import Foundation
import NearbyCore
import Observation
import UIKit
import os

/// Owns identity, transports, peers, and room state. All UI reads go through this object.
/// One class split by topic: packets in +Wire, peer tracking in +Peers, room membership in
/// +Rooms, the call audio path in +Voice. Extensions cannot hold stored state, so it all lives
/// here, internal rather than private; the UI treats it as read-only by convention.
@MainActor @Observable
final class NearbyNode {
    /// The app's node, for Live Activity intents that run in the app process.
    static weak var current: NearbyNode?

    var displayName: String {
        get { storedDisplayName }
        set {
            storedDisplayName = newValue
            UserDefaults.standard.set(newValue, forKey: Self.displayNameKey)
        }
    }
    private(set) var nodeID: NodeID
    var peers: [PeerSummary] = []
    var rooms: [RoomAnnounce] = []
    var hosted: HostRoom?
    var joined: JoinedRoom?
    var joinState: JoinState = .idle
    var keyWarning: PeerKeyWarning?
    /// When the room host first went missing; takeover waits so an internet re-route does not split the room.
    var hostMissingSince: Date?
    var transportStates: [TransportID: TransportState] = [:]
    var inCall = false
    var muted = false
    var voiceStats: [NodeID: JitterBuffer.Stats] = [:]
    var ioLatencyMs: Double = 0
    var pathInfo: [NodeID: PathInfo] = [:]
    var packetCounters = PacketCounters()
    var multipathLossThreshold: Double = 0.05
    var relayEntitlement: RelayEntitlement = .freeDirectOnly
    var paywall: PaywallPrompt?
    private var paywallShown: Set<NodeID> = []
    var attestState: String = AppAttest.isSupported ? "unattested" : "no App Attest"
    var relayError: String?
    var jitterTargetDepth: Int = 2 {
        didSet { audio?.jitterTargetDepth = jitterTargetDepth }
    }
    /// Frames of 20 ms, for peers reached over the internet.
    var internetJitterTargetDepth: Int = 3 {
        didSet { audio?.internetJitterTargetDepth = internetJitterTargetDepth }
    }

    private static let displayNameKey = "displayName"
    static let peerTimeout: TimeInterval = 5
    static let takeoverGrace: TimeInterval = 20
    static let roomTimeout: TimeInterval = 6
    static let rejoinKey = "room.rejoin"

    let logger = Logger(subsystem: "com.arsenstorm.nearby", category: "node")
    private(set) var identity: Identity
    private var storedDisplayName: String
    var peerStore: PeerStore
    var blocked: Set<NodeID>
    private(set) var transports: [TransportID: any Transport]
    var mesh: Mesh
    var probeSequence: UInt32 = 0
    var lastAdvertisement = Date.distantPast
    var lastPathRefresh = Date.distantPast
    var sessions: [NodeID: PairwiseSession] = [:]
    // Latest accepted Hello timestamp per peer. A replayed older Hello would re-derive the session from a stale ephemeral and desync it.
    var helloTimestamps: [NodeID: UInt64] = [:]
    var roomsSeen: [RoomID: (announce: RoomAnnounce, at: Date)] = [:]
    var dedup = Dedup()
    // Seeded from the clock so a relaunch does not restart below peers' dedup windows.
    var sequence = UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970 * 50))
    // One counter per member so each receiver's jitter buffer sees contiguous sequences.
    var voiceSequences: [NodeID: UInt32] = [:]
    var audio: AudioEngine?
    var outgoingVoice: Task<Void, Never>?
    var roomKey: RoomKey?
    var streamPeers: Set<NodeID> = []
    private var started = false
    /// Room to rejoin after a relaunch, until its announcement is seen or the window closes.
    var rejoinRoom: RoomID? = UserDefaults.standard.string(forKey: NearbyNode.rejoinKey).flatMap { RoomID($0) }
    let rejoinDeadline = Date().addingTimeInterval(90)
    private var eventTasks: [TransportID: Task<Void, Never>] = [:]
    private var timers: [Task<Void, Never>] = []

    init() {
        let identity = IdentityStore.loadOrCreate()
        self.identity = identity
        self.nodeID = identity.nodeID
        self.mesh = Mesh(localID: identity.nodeID)
        self.storedDisplayName =
            UserDefaults.standard.string(forKey: Self.displayNameKey) ?? UIDevice.current.name
        self.peerStore = PeerStoreFile.load()
        self.blocked = BlockListFile.load()
        self.transports = Self.makeTransports(identity: identity, serviceName: identity.nodeID.description)
        for id in TransportID.allCases {
            let supported = transports[id]?.isSupported ?? false
            transportStates[id] = TransportState(
                supported: supported,
                enabled: supported && Self.enabledSetting(id),
                active: false,
                linkCount: 0
            )
        }
        Self.current = self
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        for (id, transport) in transports where transportStates[id]?.enabled == true {
            startTransport(id, transport)
        }
        syncInternetPeers()
        refreshEntitlement()
        timers.append(every(1) { [self] in broadcastHello() })
        timers.append(every(1) { [self] in prune() })
        timers.append(every(2) { [self] in announceHostedRoom() })
        timers.append(every(0.5) { [self] in sendProbes() })
        timers.append(every(2) { [self] in broadcastLinkState() })
    }

    /// Listeners, browsers and connections do not survive the app being suspended; bring them back
    /// from scratch so stale Bonjour state cannot leave us invisible.
    func resumeFromBackground() {
        guard started else { return }
        logger.notice("resuming transports after background")
        for (id, transport) in transports where transportStates[id]?.enabled == true {
            dropLinks(for: id)
            Task { @MainActor [self] in
                await transport.stop()
                startTransport(id, transport)
            }
        }
        rebuildPeerLinks()
        refreshEntitlement()
    }

    /// PRD R20: a new identity, keeping `peerStore` — friends' keys are still valid, only ours changed.
    func regenerateIdentity() {
        Task { @MainActor [self] in
            // Leave while links are still up so members get the leave packet instead of a timeout.
            leaveRoom()
            for transport in transports.values { await transport.stop() }
            // Stale counts would otherwise survive the rebuild and double-count on reconnect.
            for id in transportStates.keys {
                transportStates[id]?.active = false
                transportStates[id]?.linkCount = 0
            }
            identity = IdentityStore.regenerate()
            nodeID = identity.nodeID
            mesh = Mesh(localID: nodeID)
            sessions = [:]
            helloTimestamps = [:]
            peers = []
            pathInfo = [:]
            voiceStats = [:]
            AppAttest.reset()
            // Old tasks read the old transports' `events`; drop them before startTransport can see
            // a non-nil entry and skip creating a task for the new transport.
            for task in eventTasks.values { task.cancel() }
            eventTasks.removeAll()
            transports = Self.makeTransports(identity: identity, serviceName: nodeID.description)
            for (id, transport) in transports where transportStates[id]?.enabled == true {
                startTransport(id, transport)
            }
            syncInternetPeers()
        }
    }

    private static func makeTransports(identity: Identity, serviceName: String) -> [TransportID: any Transport] {
        [
            .lan: DatagramTransport(id: .lan, peerToPeer: false, serviceName: serviceName),
            .p2pWiFi: DatagramTransport(id: .p2pWiFi, peerToPeer: true, serviceName: serviceName),
            .ble: BLETransport(serviceName: serviceName),
            .wifiAware: WiFiAwareTransport(serviceName: serviceName),
            .internet: InternetTransport(identity: identity,
                                         entitlement: { await RelayEntitlement.current().jws },
                                         hooks: Self.attestHooks),
        ]
    }

    // MARK: - App Attest
    // Static, and reporting back through `current`, so the transport can be built inside init.

    nonisolated static var attestHooks: InternetTransport.Hooks {
        InternetTransport.Hooks(
            attest: { jws, nonce in await proof(jws: jws, nonce: nonce) },
            attestationAccepted: { keyID in
                AppAttest.markAttested(keyID)
                report("attested")
            },
            attestationRejected: {
                AppAttest.reset()
                report("unattested")
            },
            relayUnavailable: { peer, _ in Task { @MainActor in current?.relayNeeded(peer) } },
            relayFailed: { reason in Task { @MainActor in current?.relayError = reason } })
    }

    nonisolated private static func proof(jws: String, nonce: Data) async -> InternetTransport.RelayProof? {
        guard AppAttest.isSupported else { return nil }
        do {
            let key = try await AppAttest.keyID()
            // A key must be certified before it can sign, so attest first when it is new.
            let attestation = key.isNew ? try await AppAttest.attestation(keyID: key.id, nonce: nonce) : nil
            let assertion = try await AppAttest.assertion(keyID: key.id, jws: jws, nonce: nonce)
            return .init(keyID: key.id, attestation: attestation, assertion: assertion)
        } catch {
            report("unattested")
            return nil
        }
    }

    nonisolated private static func report(_ state: String) {
        Task { @MainActor in current?.attestState = state }
    }

    private func refreshEntitlement() {
        Task { @MainActor [self] in relayEntitlement = await RelayEntitlement.current().state }
    }

    /// Shown once per peer per launch; a second refusal within the run is noise, not news.
    func relayNeeded(_ peer: NodeID) {
        guard relayEntitlement == .freeDirectOnly, !paywallShown.contains(peer) else { return }
        paywallShown.insert(peer)
        paywall = PaywallPrompt(peer: peer)
    }

    func purchased(for peer: NodeID) {
        Task { @MainActor [self] in
            relayEntitlement = await RelayEntitlement.reload().state
            (transports[.internet] as? InternetTransport)?.retryRelay(peer)
        }
    }

    func peerName(_ id: NodeID) -> String {
        peers.first { $0.id == id }?.name ?? peerStore.record(for: id)?.name ?? id.description
    }

    func setTransport(_ id: TransportID, enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey(id))
        transportStates[id]?.enabled = enabled
        guard let transport = transports[id] else { return }
        if enabled {
            if started { startTransport(id, transport) }
        } else {
            Task { await transport.stop() }
            dropLinks(for: id)
            rebuildPeerLinks()
            advertiseLinkState()
        }
    }

    private func dropLinks(for id: TransportID) {
        let now = Date()
        for link in mesh.allLinks where link.transport == id { mesh.linkDown(link, now: now) }
        transportStates[id]?.active = false
        transportStates[id]?.linkCount = 0
    }

    private func startTransport(_ id: TransportID, _ transport: any Transport) {
        if eventTasks[id] == nil {
            eventTasks[id] = Task { @MainActor [self] in
                for await event in transport.events { handle(event) }
            }
        }
        Task { @MainActor [self] in
            do {
                try await transport.start()
                transportStates[id]?.active = true
            } catch {
                logger.error("\(id.rawValue, privacy: .public) start failed: \(error.localizedDescription, privacy: .public)")
                if !transport.isSupported {
                    transportStates[id]?.supported = false
                    transportStates[id]?.enabled = false
                }
            }
        }
    }

    private static func enabledKey(_ id: TransportID) -> String { "transport.\(id.rawValue).enabled" }

    private static func enabledSetting(_ id: TransportID) -> Bool {
        UserDefaults.standard.object(forKey: enabledKey(id)) as? Bool ?? true
    }

    private func every(_ seconds: Double, _ body: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                body()
            }
        }
    }
}

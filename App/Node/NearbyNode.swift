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
    let nodeID: NodeID
    var peers: [PeerSummary] = []
    var rooms: [RoomAnnounce] = []
    var hosted: HostRoom?
    var joined: JoinedRoom?
    var joinState: JoinState = .idle
    var keyWarning: PeerKeyWarning?
    var transportStates: [TransportID: TransportState] = [:]
    var inCall = false
    var muted = false
    var voiceStats: [NodeID: JitterBuffer.Stats] = [:]
    var ioLatencyMs: Double = 0
    var pathInfo: [NodeID: PathInfo] = [:]
    var packetCounters = PacketCounters()
    var multipathLossThreshold: Double = 0.05
    var jitterTargetDepth: Int = 3 {
        didSet { audio?.jitterTargetDepth = jitterTargetDepth }
    }

    private static let displayNameKey = "displayName"
    static let peerTimeout: TimeInterval = 5
    static let roomTimeout: TimeInterval = 6
    static let rejoinKey = "room.rejoin"

    let logger = Logger(subsystem: "com.arsenstorm.nearby", category: "node")
    let identity: Identity
    private var storedDisplayName: String
    var peerStore: PeerStore
    let transports: [TransportID: any Transport]
    var mesh: Mesh
    var probeSequence: UInt32 = 0
    var lastAdvertisement = Date.distantPast
    var lastPathRefresh = Date.distantPast
    var sessions: [NodeID: PairwiseSession] = [:]
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
        let serviceName = identity.nodeID.description
        self.transports = [
            .lan: DatagramTransport(id: .lan, peerToPeer: false, serviceName: serviceName),
            .p2pWiFi: DatagramTransport(id: .p2pWiFi, peerToPeer: true, serviceName: serviceName),
            .ble: BLETransport(serviceName: serviceName),
            .wifiAware: WiFiAwareTransport(serviceName: serviceName),
        ]
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

import Foundation
import NearbyCore
import Network
import os

/// UDP over the open internet. Two nodes meet in a rendezvous room named after both their IDs, trade
/// signed Hellos and candidates, hole-punch, and keep the resulting mapping alive.
final class InternetTransport: Transport, @unchecked Sendable {
    let id: TransportID = .internet
    let isSupported = true
    let events: AsyncStream<TransportEvent>

    // A punch is always answered with an ack; an ack is never answered, so keepalives cannot ping-pong.
    private static let punch = Data("nearby-punch-v1".utf8)
    private static let ack = Data("nearby-ack-v1".utf8)
    private static let punchWindow: TimeInterval = 3
    private static let keepaliveInterval: TimeInterval = 15
    private static let linkTimeout: TimeInterval = 45
    private static let retryDelay: TimeInterval = 30
    /// An offer that lands this soon after ours is the peer answering it, not a peer still waiting.
    static let offerEcho: TimeInterval = 2

    private let continuation: AsyncStream<TransportEvent>.Continuation
    let queue = DispatchQueue(label: "nearby.transport.internet")
    let logger = Logger(subsystem: "com.arsenstorm.nearby", category: "internet")
    let identity: Identity
    private let rendezvous: URL
    let entitlement: @Sendable () async -> String?
    let hooks: Hooks

    /// The App Attest material a relay request carries (PRD R17); nil where App Attest is unavailable.
    struct RelayProof: Sendable {
        let keyID: String
        let attestation: Data?
        let assertion: Data
    }

    struct Hooks: Sendable {
        /// Builds a proof over the entitlement JWS and this room's challenge nonce.
        var attest: @Sendable (_ jws: String, _ nonce: Data) async -> RelayProof? = { _, _ in nil }
        var attestationAccepted: @Sendable (_ keyID: String) -> Void = { _ in }
        var attestationRejected: @Sendable () -> Void = {}
    }

    private var socket: UDPSocket?
    var probe: NATProbe?
    var started = false
    private var peers: Set<NodeID> = []
    private var pathMonitor: NWPathMonitor?
    /// The interfaces and status of the last update, to tell a real path change from a repeat.
    private var lastPath: (interfaces: [String], status: NWPath.Status)?
    var rooms: [NodeID: URLSessionWebSocketTask] = [:]
    /// The challenge nonce of each open room; the App Attest assertion signs over it.
    var nonces: [NodeID: Data] = [:]
    var offered: Set<NodeID> = []
    var lastOfferAt: [NodeID: Date] = [:]
    var mine: [NodeID: [Candidate]] = [:]
    private var punching: [NodeID: (candidates: [Candidate], deadline: Date)] = [:]
    /// Every address a peer has offered; kept after link-up because the peer may talk from another of them.
    private var theirs: [NodeID: [Candidate]] = [:]
    private var links: [LinkID: Link] = [:]
    /// The allocation each peer is currently reached through.
    var relays: [NodeID: TURNClient] = [:]
    /// The allocation a renewal replaced; it still receives until the peer stops sending through it.
    var retiring: [NodeID: TURNClient] = [:]
    var lastRelayAttempt: [NodeID: Date] = [:]
    /// A relay asked for but not yet answered; the reply needs the candidates the punch failed on.
    var pendingRelay: [NodeID: (jws: String, candidates: [Candidate], proof: RelayProof?, renewal: Bool)] = [:]
    private var keepaliveTimer: DispatchSourceTimer?

    private struct Link {
        let peer: NodeID
        let host: String
        let port: UInt16
        var lastHeard: Date
        /// The allocation this link's datagrams ride; nil when the path is direct.
        var relay: TURNClient?
        /// True on either end of a relayed path: ours, or one the peer allocated and we send straight into.
        let relayed: Bool
    }

    init(identity: Identity, rendezvous: URL = URL(string: "wss://nearby.arsenstorm.com/pair/")!,
         entitlement: @escaping @Sendable () async -> String? = { nil },
         hooks: Hooks = Hooks()) {
        self.identity = identity
        self.rendezvous = rendezvous
        self.entitlement = entitlement
        self.hooks = hooks
        (self.events, self.continuation) = AsyncStream.makeStream(of: TransportEvent.self)
    }

    // MARK: - Lifecycle

    /// Peers worth dialing (the PeerStore). Remembered across stop/start.
    func setPeers(_ ids: Set<NodeID>) {
        queue.async { [self] in
            peers = ids
            for peer in ids { dial(peer) }
        }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard !started else { return cont.resume() }
                do {
                    let socket = try UDPSocket(port: .random(in: 20000...60000), queue: queue)
                    socket.onReceive = { [weak self] data, host, port in self?.received(data, host, port) }
                    self.socket = socket
                    self.probe = NATProbe(socket: socket)
                    started = true
                    // Pacing against a grant the last run paid for would blank the first minute here.
                    lastRelayAttempt.removeAll()
                    startKeepalive()
                    startPathMonitor()
                    for peer in peers { dial(peer) }
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                started = false
                keepaliveTimer?.cancel()
                keepaliveTimer = nil
                pathMonitor?.cancel()
                pathMonitor = nil
                lastPath = nil
                teardown()
                socket?.shutdown()
                socket = nil
                probe = nil
                cont.resume()
            }
        }
    }

    /// Everything tied to the current network path: allocations, links, rooms, and the relay pacing.
    private func teardown() {
        for client in relays.values { client.close() }
        for client in retiring.values { client.close() }
        relays.removeAll()
        retiring.removeAll()
        for peer in Array(rooms.keys) { closeRoom(peer) }
        punching.removeAll()
        pendingRelay.removeAll()
        lastRelayAttempt.removeAll()
        for link in links.keys { continuation.yield(.linkDown(link)) }
        links.removeAll()
    }

    func send(_ data: Data, over link: LinkID) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard let state = links[link] else {
                    return cont.resume(throwing: TransportError.unknownLink(link))
                }
                sendRaw(data, host: state.host, port: state.port, via: state.relay)
                cont.resume()
            }
        }
    }

    // MARK: - Path

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in self?.pathChanged(path) }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    /// A TURN allocation is bound to the client's 5-tuple and a punched mapping to the old NAT, so a
    /// Wi-Fi↔cellular switch kills both silently. What was built on the old path goes rather than time out.
    private func pathChanged(_ path: NWPath) {
        let current = (interfaces: path.availableInterfaces.map(\.name), status: path.status)
        defer { lastPath = current }
        guard let last = lastPath,
              last.interfaces != current.interfaces || last.status != current.status
        else { return }
        logger.notice("path change: \(current.interfaces.joined(separator: ","), privacy: .public)")
        teardown()
        for peer in peers { dial(peer) }
    }

    // MARK: - Rendezvous

    func dial(_ peer: NodeID) {
        // A relayed peer keeps its room open for the renewal, so a dropped socket has to be redialed.
        guard started, rooms[peer] == nil, hasRelayedLink(peer) || !hasLink(peer) else { return }
        let room = PairRoom.name(identity.nodeID, peer)
        let task = URLSession.shared.webSocketTask(with: rendezvous.appendingPathComponent(room))
        rooms[peer] = task
        task.resume()
        logger.notice("dial \(peer.description, privacy: .public)")
        receiveFrame(task, peer: peer)
    }

    private func receiveFrame(_ task: URLSessionWebSocketTask, peer: NodeID) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.rooms[peer] === task else { return }
                switch result {
                case .success(.string(let text)):
                    self.handleFrame(text, peer: peer, task: task)
                    self.receiveFrame(task, peer: peer)
                case .success:
                    self.receiveFrame(task, peer: peer)
                case .failure(let error):
                    self.logger.error("ws \(peer.description, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    self.closeRoom(peer)
                    self.retryLater(peer)
                }
            }
        }
    }

    func send(_ frame: [String: Any], on task: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: frame) else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
            guard let error else { return }
            self?.logger.error("ws send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func closeRoom(_ peer: NodeID) {
        rooms.removeValue(forKey: peer)?.cancel()
        nonces.removeValue(forKey: peer)
        offered.remove(peer)
    }

    func retryLater(_ peer: NodeID) {
        queue.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
            guard let self, self.peers.contains(peer) else { return }
            self.dial(peer)
        }
    }

    // MARK: - Punching

    func startPunch(_ peer: NodeID, candidates: [Candidate]) {
        theirs[peer] = candidates
        let deadline = Date().addingTimeInterval(Self.punchWindow)
        punching[peer] = (candidates, deadline)
        logger.notice("punch \(peer.description, privacy: .public)")
        punchTick(peer, deadline: deadline)
    }

    private func punchTick(_ peer: NodeID, deadline: Date) {
        guard let state = punching[peer], state.deadline == deadline, socket != nil else { return }
        guard Date() < deadline else {
            punching[peer] = nil
            return startRelay(peer, candidates: state.candidates)
        }
        // Once a relay is allocated the punch goes through it: the direct path already had its window.
        for candidate in state.candidates {
            sendRaw(Self.punch, host: candidate.host, port: candidate.port, via: relays[peer])
        }
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.punchTick(peer, deadline: deadline) }
    }

    // MARK: - Relay handover

    /// A renewed allocation proves itself the moment the peer's traffic arrives through it, so the link
    /// moves across without ever going down.
    private func adopt(_ client: TURNClient?, for link: LinkID) {
        guard let client, let state = links[link], state.relay !== client, relays[state.peer] === client
        else { return }
        links[link]?.relay = client
        logger.notice("relay renewed for \(state.peer.description, privacy: .public)")
        retire(state.peer)
    }

    /// The peer keeps sending through the replaced allocation until its own link to it times out, so
    /// that allocation outlives the handover by exactly that window instead of closing straight away.
    private func retire(_ peer: NodeID) {
        guard let old = retiring[peer] else { return }
        queue.asyncAfter(deadline: .now() + Self.linkTimeout + Self.keepaliveInterval) { [weak self, weak old] in
            guard let self, let old, retiring[peer] === old else { return }
            retiring.removeValue(forKey: peer)?.close()
            logger.notice("relay retired for \(peer.description, privacy: .public)")
        }
    }

    /// The peer's addresses, but only while a relayed link to it is up: nothing else is worth renewing for.
    func relayedPeerCandidates(_ peer: NodeID) -> [Candidate]? {
        guard links.values.contains(where: { $0.peer == peer && $0.relay != nil }) else { return nil }
        return theirs[peer]
    }

    private func sendRaw(_ data: Data, host: String, port: UInt16, via client: TURNClient?) {
        guard let client else { return socket?.send(data, to: host, port: port) ?? () }
        client.send(data, to: host, port: port)
    }

    /// A symmetric NAT rewrites the source port per destination, so the peer can arrive from a port it never advertised.
    private func peerOwning(host: String, port: UInt16) -> NodeID? {
        let exact = theirs.first { $0.value.contains { $0.host == host && $0.port == port } }
        return exact?.key ?? theirs.first { $0.value.contains { $0.host == host } }?.key
    }

    // MARK: - Datagrams

    private func received(_ data: Data, _ host: String, _ port: UInt16) {
        if probe?.handleDatagram(data) == true { return }
        deliver(data, host: host, port: port, via: nil)
    }

    /// `client` is the allocation that carried this datagram; PRD R14 reads it back off the endpoint.
    func deliver(_ data: Data, host: String, port: UInt16, via client: TURNClient?) {
        let relayed = client != nil || isPeerRelay(host: host, port: port)
        let link = LinkID(transport: id, endpoint: relayed ? "relay:\(host):\(port)" : "\(host):\(port)")
        adopt(client, for: link)
        // A punch only proves the inbound direction, so it is answered but never brings a link up;
        // the ack that comes back proves the round trip and does.
        if data == Self.punch { return answerPunch(link, host: host, port: port, via: client) }
        if data == Self.ack { return receivedAck(link, host: host, port: port, via: client) }
        // The peer may have nominated a different address pair than we did; a datagram from any
        // address it offered is proof enough to carry that pair as a second link.
        if links[link] == nil, let peer = peerOwning(host: host, port: port) {
            bringUp(link, peer: peer, host: host, port: port, via: client)
        }
        guard links[link] != nil else { return }
        links[link]?.lastHeard = Date()
        continuation.yield(.received(data, link))
    }

    private func answerPunch(_ link: LinkID, host: String, port: UInt16, via client: TURNClient?) {
        sendRaw(Self.ack, host: host, port: port, via: client)
        links[link]?.lastHeard = Date()
    }

    private func receivedAck(_ link: LinkID, host: String, port: UInt16, via client: TURNClient?) {
        guard links[link] == nil else {
            links[link]?.lastHeard = Date()
            return
        }
        guard let peer = peerOwning(host: host, port: port) else { return }
        bringUp(link, peer: peer, host: host, port: port, via: client)
    }

    private func bringUp(_ link: LinkID, peer: NodeID, host: String, port: UInt16, via client: TURNClient?) {
        let relayed = link.endpoint.hasPrefix("relay:")
        links[link] = Link(peer: peer, host: host, port: port, lastHeard: Date(), relay: client, relayed: relayed)
        punching[peer] = nil
        // PRD R9 renews TURN credentials over this same room. The renewed address reaches the other
        // end as an offer, so the room stays open on both ends of a relayed path, not just the payer's.
        if !relayed { closeRoom(peer) }
        if client != nil, relays[peer] === client { retire(peer) }
        logger.notice("link up \(link.description, privacy: .public) to \(peer.description, privacy: .public)")
        continuation.yield(.linkUp(link))
    }

    private func startKeepalive() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.keepaliveInterval, repeating: Self.keepaliveInterval)
        timer.setEventHandler { [weak self] in self?.keepalive() }
        timer.resume()
        keepaliveTimer = timer
    }

    private func keepalive() {
        let now = Date()
        for (link, state) in links {
            guard now.timeIntervalSince(state.lastHeard) <= Self.linkTimeout else {
                links[link] = nil
                logger.notice("link down \(link.description, privacy: .public)")
                if state.relay != nil { dropRelay(state.peer) }
                continuation.yield(.linkDown(link))
                dial(state.peer)
                continue
            }
            sendRaw(Self.ack, host: state.host, port: state.port, via: state.relay)
        }
    }

    func hasLink(_ peer: NodeID) -> Bool {
        links.values.contains { $0.peer == peer }
    }

    func hasRelayedLink(_ peer: NodeID) -> Bool {
        relays[peer] != nil || links.values.contains { $0.peer == peer && $0.relayed }
    }

    /// An address the peer offered as its TURN allocation.
    private func isPeerRelay(host: String, port: UInt16) -> Bool {
        theirs.values.contains { $0.contains { $0.kind == .relay && $0.host == host && $0.port == port } }
    }
}

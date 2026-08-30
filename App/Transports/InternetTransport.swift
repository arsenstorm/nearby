import Foundation
import NearbyCore
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

    private let continuation: AsyncStream<TransportEvent>.Continuation
    let queue = DispatchQueue(label: "nearby.transport.internet")
    let logger = Logger(subsystem: "com.arsenstorm.nearby", category: "internet")
    let identity: Identity
    private let rendezvous: URL
    private let entitlement: @Sendable () async -> String?

    private var socket: UDPSocket?
    var probe: NATProbe?
    var started = false
    private var peers: Set<NodeID> = []
    var rooms: [NodeID: URLSessionWebSocketTask] = [:]
    var offered: Set<NodeID> = []
    var mine: [NodeID: [Candidate]] = [:]
    private var punching: [NodeID: (candidates: [Candidate], deadline: Date)] = [:]
    private var links: [LinkID: Link] = [:]
    var relays: [NodeID: TURNClient] = [:]
    /// A relay asked for but not yet answered; the reply needs the candidates the punch failed on.
    var pendingRelay: [NodeID: (jws: String, candidates: [Candidate])] = [:]
    private var keepaliveTimer: DispatchSourceTimer?

    private struct Link {
        let peer: NodeID
        let host: String
        let port: UInt16
        var lastHeard: Date
    }

    init(identity: Identity, rendezvous: URL = URL(string: "wss://nearby.arsenstorm.com/pair/")!,
         entitlement: @escaping @Sendable () async -> String? = { nil }) {
        self.identity = identity
        self.rendezvous = rendezvous
        self.entitlement = entitlement
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
                    startKeepalive()
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
                for (_, task) in rooms { task.cancel() }
                rooms.removeAll()
                offered.removeAll()
                punching.removeAll()
                pendingRelay.removeAll()
                for relay in relays.values { relay.close() }
                relays.removeAll()
                for link in links.keys { continuation.yield(.linkDown(link)) }
                links.removeAll()
                socket?.shutdown()
                socket = nil
                probe = nil
                cont.resume()
            }
        }
    }

    func send(_ data: Data, over link: LinkID) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard let state = links[link] else {
                    return cont.resume(throwing: TransportError.unknownLink(link))
                }
                sendRaw(data, host: state.host, port: state.port, relay: relayed(link) ? state.peer : nil)
                cont.resume()
            }
        }
    }

    // MARK: - Rendezvous

    func dial(_ peer: NodeID) {
        guard started, rooms[peer] == nil, !hasLink(peer) else { return }
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
        let relay = relays[peer] != nil ? peer : nil
        for candidate in state.candidates {
            sendRaw(Self.punch, host: candidate.host, port: candidate.port, relay: relay)
        }
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.punchTick(peer, deadline: deadline) }
    }

    // MARK: - Relay

    /// PRD R7/R9: only after the direct window fails do we pay for a TURN allocation.
    private func startRelay(_ peer: NodeID, candidates: [Candidate]) {
        guard started, relays[peer] == nil, pendingRelay[peer] == nil, !hasLink(peer) else { return }
        Task { [weak self, entitlement] in
            guard let jws = await entitlement() else { return }
            self?.queue.async { [weak self] in self?.requestRelay(peer, jws: jws, candidates: candidates) }
        }
    }

    func beginRelay(_ peer: NodeID, candidates: [Candidate], credentials: TURNCredentials) {
        guard started, relays[peer] == nil, let socket else { return }
        let client = TURNClient(credentials: credentials,
                                send: { [weak socket] data, host, port in socket?.send(data, to: host, port: port) },
                                queue: queue)
        client.onRelayed = { [weak self] relayed in self?.relayReady(peer, relayed: relayed, candidates: candidates) }
        client.onData = { [weak self] payload, host, port in
            self?.deliver(payload, host: host, port: port, relay: peer)
        }
        client.onFailure = { [weak self] _ in self?.dropRelay(peer) }
        relays[peer] = client
        client.allocate()
        logger.notice("relay allocating for \(peer.description, privacy: .public)")
    }

    private func relayReady(_ peer: NodeID, relayed: (host: String, port: UInt16), candidates: [Candidate]) {
        // The relay drops anything from an address it has no permission for (RFC 8656 §9).
        for host in Set(candidates.map(\.host)) { relays[peer]?.permit(host: host) }
        if let task = rooms[peer] {
            let relay = Candidate(kind: .relay, host: relayed.host, port: relayed.port)
            finishOffer(task, peer: peer, candidates: (mine[peer] ?? []) + [relay])
        }
        startPunch(peer, candidates: candidates)
    }

    private func dropRelay(_ peer: NodeID) {
        relays.removeValue(forKey: peer)?.close()
    }

    private func relayed(_ link: LinkID) -> Bool { link.endpoint.hasPrefix("relay:") }

    private func sendRaw(_ data: Data, host: String, port: UInt16, relay: NodeID?) {
        guard let relay, let client = relays[relay] else { return socket?.send(data, to: host, port: port) ?? () }
        client.send(data, to: host, port: port)
    }

    /// A symmetric NAT rewrites the source port per destination, so the peer can arrive from a port it never advertised.
    private func peerOwning(host: String, port: UInt16) -> NodeID? {
        let exact = punching.first { $0.value.candidates.contains { $0.host == host && $0.port == port } }
        return exact?.key ?? punching.first { $0.value.candidates.contains { $0.host == host } }?.key
    }

    // MARK: - Datagrams

    private func received(_ data: Data, _ host: String, _ port: UInt16) {
        if probe?.handleDatagram(data) == true { return }
        for client in relays.values where client.handle(data, from: host, port: port) { return }
        deliver(data, host: host, port: port, relay: nil)
    }

    /// `relay` names the peer whose allocation carried this datagram; PRD R14 reads it back off the endpoint.
    private func deliver(_ data: Data, host: String, port: UInt16, relay: NodeID?) {
        let endpoint = relay == nil ? "\(host):\(port)" : "relay:\(host):\(port)"
        let link = LinkID(transport: id, endpoint: endpoint)
        if data == Self.punch { sendRaw(Self.ack, host: host, port: port, relay: relay) }
        guard data != Self.punch, data != Self.ack else { return receivedPunch(link, host: host, port: port) }
        guard links[link] != nil else { return }
        links[link]?.lastHeard = Date()
        continuation.yield(.received(data, link))
    }

    private func receivedPunch(_ link: LinkID, host: String, port: UInt16) {
        guard links[link] == nil else {
            links[link]?.lastHeard = Date()
            return
        }
        guard let peer = peerOwning(host: host, port: port) else { return }
        links[link] = Link(peer: peer, host: host, port: port, lastHeard: Date())
        punching[peer] = nil
        // PRD R9 renews TURN credentials over this same socket, so a relayed link keeps its room.
        // ponytail: credentials are not renewed; a relayed call drops at the 10-min TTL. Renew by
        // re-sending the relay frame at ttl/2 and updating TURNClient's password.
        if relays[peer] == nil { closeRoom(peer) }
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
                if relayed(link) { dropRelay(state.peer) }
                continuation.yield(.linkDown(link))
                dial(state.peer)
                continue
            }
            sendRaw(Self.ack, host: state.host, port: state.port, relay: relayed(link) ? state.peer : nil)
        }
    }

    private func hasLink(_ peer: NodeID) -> Bool {
        links.values.contains { $0.peer == peer }
    }

    static func unhex(_ text: String) -> Data? {
        guard text.count % 2 == 0 else { return nil }
        var out = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}

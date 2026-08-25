import Foundation
import NearbyCore
import Observation
import UIKit
import os

struct PeerSummary: Identifiable, Equatable, Sendable {
    let id: NodeID
    var name: String
    var lastSeen: Date
    var links: [LinkID]
}

struct JoinedRoom: Equatable, Sendable {
    let id: RoomID
    var name: String
    var host: NodeID
    var members: [Member]
    var roomKey: Data
}

enum JoinState: Equatable, Sendable {
    case idle
    case requested(RoomID)
    case rejected(String)
}

struct PeerKeyWarning: Equatable, Sendable {
    let hello: Hello
    let existing: PeerRecord
}

struct TransportState: Equatable, Sendable {
    var supported: Bool
    var enabled: Bool
    var active: Bool
    var linkCount: Int
}

struct PathInfo: Equatable, Sendable {
    var hops: Int
    var costMs: Double
    var nextLink: LinkID?
    var latencyMs: Double
    var lossFraction: Double
    var jitterMs: Double
}

struct PacketCounters: Equatable, Sendable {
    var sent = 0
    var received = 0
    var relayed = 0
    var droppedDedup = 0
    var droppedTTL = 0
}

/// Owns identity, transports, peers, and room state. All UI reads go through this object.
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
    private(set) var peers: [PeerSummary] = []
    private(set) var rooms: [RoomAnnounce] = []
    private(set) var hosted: HostRoom?
    private(set) var joined: JoinedRoom?
    private(set) var joinState: JoinState = .idle
    private(set) var keyWarning: PeerKeyWarning?
    private(set) var transportStates: [TransportID: TransportState] = [:]
    private(set) var inCall = false
    var muted = false
    private(set) var voiceStats: [NodeID: JitterBuffer.Stats] = [:]
    private(set) var ioLatencyMs: Double = 0
    private(set) var pathInfo: [NodeID: PathInfo] = [:]
    private(set) var packetCounters = PacketCounters()
    var multipathLossThreshold: Double = 0.05
    var jitterTargetDepth: Int = 3 {
        didSet { audio?.jitterTargetDepth = jitterTargetDepth }
    }

    private static let displayNameKey = "displayName"
    private static let peerTimeout: TimeInterval = 5
    private static let roomTimeout: TimeInterval = 6

    private let logger = Logger(subsystem: "com.arsenstorm.nearby", category: "node")
    private let identity: Identity
    private var storedDisplayName: String
    private var peerStore: PeerStore
    private let transports: [TransportID: any Transport]
    private var mesh: Mesh
    private var probeSequence: UInt32 = 0
    private var lastAdvertisement = Date.distantPast
    private var lastPathRefresh = Date.distantPast
    private var sessions: [NodeID: PairwiseSession] = [:]
    private var roomsSeen: [RoomID: (announce: RoomAnnounce, at: Date)] = [:]
    private var dedup = Dedup()
    // Seeded from the clock so a relaunch does not restart below peers' dedup windows.
    private var sequence = UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970 * 50))
    // One counter per member so each receiver's jitter buffer sees contiguous sequences.
    private var voiceSequences: [NodeID: UInt32] = [:]
    private var audio: AudioEngine?
    private var outgoingVoice: Task<Void, Never>?
    private var roomKey: RoomKey?
    private var streamPeers: Set<NodeID> = []
    private var started = false
    /// Room to rejoin after a relaunch, until its announcement is seen or the window closes.
    private var rejoinRoom: RoomID? = UserDefaults.standard.string(forKey: NearbyNode.rejoinKey).flatMap { RoomID($0) }
    private let rejoinDeadline = Date().addingTimeInterval(90)
    private static let rejoinKey = "room.rejoin"
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
        let now = Date()
        for (id, transport) in transports where transportStates[id]?.enabled == true {
            for link in mesh.allLinks where link.transport == id { mesh.linkDown(link, now: now) }
            transportStates[id]?.active = false
            transportStates[id]?.linkCount = 0
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
            let now = Date()
            for link in mesh.allLinks where link.transport == id { mesh.linkDown(link, now: now) }
            transportStates[id]?.active = false
            transportStates[id]?.linkCount = 0
            rebuildPeerLinks()
            advertiseLinkState()
        }
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

    // MARK: - Sending

    private func nextSequence() -> UInt32 {
        sequence &+= 1
        return sequence
    }

    private var sendableLinks: [LinkID] {
        mesh.allLinks.filter { transportStates[$0.transport].map { $0.enabled && $0.active } ?? false }
    }

    private func transmit(_ data: Data, over link: LinkID) {
        guard let transport = transports[link.transport] else { return }
        packetCounters.sent += 1
        Task { try? await transport.send(data, over: link) }
    }

    private func broadcastControl(_ message: ControlMessage) {
        let header = PacketHeader(
            type: .control, source: nodeID, destination: .broadcast,
            stream: 0, sequence: nextSequence()
        )
        guard let payload = try? message.encode() else { return }
        let data = Packet(header: header, payload: payload).encode()
        for link in sendableLinks { transmit(data, over: link) }
    }

    private func sendControl(_ message: ControlMessage, to destination: NodeID) {
        let header = PacketHeader(
            type: .control, source: nodeID, destination: destination,
            stream: 0, sequence: nextSequence()
        )
        guard let session = sessions[destination] else {
            logger.error("no session for \(destination.description, privacy: .public), dropping control")
            return
        }
        guard let plaintext = try? message.encode(),
              let sealed = try? session.seal(plaintext, header: header)
        else {
            logger.error("failed to seal control for \(destination.description, privacy: .public)")
            return
        }
        guard let link = mesh.nextLink(to: destination) else {
            logger.error("no route to \(destination.description, privacy: .public), dropping control")
            return
        }
        let data = Packet(header: header, payload: sealed).encode()
        transmit(data, over: link)
        if let alternate = mesh.alternateLink(to: destination), alternate != link {
            transmit(data, over: alternate)
        }
    }

    private func helloPacket() -> Data? {
        let header = PacketHeader(
            type: .hello, source: nodeID, destination: .broadcast,
            stream: 0, sequence: nextSequence()
        )
        let timestampMs = UInt64(Date().timeIntervalSince1970 * 1000)
        guard let hello = try? Hello(identity: identity, name: displayName, timestampMs: timestampMs),
              let payload = try? hello.encode()
        else {
            logger.error("failed to build hello")
            return nil
        }
        return Packet(header: header, payload: payload).encode()
    }

    private func broadcastHello() {
        let links = sendableLinks
        guard !links.isEmpty, let data = helloPacket() else { return }
        for link in links { transmit(data, over: link) }
    }

    private func probePayload(kind: UInt8, sequence: UInt32) -> Data {
        Data([kind]) + withUnsafeBytes(of: sequence.bigEndian) { Data($0) }
    }

    private func sendProbe(kind: UInt8, sequence: UInt32, on link: LinkID, to destination: NodeID) {
        let header = PacketHeader(
            type: .probe, source: nodeID, destination: destination,
            stream: 0, sequence: nextSequence(), ttl: 1
        )
        let packet = Packet(header: header, payload: probePayload(kind: kind, sequence: sequence))
        transmit(packet.encode(), over: link)
    }

    private func sendProbes() {
        let now = Date()
        for link in mesh.allLinks {
            probeSequence &+= 1
            mesh.probeSent(on: link, sequence: probeSequence, at: now)
            sendProbe(kind: 0, sequence: probeSequence, on: link, to: mesh.node(for: link) ?? .broadcast)
        }
        mesh.expireProbes(now: now)
    }

    private func broadcastLinkState() {
        let now = Date()
        lastAdvertisement = now
        let lsa = mesh.localAdvertisement(now: now)
        guard let payload = try? lsa.encode() else { return }
        let header = PacketHeader(
            type: .linkState, source: nodeID, destination: .broadcast,
            stream: 0, sequence: nextSequence()
        )
        let data = Packet(header: header, payload: payload).encode()
        for link in sendableLinks { transmit(data, over: link) }
        refreshPaths(now: now)
    }

    /// Event-driven advertisements are capped so a flapping link cannot flood the mesh.
    private func advertiseLinkState() {
        guard Date().timeIntervalSince(lastAdvertisement) >= 0.25 else { return }
        broadcastLinkState()
    }

    // MARK: - Receiving

    private func handle(_ event: TransportEvent) {
        switch event {
        case .linkUp(let link):
            mesh.linkUp(link, bandwidthKbps: link.transport == .ble ? 100 : 10_000, now: Date())
            transportStates[link.transport]?.linkCount += 1
            if let data = helloPacket() { transmit(data, over: link) }
            advertiseLinkState()
        case .linkDown(let link):
            mesh.linkDown(link, now: Date())
            if let count = transportStates[link.transport]?.linkCount {
                transportStates[link.transport]?.linkCount = max(0, count - 1)
            }
            rebuildPeerLinks()
            refreshPaths()
            advertiseLinkState()
        case .received(let data, let link):
            receive(data, from: link)
        }
    }

    private func receive(_ data: Data, from link: LinkID) {
        guard let packet = Packet(decoding: data) else { return }
        let header = packet.header
        guard header.source != nodeID else { return }
        packetCounters.received += 1
        guard dedup.check(source: header.source, destination: header.destination, stream: header.stream, sequence: header.sequence)
        else {
            packetCounters.droppedDedup += 1
            return
        }
        let now = Date()

        switch header.type {
        case .hello:
            receiveHello(packet.payload, from: link, direct: header.ttl == PacketHeader.initialTTL)
            if header.ttl > 1 { flood(packet, from: link) }
        case .probe:
            receiveProbe(packet, from: link, now: now)
        case .linkState:
            guard let lsa = try? LinkStateAdvertisement.decode(packet.payload),
                  mesh.apply(lsa, now: now)
            else { return }
            if header.ttl > 1 { flood(packet, from: link) }
            refreshPaths(now: now)
        case .control where header.destination == .broadcast:
            receiveControl(packet)
            if header.ttl > 1 { flood(packet, from: link) }
        case .control, .voice:
            if header.destination == nodeID {
                if header.type == .control { receiveControl(packet) } else { receiveVoice(packet) }
            } else if header.ttl > 1 {
                forward(packet)
            } else {
                packetCounters.droppedTTL += 1
            }
        case .ack:
            break
        }
    }

    private func flood(_ packet: Packet, from link: LinkID) {
        var header = packet.header
        header.ttl -= 1
        let data = Packet(header: header, payload: packet.payload).encode()
        for out in sendableLinks where out != link {
            transmit(data, over: out)
            packetCounters.relayed += 1
        }
    }

    private func forward(_ packet: Packet) {
        guard let link = mesh.nextLink(to: packet.header.destination) else { return }
        var header = packet.header
        header.ttl -= 1
        transmit(Packet(header: header, payload: packet.payload).encode(), over: link)
        packetCounters.relayed += 1
    }

    private func receiveProbe(_ packet: Packet, from link: LinkID, now: Date) {
        let payload = [UInt8](packet.payload)
        guard payload.count >= 5 else { return }
        let sequence = payload[1...4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        if payload[0] == 0 {
            sendProbe(kind: 1, sequence: sequence, on: link, to: packet.header.source)
        } else {
            _ = mesh.probeReply(on: link, sequence: sequence, at: now)
        }
    }

    private func receiveHello(_ payload: Data, from link: LinkID, direct: Bool) {
        guard let hello = try? Hello.decode(payload) else { return }
        let now = Date()
        let before = peerStore.record(for: hello.nodeID)
        let record: PeerRecord
        do {
            record = try peerStore.observe(hello, now: now)
        } catch PeerStoreError.keyChanged(let existing) {
            if keyWarning == nil { keyWarning = PeerKeyWarning(hello: hello, existing: existing) }
            return
        } catch {
            logger.error("hello from \(hello.nodeID.description, privacy: .public) failed verification")
            return
        }
        if direct {
            let unbound = mesh.node(for: link) == nil
            mesh.bind(link, to: hello.nodeID)
            if unbound { advertiseLinkState() }
        }
        if sessions[hello.nodeID] == nil { makeSession(for: record) }
        upsertPeer(id: record.id, name: record.name, lastSeen: now)
        if before != record { PeerStoreFile.save(peerStore) }
    }

    private func receiveControl(_ packet: Packet) {
        let header = packet.header
        let plaintext: Data
        if header.destination == .broadcast {
            plaintext = packet.payload
        } else {
            guard let session = sessions[header.source],
                  let opened = try? session.open(packet.payload, header: header)
            else {
                logger.error("cannot open control from \(header.source.description, privacy: .public)")
                return
            }
            plaintext = opened
        }
        guard let message = try? ControlMessage.decode(plaintext) else { return }
        handle(message, from: header.source)
    }

    private func handle(_ message: ControlMessage, from source: NodeID) {
        switch message {
        case .roomAnnounce(let announce):
            roomsSeen[announce.roomID] = (announce, Date())
            refreshRooms()
            if announce.roomID == rejoinRoom, hosted == nil, joined == nil, joinState != .requested(announce.roomID) {
                logger.notice("rejoining room \(announce.roomID) after relaunch")
                requestJoin(announce)
            }
            if var room = joined, room.id == announce.roomID, room.host != source,
               announce.host == source, announce.verifyProof(roomKey: room.roomKey),
               room.members.contains(where: { $0.id == source }) {
                room.host = source
                joined = room
                logger.notice("host of room \(room.id) is now \(source.description, privacy: .public)")
            }
            if let room = hosted, room.id == announce.roomID, source < nodeID,
               announce.host == source, announce.verifyProof(roomKey: room.roomKey),
               room.members.contains(where: { $0.id == source }) {
                joined = JoinedRoom(
                    id: room.id,
                    name: room.name,
                    host: source,
                    members: room.members,
                    roomKey: room.roomKey
                )
                hosted = nil
                syncRoomKey()
                syncStreams()
                logger.notice("yielded room \(room.id) to \(source.description, privacy: .public)")
            }

        case .joinRequest(let request):
            guard var room = hosted, room.id == request.roomID else { return }
            let returning = room.members.contains { $0.id == source }
            if returning { _ = room.remove(source) }
            room.request(from: Member(id: source, name: request.name))
            hosted = room
            if returning { accept(source) }

        case .joinAccept(let accept):
            guard joinState == .requested(accept.roomID) else { return }
            joined = JoinedRoom(
                id: accept.roomID,
                name: roomsSeen[accept.roomID]?.announce.name ?? "Room",
                host: source,
                members: accept.members,
                roomKey: accept.roomKey
            )
            joinState = .idle
            rejoinRoom = nil
            syncRoomKey()
            startCall()

        case .joinReject(let roomID, let reason):
            guard joinState == .requested(roomID) else { return }
            joinState = .rejected(reason)

        case .memberList(let roomID, let members, let roomKey):
            guard var room = joined, room.host == source, room.id == roomID else { return }
            room.members = members
            room.roomKey = roomKey
            joined = room
            syncRoomKey()
            syncStreams()

        case .leave(let roomID):
            if var room = joined, room.host == source, room.id == roomID {
                room.members.removeAll { $0.id == source }
                joined = room
                syncStreams()
                evaluateHost()
            } else if var room = hosted, room.id == roomID, let update = room.remove(source) {
                hosted = room
                syncRoomKey()
                syncStreams()
                for member in room.members where member.id != nodeID {
                    sendControl(update, to: member.id)
                }
            }
        }
    }

    // MARK: - Peers

    private func makeSession(for record: PeerRecord) {
        do {
            sessions[record.id] = try PairwiseSession(
                identity: identity,
                remoteID: record.id,
                remoteAgreementPublicKey: record.agreementPublicKey
            )
        } catch {
            logger.error("session for \(record.id.description, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func upsertPeer(id: NodeID, name: String, lastSeen: Date) {
        let links = displayLinks(for: id)
        if let index = peers.firstIndex(where: { $0.id == id }) {
            peers[index].name = name
            peers[index].lastSeen = lastSeen
            if peers[index].links != links {
                peers[index].links = links
                logger.notice("peer \(name, privacy: .public) links \(links.map(\.description).joined(separator: " "), privacy: .public)")
            }
        } else {
            logger.notice("peer \(name, privacy: .public) links \(links.map(\.description).joined(separator: " "), privacy: .public)")
            peers.append(PeerSummary(id: id, name: name, lastSeen: lastSeen, links: links))
            sortPeers()
        }
    }

    private func sortPeers() {
        peers.sort { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }

    /// Stable order for the UI; `mesh.links(to:)` orders by live cost and would reshuffle every second.
    private func displayLinks(for id: NodeID) -> [LinkID] {
        mesh.links(to: id).sorted { $0.description < $1.description }
    }

    private func rebuildPeerLinks() {
        for index in peers.indices { peers[index].links = displayLinks(for: peers[index].id) }
    }

    private func refreshPaths(now: Date = Date(), force: Bool = false) {
        guard force || now.timeIntervalSince(lastPathRefresh) >= 0.25 else { return }
        lastPathRefresh = now
        var info: [NodeID: PathInfo] = [:]
        for id in mesh.reachable() {
            let route = mesh.route(to: id)
            let nextLink = mesh.nextLink(to: id)
            let metrics = nextLink.flatMap { mesh.metrics(for: $0, now: now) }
            info[id] = PathInfo(
                hops: route?.hops ?? 1,
                costMs: route?.cost ?? metrics?.cost ?? 0,
                nextLink: nextLink,
                latencyMs: metrics?.latencyMs ?? 0,
                lossFraction: metrics?.lossFraction ?? 0,
                jitterMs: metrics?.jitterMs ?? 0
            )
        }
        for (id, path) in info where path.hops != pathInfo[id]?.hops || path.nextLink != pathInfo[id]?.nextLink {
            logger.notice("path to \(id.description, privacy: .public): \(path.hops) hops via \(path.nextLink?.description ?? "-", privacy: .public) cost \(Int(path.costMs)) ms")
        }
        pathInfo = info
    }

    private func prune() {
        let now = Date()
        _ = mesh.expire(now: now)
        refreshPaths(now: now, force: true)
        peers.removeAll { now.timeIntervalSince($0.lastSeen) > Self.peerTimeout }
        evaluateHost()
        if rejoinRoom != nil, now > rejoinDeadline { rejoinRoom = nil }
        let currentRoom = (hosted?.id ?? joined?.id).map(String.init)
        if UserDefaults.standard.string(forKey: Self.rejoinKey) != currentRoom {
            UserDefaults.standard.set(currentRoom, forKey: Self.rejoinKey)
        }
        refreshRooms(now: now)
        guard inCall, let audio else { return }
        voiceStats = Dictionary(
            uniqueKeysWithValues: streamPeers.compactMap { id in audio.stats(for: id).map { (id, $0) } }
        )
        ioLatencyMs = audio.ioLatencyMs
    }

    func trustKeyChange() {
        guard let warning = keyWarning else { return }
        if let record = try? peerStore.trust(warning.hello, now: Date()) {
            makeSession(for: record)
            PeerStoreFile.save(peerStore)
        }
        keyWarning = nil
    }

    func dismissKeyWarning() {
        keyWarning = nil
    }

    // MARK: - Rooms

    private func refreshRooms(now: Date = Date()) {
        roomsSeen = roomsSeen.filter { now.timeIntervalSince($0.value.at) <= Self.roomTimeout }
        rooms = roomsSeen.values
            .map(\.announce)
            .filter { $0.host != nodeID && $0.roomID != joined?.id }
            .sorted { $0.name == $1.name ? $0.roomID < $1.roomID : $0.name < $1.name }
    }

    private func reachableMembers() -> [Member] {
        currentMembers.filter { member in
            member.id == nodeID || peers.contains { $0.id == member.id }
        }
    }

    /// The lowest reachable member hosts, so a lost host is replaced without a vote.
    private func evaluateHost() {
        guard let room = joined else { return }
        let hostGone = !room.members.contains { $0.id == room.host }
            || !peers.contains { $0.id == room.host }
        guard hostGone, nodeID == reachableMembers().map(\.id).min() else { return }
        let takeover = HostRoom(
            takingOver: room.id,
            name: room.name,
            host: Member(id: nodeID, name: displayName),
            members: room.members,
            roomKey: room.roomKey
        )
        hosted = takeover
        joined = nil
        syncRoomKey()
        syncStreams()
        broadcastControl(.roomAnnounce(takeover.announce))
        logger.notice("took over room \(takeover.id)")
    }

    private func announceHostedRoom() {
        guard let hosted else { return }
        broadcastControl(.roomAnnounce(hosted.announce))
    }

    func hostRoom(name: String) {
        hosted = HostRoom(
            id: RoomID.random(in: 1...RoomID.max),
            name: name,
            host: Member(id: nodeID, name: displayName)
        )
        joined = nil
        syncRoomKey()
        startCall()
    }


    func requestJoin(_ room: RoomAnnounce) {
        sendControl(
            .joinRequest(JoinRequest(roomID: room.roomID, name: displayName, codeProof: nil)),
            to: room.host
        )
        joinState = .requested(room.roomID)
    }

    func accept(_ id: NodeID) {
        guard var room = hosted, let accept = room.accept(id) else { return }
        hosted = room
        syncRoomKey()
        syncStreams()
        sendControl(.joinAccept(accept), to: id)
        for member in room.members where member.id != nodeID && member.id != id {
            sendControl(
                .memberList(roomID: room.id, members: room.members, roomKey: room.roomKey),
                to: member.id
            )
        }
    }

    func reject(_ id: NodeID) {
        guard let roomID = hosted?.id else { return }
        hosted?.reject(id)
        sendControl(.joinReject(roomID: roomID, reason: "Declined"), to: id)
    }

    func toggleMute() { muted.toggle() }

    /// Leaving as host does not end the room: members drop the host and elect a new one.
    func leaveRoom() {
        if let hosted {
            for member in hosted.members where member.id != nodeID {
                sendControl(.leave(roomID: hosted.id), to: member.id)
            }
        } else if let joined {
            sendControl(.leave(roomID: joined.id), to: joined.host)
        }
        hosted = nil
        joined = nil
        joinState = .idle
        rejoinRoom = nil
        UserDefaults.standard.removeObject(forKey: Self.rejoinKey)
        stopCall()
    }

    // MARK: - Voice

    /// In a call with other members, none of them reachable.
    var disconnected: Bool {
        let others = currentMembers.filter { $0.id != nodeID }
        return inCall && !others.isEmpty && !others.contains { pathInfo[$0.id] != nil }
    }

    private var currentMembers: [Member] { hosted?.members ?? joined?.members ?? [] }

    private func syncRoomKey() {
        roomKey = (hosted?.roomKey ?? joined?.roomKey).flatMap { try? RoomKey(data: $0) }
    }

    private func startCall() {
        if audio == nil {
            // An AsyncStream keeps frames in capture order; a Task per frame would let the main actor
            // stamp sequence numbers out of order, and the receiver would drop the reordered frames.
            let (frames, continuation) = AsyncStream.makeStream(of: Data.self)
            audio = AudioEngine { frame in continuation.yield(frame) }
            outgoingVoice = Task { @MainActor [weak self] in
                for await frame in frames { self?.sendVoice(frame) }
            }
        }
        guard let audio else { return }
        audio.jitterTargetDepth = jitterTargetDepth
        do {
            try audio.start()
        } catch {
            // Kept alive on failure so a route change can retry through the engine's own observers.
            logger.error("audio start failed: \(error.localizedDescription, privacy: .public)")
        }
        inCall = true
        ioLatencyMs = audio.ioLatencyMs
        syncStreams()
    }

    private func stopCall() {
        outgoingVoice?.cancel()
        outgoingVoice = nil
        // Engine teardown takes a noticeable moment; the UI must not wait for it.
        if let audio {
            Task.detached(priority: .userInitiated) { audio.stop() }
        }
        audio = nil
        inCall = false
        voiceStats = [:]
        streamPeers = []
        roomKey = nil
    }

    private func syncStreams() {
        let wanted = Set(currentMembers.map(\.id)).subtracting([nodeID])
        for id in wanted.subtracting(streamPeers) { audio?.addStream(id) }
        for id in streamPeers.subtracting(wanted) { audio?.removeStream(id) }
        streamPeers = wanted
    }

    private func nextVoiceSequence(for member: NodeID) -> UInt32 {
        let next = (voiceSequences[member] ?? UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970 * 50))) &+ 1
        voiceSequences[member] = next
        return next
    }

    /// One sealed copy per member: a relay must not dedup-drop the copy addressed to a different member, so each copy carries its own sequence.
    private func sendVoice(_ frame: Data) {
        guard inCall, !muted, let roomKey else { return }
        let now = Date()
        for member in currentMembers where member.id != nodeID {
            guard let link = mesh.nextLink(to: member.id) else { continue }
            let header = PacketHeader(
                type: .voice, source: nodeID, destination: member.id,
                stream: 1, sequence: nextVoiceSequence(for: member.id)
            )
            guard let sealed = try? roomKey.seal(frame, header: header) else { continue }
            let data = Packet(header: header, payload: sealed).encode()
            transmit(data, over: link)
            guard let loss = mesh.metrics(for: link, now: now)?.lossFraction,
                  loss > multipathLossThreshold,
                  let alternate = mesh.alternateLink(to: member.id), alternate != link
            else { continue }
            transmit(data, over: alternate)
        }
    }

    private func receiveVoice(_ packet: Packet) {
        let header = packet.header
        guard inCall, let roomKey, currentMembers.contains(where: { $0.id == header.source })
        else { return }
        // Silent drop covers the rotation window where the sender still holds the previous room key.
        guard let frame = try? roomKey.open(packet.payload, header: header) else { return }
        audio?.push(header.source, sequence: header.sequence, frame: frame)
    }
}

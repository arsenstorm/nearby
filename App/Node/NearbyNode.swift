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
    let host: NodeID
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

/// Owns identity, transports, peers, and room state. All UI reads go through this object.
@MainActor @Observable
final class NearbyNode {
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

    private static let displayNameKey = "displayName"
    private static let peerTimeout: TimeInterval = 5
    private static let roomTimeout: TimeInterval = 6

    private let logger = Logger(subsystem: "com.shkrumelyak.nearby", category: "node")
    private let identity: Identity
    private var storedDisplayName: String
    private var peerStore: PeerStore
    private let transports: [TransportID: any Transport]
    private var knownLinks: Set<LinkID> = []
    private var linkNode: [LinkID: NodeID] = [:]
    private var sessions: [NodeID: PairwiseSession] = [:]
    private var roomsSeen: [RoomID: (announce: RoomAnnounce, at: Date)] = [:]
    private var dedup = Dedup()
    // Seeded from the clock so a relaunch does not restart below peers' dedup windows.
    private var sequence = UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970 * 50))
    private var voiceSequence = UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970 * 50))
    private var audio: AudioEngine?
    private var roomKey: RoomKey?
    private var streamPeers: Set<NodeID> = []
    private var started = false
    private var eventTasks: [TransportID: Task<Void, Never>] = [:]
    private var timers: [Task<Void, Never>] = []

    init() {
        let identity = IdentityStore.loadOrCreate()
        self.identity = identity
        self.nodeID = identity.nodeID
        self.storedDisplayName =
            UserDefaults.standard.string(forKey: Self.displayNameKey) ?? UIDevice.current.name
        self.peerStore = PeerStoreFile.load()
        let serviceName = identity.nodeID.description
        self.transports = [
            .lan: DatagramTransport(id: .lan, peerToPeer: false, serviceName: serviceName),
            .p2pWiFi: DatagramTransport(id: .p2pWiFi, peerToPeer: true, serviceName: serviceName),
        ]
        for id in TransportID.allCases {
            let supported = transports[id] != nil
            transportStates[id] = TransportState(
                supported: supported,
                enabled: supported && Self.enabledSetting(id),
                active: false,
                linkCount: 0
            )
        }
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
    }

    func setTransport(_ id: TransportID, enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey(id))
        transportStates[id]?.enabled = enabled
        guard let transport = transports[id] else { return }
        if enabled {
            if started { startTransport(id, transport) }
        } else {
            Task { await transport.stop() }
            for link in knownLinks where link.transport == id {
                knownLinks.remove(link)
                linkNode[link] = nil
            }
            transportStates[id]?.active = false
            transportStates[id]?.linkCount = 0
            rebuildPeerLinks()
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
        knownLinks.filter { transportStates[$0.transport].map { $0.enabled && $0.active } ?? false }
    }

    private func transmit(_ data: Data, over link: LinkID) {
        guard let transport = transports[link.transport] else { return }
        Task { try? await transport.send(data, over: link) }
    }

    private func route(to node: NodeID) -> LinkID? {
        let order = TransportID.allCases
        return linkNode
            .filter { $0.value == node }
            .map(\.key)
            .min {
                let a = order.firstIndex(of: $0.transport) ?? order.count
                let b = order.firstIndex(of: $1.transport) ?? order.count
                return a == b ? $0.endpoint < $1.endpoint : a < b
            }
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
        guard let link = route(to: destination) else {
            logger.error("no route to \(destination.description, privacy: .public), dropping control")
            return
        }
        transmit(Packet(header: header, payload: sealed).encode(), over: link)
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

    // MARK: - Receiving

    private func handle(_ event: TransportEvent) {
        switch event {
        case .linkUp(let link):
            knownLinks.insert(link)
            transportStates[link.transport]?.linkCount += 1
            if let data = helloPacket() { transmit(data, over: link) }
        case .linkDown(let link):
            knownLinks.remove(link)
            linkNode[link] = nil
            if let count = transportStates[link.transport]?.linkCount {
                transportStates[link.transport]?.linkCount = max(0, count - 1)
            }
            rebuildPeerLinks()
        case .received(let data, let link):
            receive(data, from: link)
        }
    }

    private func receive(_ data: Data, from link: LinkID) {
        guard let packet = Packet(decoding: data) else { return }
        let header = packet.header
        guard header.source != nodeID else { return }
        guard dedup.check(source: header.source, stream: header.stream, sequence: header.sequence)
        else { return }
        guard header.destination == .broadcast || header.destination == nodeID else { return }

        switch header.type {
        case .hello:
            receiveHello(packet.payload, from: link)
        case .control:
            receiveControl(packet)
        case .voice:
            receiveVoice(packet)
        case .probe, .ack, .linkState:
            break
        }
    }

    private func receiveHello(_ payload: Data, from link: LinkID) {
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
        linkNode[link] = hello.nodeID
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

        case .joinRequest(let request):
            guard hosted?.id == request.roomID else { return }
            hosted?.request(from: Member(id: source, name: request.name))

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

        case .joinReject(let roomID, let reason):
            syncRoomKey()
            startCall()
            guard joinState == .requested(roomID) else { return }
            joinState = .rejected(reason)

        case .memberList(let roomID, let members, let roomKey):
            guard var room = joined, room.host == source, room.id == roomID else { return }
            room.members = members
            room.roomKey = roomKey
            joined = room

        case .leave(let roomID):
            syncRoomKey()
            syncStreams()
            if let room = joined, room.host == source, room.id == roomID {
                joined = nil
            } else if var room = hosted, room.id == roomID, let update = room.remove(source) {
                hosted = room
                stopCall()
                for member in room.members where member.id != nodeID {
                    sendControl(update, to: member.id)
                syncRoomKey()
                syncStreams()
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

    private func links(for node: NodeID) -> [LinkID] {
        linkNode.filter { $0.value == node }.map(\.key).sorted { $0.description < $1.description }
    }

    private func upsertPeer(id: NodeID, name: String, lastSeen: Date) {
        let links = links(for: id)
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

    private func rebuildPeerLinks() {
        for index in peers.indices { peers[index].links = links(for: peers[index].id) }
    }

    private func prune() {
        let now = Date()
        peers.removeAll { now.timeIntervalSince($0.lastSeen) > Self.peerTimeout }
        refreshRooms(now: now)
    }

        guard inCall, let audio else { return }
        voiceStats = Dictionary(
            uniqueKeysWithValues: streamPeers.compactMap { id in audio.stats(for: id).map { (id, $0) } }
        )
        ioLatencyMs = audio.ioLatencyMs
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
            .filter { $0.host != nodeID }
            .sorted { $0.name == $1.name ? $0.roomID < $1.roomID : $0.name < $1.name }
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
    }

        syncRoomKey()
        startCall()
    func closeRoom() {
        guard let hosted else { return }
        for member in hosted.members where member.id != nodeID {
            sendControl(.leave(roomID: hosted.id), to: member.id)
        }
        self.hosted = nil
    }

        stopCall()
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
        sendControl(.joinAccept(accept), to: id)
        for member in room.members where member.id != nodeID && member.id != id {
        syncRoomKey()
        syncStreams()
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

    func leaveRoom() {
        if let joined { sendControl(.leave(roomID: joined.id), to: joined.host) }
        joined = nil
        joinState = .idle
    }
}
        stopCall()
    }

    // MARK: - Voice

    private var currentMembers: [Member] { hosted?.members ?? joined?.members ?? [] }

    private func syncRoomKey() {
        roomKey = (hosted?.roomKey ?? joined?.roomKey).flatMap { try? RoomKey(data: $0) }
    }

    private func startCall() {
        if audio == nil {
            // ponytail: one main-actor hop per 20 ms frame; move sealing off the main actor when profiling says so.
            audio = AudioEngine { [weak self] frame in
                Task { @MainActor in self?.sendVoice(frame) }
            }
        }
        guard let audio else { return }
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
        audio?.stop()
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

    private func nextVoiceSequence() -> UInt32 {
        voiceSequence &+= 1
        return voiceSequence
    }

    /// Broadcast: every neighbour gets the frame once and non-members cannot open it. Per-member mesh routing arrives in a later phase.
    private func sendVoice(_ frame: Data) {
        guard inCall, !muted, let roomKey else { return }
        let header = PacketHeader(
            type: .voice, source: nodeID, destination: .broadcast,
            stream: 1, sequence: nextVoiceSequence()
        )
        guard let sealed = try? roomKey.seal(frame, header: header) else { return }
        let data = Packet(header: header, payload: sealed).encode()
        for link in sendableLinks { transmit(data, over: link) }
    }

    private func receiveVoice(_ packet: Packet) {
        let header = packet.header
        guard inCall, let roomKey, currentMembers.contains(where: { $0.id == header.source })
        else { return }
        // Silent drop covers the rotation window where the sender still holds the previous room key.
        guard let frame = try? roomKey.open(packet.payload, header: header) else { return }
        audio?.push(header.source, sequence: header.sequence, frame: frame)

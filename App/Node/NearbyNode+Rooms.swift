import Foundation
import NearbyCore

/// Room discovery, membership, host handover, and control-message handling.
extension NearbyNode {
    // MARK: - Control messages

    func handle(_ message: ControlMessage, from source: NodeID) {
        switch message {
        case .roomAnnounce(let announce):
            receiveRoomAnnounce(announce, from: source)
        case .joinRequest(let request):
            receiveJoinRequest(request, from: source)
        case .joinAccept(let accept):
            receiveJoinAccept(accept, from: source)
        case .joinReject(let roomID, let reason):
            receiveJoinReject(roomID: roomID, reason: reason)
        case .memberList(let roomID, let members, let roomKey):
            receiveMemberList(roomID: roomID, members: members, roomKey: roomKey, from: source)
        case .leave(let roomID):
            receiveLeave(roomID: roomID, from: source)
        }
    }

    private func receiveRoomAnnounce(_ announce: RoomAnnounce, from source: NodeID) {
        roomsSeen[announce.roomID] = (announce, Date())
        refreshRooms()
        rejoinIfAnnounced(announce)
        followNewHost(announce, from: source)
        yieldHostingIfOutranked(announce, from: source)
    }

    private func rejoinIfAnnounced(_ announce: RoomAnnounce) {
        guard announce.roomID == rejoinRoom, hosted == nil, joined == nil else { return }
        guard joinState != .requested(announce.roomID) else { return }
        logger.notice("rejoining room \(announce.roomID) after relaunch")
        requestJoin(announce)
    }

    /// A room member announcing itself as host, with proof it holds the room key.
    private func verifiedHostClaim(_ announce: RoomAnnounce, by source: NodeID, members: [Member], roomKey: Data) -> Bool {
        announce.host == source
            && announce.verifyProof(roomKey: roomKey)
            && members.contains { $0.id == source }
    }

    private func followNewHost(_ announce: RoomAnnounce, from source: NodeID) {
        guard var room = joined, room.id == announce.roomID, room.host != source else { return }
        guard verifiedHostClaim(announce, by: source, members: room.members, roomKey: room.roomKey) else { return }
        room.host = source
        joined = room
        logger.notice("host of room \(room.id) is now \(source.description, privacy: .public)")
    }

    private func yieldHostingIfOutranked(_ announce: RoomAnnounce, from source: NodeID) {
        guard let room = hosted, room.id == announce.roomID, source < nodeID else { return }
        guard verifiedHostClaim(announce, by: source, members: room.members, roomKey: room.roomKey) else { return }
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

    private func receiveJoinRequest(_ request: JoinRequest, from source: NodeID) {
        guard var room = hosted, room.id == request.roomID else { return }
        let returning = room.members.contains { $0.id == source }
        if returning { _ = room.remove(source) }
        room.request(from: Member(id: source, name: request.name))
        hosted = room
        if returning { accept(source) }
    }

    private func receiveJoinAccept(_ accept: JoinAccept, from source: NodeID) {
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
    }

    private func receiveJoinReject(roomID: RoomID, reason: String) {
        guard joinState == .requested(roomID) else { return }
        joinState = .rejected(reason)
    }

    private func receiveMemberList(roomID: RoomID, members: [Member], roomKey: Data, from source: NodeID) {
        guard var room = joined, room.host == source, room.id == roomID else { return }
        room.members = members
        room.roomKey = roomKey
        joined = room
        syncRoomKey()
        syncStreams()
    }

    private func receiveLeave(roomID: RoomID, from source: NodeID) {
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

    // MARK: - Rooms

    func refreshRooms(now: Date = Date()) {
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
    func evaluateHost() {
        guard let room = joined else { return }
        let hostGone = !room.members.contains { $0.id == room.host }
            || !peers.contains { $0.id == room.host }
        guard hostGone else { return hostMissingSince = nil }
        // A relay or a Wi-Fi/cellular switch can hide the host for 10-20 s; only a longer absence is a real loss.
        let missingSince = hostMissingSince ?? Date()
        hostMissingSince = missingSince
        guard Date().timeIntervalSince(missingSince) >= Self.takeoverGrace,
              nodeID == reachableMembers().map(\.id).min() else { return }
        hostMissingSince = nil
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

    func announceHostedRoom() {
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
}

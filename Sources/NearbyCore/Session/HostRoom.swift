import Foundation

/// Host-side room state: membership, pending join requests, and the shared room key.
public struct HostRoom: Sendable {
    public let id: RoomID
    public var name: String
    public let host: Member
    public private(set) var members: [Member]
    public private(set) var pending: [Member]
    public private(set) var roomKey: Data

    public init(id: RoomID, name: String, host: Member) {
        self.id = id
        self.name = name
        self.host = host
        self.members = [host]
        self.pending = []
        self.roomKey = Self.generateKey()
    }

    /// Takes over an existing room after the host was lost: same id, same members, same key, so voice never pauses.
    public init(takingOver id: RoomID, name: String, host: Member, members: [Member], roomKey: Data) {
        self.id = id
        self.name = name
        self.host = host
        self.members = members.contains(where: { $0.id == host.id }) ? members : [host] + members
        self.pending = []
        self.roomKey = roomKey
    }

    /// Unsigned: the node broadcasting it signs with its identity key, which HostRoom does not hold.
    public var announce: RoomAnnounce {
        RoomAnnounce(roomID: id, name: name, host: host.id, hasCode: false)
    }

    public mutating func request(from member: Member) {
        guard !members.contains(where: { $0.id == member.id }),
              !pending.contains(where: { $0.id == member.id }) else { return }
        pending.append(member)
    }

    public mutating func accept(_ id: NodeID) -> JoinAccept? {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return nil }
        let member = pending.remove(at: index)
        members.append(member)
        roomKey = Self.generateKey()
        return JoinAccept(roomID: self.id, roomKey: roomKey, members: members)
    }

    public mutating func reject(_ id: NodeID) {
        pending.removeAll { $0.id == id }
    }

    public mutating func remove(_ id: NodeID) -> ControlMessage? {
        guard id != host.id, let index = members.firstIndex(where: { $0.id == id }) else { return nil }
        members.remove(at: index)
        roomKey = Self.generateKey()
        return .memberList(roomID: self.id, members: members, roomKey: roomKey)
    }

    private static func generateKey() -> Data {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }
        return Data(bytes)
    }
}

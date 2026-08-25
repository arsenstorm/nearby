import CryptoKit
import Foundation

public typealias RoomID = UInt64

public struct RoomAnnounce: Codable, Sendable, Equatable {
    public var roomID: RoomID
    public var name: String
    public var host: NodeID
    public var hasCode: Bool
    /// HMAC over (roomID, host) keyed by the room key. Announces are plaintext broadcasts, so members use it to reject a forged host claim.
    public var proof: Data?

    public init(roomID: RoomID, name: String, host: NodeID, hasCode: Bool, proof: Data? = nil) {
        self.roomID = roomID
        self.name = name
        self.host = host
        self.hasCode = hasCode
        self.proof = proof
    }

    public static func proof(roomID: RoomID, host: NodeID, roomKey: Data) -> Data {
        var message = withUnsafeBytes(of: roomID.bigEndian) { Data($0) }
        message.append(host.bytes)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: roomKey))).prefix(16)
    }

    public func verifyProof(roomKey: Data) -> Bool {
        proof == Self.proof(roomID: roomID, host: host, roomKey: roomKey)
    }
}

public struct JoinRequest: Codable, Sendable, Equatable {
    public var roomID: RoomID
    public var name: String
    public var codeProof: Data?

    public init(roomID: RoomID, name: String, codeProof: Data? = nil) {
        self.roomID = roomID
        self.name = name
        self.codeProof = codeProof
    }
}

public struct Member: Codable, Sendable, Equatable, Hashable {
    public var id: NodeID
    public var name: String

    public init(id: NodeID, name: String) {
        self.id = id
        self.name = name
    }
}

public struct JoinAccept: Codable, Sendable, Equatable {
    public var roomID: RoomID
    public var roomKey: Data
    public var members: [Member]

    public init(roomID: RoomID, roomKey: Data, members: [Member]) {
        self.roomID = roomID
        self.roomKey = roomKey
        self.members = members
    }
}

public enum ControlMessage: Codable, Sendable, Equatable {
    case roomAnnounce(RoomAnnounce)
    case joinRequest(JoinRequest)
    case joinAccept(JoinAccept)
    case joinReject(roomID: RoomID, reason: String)
    case memberList(roomID: RoomID, members: [Member], roomKey: Data)
    case leave(roomID: RoomID)

    public func encode() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> ControlMessage {
        try JSONDecoder().decode(ControlMessage.self, from: data)
    }
}

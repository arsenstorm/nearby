import Foundation

public typealias RoomID = UInt64

public struct RoomAnnounce: Codable, Sendable, Equatable {
    public var roomID: RoomID
    public var name: String
    public var host: NodeID
    public var hasCode: Bool
    /// Ed25519 signature by `host` over `signedBytes`. Announces are plaintext broadcasts, so members
    /// verify it against the host's known signing key. Room-key possession, which every member has,
    /// no longer stands in for host identity.
    public var signature: Data?

    public init(roomID: RoomID, name: String, host: NodeID, hasCode: Bool, signature: Data? = nil) {
        self.roomID = roomID
        self.name = name
        self.host = host
        self.hasCode = hasCode
        self.signature = signature
    }

    public var signedBytes: Data {
        var d = withUnsafeBytes(of: roomID.bigEndian) { Data($0) }
        d.append(host.bytes)
        d.append(hasCode ? 1 : 0)
        d.append(Data(name.utf8))
        return d
    }

    public func signed(by identity: Identity) -> RoomAnnounce {
        var copy = self
        copy.signature = try? identity.sign(signedBytes)
        return copy
    }

    public func verify(signingPublicKey: Data) -> Bool {
        guard let signature else { return false }
        return Identity.verify(signature: signature, for: signedBytes, signingPublicKey: signingPublicKey)
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

    /// Only roomAnnounce may travel as a plaintext broadcast; it self-authenticates with the host's
    /// signature. Every other message must arrive sealed over a pairwise session, so the receiver
    /// rejects it on the broadcast path.
    public var isBroadcastable: Bool {
        if case .roomAnnounce = self { return true }
        return false
    }

    public func encode() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> ControlMessage {
        try JSONDecoder().decode(ControlMessage.self, from: data)
    }
}

import Foundation

public struct Hello: Codable, Sendable, Equatable {
    public var nodeID: NodeID
    public var signingPublicKey: Data
    public var ephemeralPublicKey: Data
    public var name: String
    public var timestampMs: UInt64
    public var signature: Data

    private static func signedBytes(
        nodeID: NodeID, timestampMs: UInt64, ephemeralPublicKey: Data, name: String
    ) -> Data {
        var d = Data()
        d.append(nodeID.bytes)
        d.append(withUnsafeBytes(of: timestampMs.bigEndian) { Data($0) })
        d.append(ephemeralPublicKey)
        d.append(Data(name.utf8))
        return d
    }

    public init(identity: Identity, name: String, timestampMs: UInt64) throws {
        let nodeID = identity.nodeID
        let ephemeralPublicKey = identity.ephemeralPublicKey
        let bytes = Hello.signedBytes(
            nodeID: nodeID, timestampMs: timestampMs, ephemeralPublicKey: ephemeralPublicKey, name: name
        )
        self.nodeID = nodeID
        self.signingPublicKey = identity.signingPublicKey
        self.ephemeralPublicKey = ephemeralPublicKey
        self.name = name
        self.timestampMs = timestampMs
        self.signature = try identity.sign(bytes)
    }

    public func verify() -> Bool {
        guard NodeID(publicKey: signingPublicKey) == nodeID else { return false }
        let bytes = Hello.signedBytes(
            nodeID: nodeID, timestampMs: timestampMs, ephemeralPublicKey: ephemeralPublicKey, name: name
        )
        return Identity.verify(signature: signature, for: bytes, signingPublicKey: signingPublicKey)
    }

    public func encode() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> Hello {
        try JSONDecoder().decode(Hello.self, from: data)
    }
}

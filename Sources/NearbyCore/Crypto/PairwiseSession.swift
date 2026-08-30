import CryptoKit
import Foundation

public struct PairwiseSession: Sendable {
    public let local: NodeID
    public let remote: NodeID
    public let remoteEphemeralPublicKey: Data

    private let key: SymmetricKey

    public init(identity: Identity, remoteID: NodeID, remoteEphemeralPublicKey: Data) throws {
        self.local = identity.nodeID
        self.remote = remoteID
        self.remoteEphemeralPublicKey = remoteEphemeralPublicKey
        let remoteKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteEphemeralPublicKey)
        let shared = try identity.ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: remoteKey)
        let lo = min(local, remote)
        let hi = max(local, remote)
        let localEphemeral = identity.ephemeralPublicKey
        // Both ephemerals in the transcript so a swapped key on either side yields a different session key.
        let ephemerals = [localEphemeral, remoteEphemeralPublicKey].sorted { $0.lexicographicallyPrecedes($1) }
        self.key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: lo.bytes + hi.bytes,
            sharedInfo: Data("nearby-pairwise-v2".utf8) + ephemerals[0] + ephemerals[1],
            outputByteCount: 32
        )
    }

    public func seal(_ plaintext: Data, header: PacketHeader) throws -> Data {
        try AEAD.seal(plaintext, key: key, header: header)
    }

    public func open(_ sealed: Data, header: PacketHeader) throws -> Data {
        try AEAD.open(sealed, key: key, header: header)
    }
}

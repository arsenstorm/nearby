import CryptoKit
import Foundation

public struct PairwiseSession: Sendable {
    public let local: NodeID
    public let remote: NodeID

    private let key: SymmetricKey

    public init(identity: Identity, remoteID: NodeID, remoteAgreementPublicKey: Data) throws {
        self.local = identity.nodeID
        self.remote = remoteID
        let remoteKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteAgreementPublicKey)
        let shared = try identity.agreementPrivateKey.sharedSecretFromKeyAgreement(with: remoteKey)
        let lo = min(local, remote)
        let hi = max(local, remote)
        let salt = lo.bytes + hi.bytes
        self.key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("nearby-pairwise-v1".utf8),
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

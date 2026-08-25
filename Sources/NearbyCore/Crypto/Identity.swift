import CryptoKit
import Foundation

public enum IdentityError: Error, Sendable {
    case badSeed
}

public struct Identity: Sendable {
    public let seed: Data

    private let signingKey: Curve25519.Signing.PrivateKey
    private let agreementKey: Curve25519.KeyAgreement.PrivateKey

    public init() {
        let seed = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try! self.init(seed: seed)
    }

    public init(seed: Data) throws {
        guard seed.count == 32 else { throw IdentityError.badSeed }
        self.seed = seed
        self.signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let agreementSeed = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: seed),
            info: Data("nearby-agreement-v1".utf8),
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
        self.agreementKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: agreementSeed)
    }

    public var nodeID: NodeID { NodeID(publicKey: signingPublicKey) }

    public var signingPublicKey: Data { signingKey.publicKey.rawRepresentation }

    public var agreementPublicKey: Data { agreementKey.publicKey.rawRepresentation }

    public func sign(_ data: Data) throws -> Data {
        try signingKey.signature(for: data)
    }

    public static func verify(signature: Data, for data: Data, signingPublicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signingPublicKey) else {
            return false
        }
        return key.isValidSignature(signature, for: data)
    }

    var agreementPrivateKey: Curve25519.KeyAgreement.PrivateKey { agreementKey }
}

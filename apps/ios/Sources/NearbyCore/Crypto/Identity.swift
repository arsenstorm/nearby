import CryptoKit
import Foundation

public enum IdentityError: Error, Sendable {
    case badSeed
}

public struct Identity: Sendable {
    public let seed: Data

    private let signingKey: Curve25519.Signing.PrivateKey
    // Fresh per process, never persisted: a seized identity cannot decrypt traffic from earlier launches.
    private let ephemeralKey: Curve25519.KeyAgreement.PrivateKey

    public init() {
        let seed = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try! self.init(seed: seed)
    }

    public init(seed: Data) throws {
        guard seed.count == 32 else { throw IdentityError.badSeed }
        self.seed = seed
        self.signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        self.ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
    }

    public var nodeID: NodeID { NodeID(publicKey: signingPublicKey) }

    public var signingPublicKey: Data { signingKey.publicKey.rawRepresentation }

    public var ephemeralPublicKey: Data { ephemeralKey.publicKey.rawRepresentation }

    public func sign(_ data: Data) throws -> Data {
        try signingKey.signature(for: data)
    }

    public static func verify(signature: Data, for data: Data, signingPublicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signingPublicKey) else {
            return false
        }
        return key.isValidSignature(signature, for: data)
    }

    var ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey { ephemeralKey }
}

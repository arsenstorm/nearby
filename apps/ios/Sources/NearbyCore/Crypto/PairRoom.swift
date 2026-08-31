import CryptoKit
import Foundation

/// Rendezvous room shared by two nodes. Only someone who knows both IDs can name it.
public enum PairRoom {
    public static let domain = Data("nearby-pair-v1".utf8)

    /// hex(SHA256(lo.bytes ‖ hi.bytes)), lo/hi by NodeID order.
    public static func name(_ a: NodeID, _ b: NodeID) -> String {
        let (lo, hi) = a < b ? (a, b) : (b, a)
        return SHA256.hash(data: lo.bytes + hi.bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Ed25519 over domain ‖ nonce ‖ utf8(room); the server verifies it before granting a slot.
    public static func authSignature(identity: Identity, nonce: Data, room: String) throws -> Data {
        try identity.sign(domain + nonce + Data(room.utf8))
    }
}

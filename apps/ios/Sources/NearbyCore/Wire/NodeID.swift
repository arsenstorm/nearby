import CryptoKit
import Foundation

/// 8-byte node identifier: first 8 bytes of SHA256 of the identity signing public key.
public struct NodeID: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let raw: UInt64

    public static let broadcast = NodeID(raw: 0)

    public init(raw: UInt64) { self.raw = raw }

    public init(publicKey: Data) {
        let digest = SHA256.hash(data: publicKey)
        self.raw = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    public var bytes: Data { withUnsafeBytes(of: raw.bigEndian) { Data($0) } }

    public static func < (lhs: NodeID, rhs: NodeID) -> Bool { lhs.raw < rhs.raw }

    public var description: String { String(format: "%016llx", raw) }
}

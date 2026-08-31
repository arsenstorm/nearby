import CryptoKit
import Foundation

public enum RoomKeyError: Error, Sendable {
    case badLength
}

public struct RoomKey: Sendable, Equatable {
    private let key: SymmetricKey

    public init() {
        self.key = SymmetricKey(size: .bits256)
    }

    public init(data: Data) throws {
        guard data.count == 32 else { throw RoomKeyError.badLength }
        self.key = SymmetricKey(data: data)
    }

    public var data: Data {
        key.withUnsafeBytes { Data($0) }
    }

    public func seal(_ plaintext: Data, header: PacketHeader) throws -> Data {
        try AEAD.seal(plaintext, key: key, header: header)
    }

    public func open(_ sealed: Data, header: PacketHeader) throws -> Data {
        try AEAD.open(sealed, key: key, header: header)
    }

    public static func codeKey(code: String, roomID: UInt64) -> SymmetricKey {
        let digest = SHA256.hash(data: Data(code.utf8))
        let salt = withUnsafeBytes(of: roomID.bigEndian) { Data($0) }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(digest)),
            salt: salt,
            info: Data("nearby-roomcode-v1".utf8),
            outputByteCount: 32
        )
    }

    public static func == (lhs: RoomKey, rhs: RoomKey) -> Bool {
        lhs.data == rhs.data
    }
}

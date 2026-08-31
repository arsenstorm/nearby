import CryptoKit
import Foundation

public enum AEADError: Error, Sendable {
    case sealFailed, openFailed
}

public enum AEAD {
    /// 12-byte nonce: source id bytes 0..<7, then stream, then sequence big-endian 4 bytes.
    /// Reason: unique per (source, stream, sequence) under one key; the room key rotates on every membership change so a 32-bit sequence never wraps under one key. Pairwise keys are per launch, so a sequence that restarts at 0 on relaunch never repeats under one key.
    public static func nonce(for header: PacketHeader) -> Data {
        var d = Data(capacity: 12)
        d.append(header.source.bytes.prefix(7))
        d.append(header.stream)
        d.append(withUnsafeBytes(of: header.sequence.bigEndian) { Data($0) })
        return d
    }

    public static func seal(_ plaintext: Data, key: SymmetricKey, header: PacketHeader) throws -> Data {
        guard let nonce = try? ChaChaPoly.Nonce(data: nonce(for: header)) else {
            throw AEADError.sealFailed
        }
        guard let sealedBox = try? ChaChaPoly.seal(
            plaintext, using: key, nonce: nonce, authenticating: header.associatedData
        ) else {
            throw AEADError.sealFailed
        }
        return sealedBox.ciphertext + sealedBox.tag
    }

    public static func open(_ sealed: Data, key: SymmetricKey, header: PacketHeader) throws -> Data {
        guard sealed.count >= 16 else { throw AEADError.openFailed }
        let ciphertext = sealed.prefix(sealed.count - 16)
        let tag = sealed.suffix(16)
        guard let nonce = try? ChaChaPoly.Nonce(data: nonce(for: header)) else {
            throw AEADError.openFailed
        }
        guard let sealedBox = try? ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        else {
            throw AEADError.openFailed
        }
        guard let plaintext = try? ChaChaPoly.open(
            sealedBox, using: key, authenticating: header.associatedData
        ) else {
            throw AEADError.openFailed
        }
        return plaintext
    }
}

import CryptoKit
import Foundation

/// Attribute types from RFC 8489 §14 and RFC 8656 §18.
public enum STUNAttribute {
    public static let mappedAddress: UInt16 = 0x0001
    public static let username: UInt16 = 0x0006
    public static let messageIntegrity: UInt16 = 0x0008
    public static let errorCode: UInt16 = 0x0009
    public static let channelNumber: UInt16 = 0x000C
    public static let lifetime: UInt16 = 0x000D
    public static let xorPeerAddress: UInt16 = 0x0012
    public static let data: UInt16 = 0x0013
    public static let realm: UInt16 = 0x0014
    public static let nonce: UInt16 = 0x0015
    public static let xorRelayedAddress: UInt16 = 0x0016
    public static let requestedTransport: UInt16 = 0x0019
    public static let xorMappedAddress: UInt16 = 0x0020
    public static let software: UInt16 = 0x8022
    public static let fingerprint: UInt16 = 0x8028
}

/// A STUN message (RFC 8489), the wire format TURN (RFC 8656) rides on.
public struct STUNMessage: Equatable, Sendable {
    public enum Class: UInt16, Sendable { case request = 0x000, indication = 0x010, success = 0x100, error = 0x110 }
    public enum Method: UInt16, Sendable {
        case binding = 0x001, allocate = 0x003, refresh = 0x004, send = 0x006, data = 0x007,
             createPermission = 0x008, channelBind = 0x009
    }

    public struct Attribute: Equatable, Sendable {
        public let type: UInt16
        public let value: Data
        public init(type: UInt16, value: Data) {
            self.type = type
            self.value = value
        }
    }

    public static let magicCookie = Data([0x21, 0x12, 0xA4, 0x42])

    public var method: Method
    public var cls: Class
    public var transactionID: Data
    public var attributes: [Attribute]

    /// Attribute padding may be any byte (RFC 8489 §14), so MESSAGE-INTEGRITY has to run over what arrived.
    private var raw: Data?

    public init(method: Method, cls: Class, transactionID: Data = STUNMessage.newTransactionID(),
                attributes: [Attribute] = []) {
        self.method = method
        self.cls = cls
        self.transactionID = transactionID
        self.attributes = attributes
    }

    public static func == (lhs: STUNMessage, rhs: STUNMessage) -> Bool {
        lhs.method == rhs.method && lhs.cls == rhs.cls
            && lhs.transactionID == rhs.transactionID && lhs.attributes == rhs.attributes
    }

    public static func newTransactionID() -> Data {
        Data((0..<12).map { _ in UInt8.random(in: .min ... .max) })
    }

    public func attribute(_ type: UInt16) -> Data? {
        attributes.first { $0.type == type }?.value
    }

    // MARK: - Coding

    public func encode() -> Data { encode(attributes) }

    /// `extra` reserves room in the header length for an attribute not yet appended (RFC 8489 §14.5).
    private func encode(_ list: [Attribute], extra: Int = 0) -> Data {
        var body = Data()
        for attribute in list {
            body.append(Self.be16(attribute.type))
            body.append(Self.be16(UInt16(attribute.value.count)))
            body.append(attribute.value)
            body.append(Data(repeating: 0, count: (4 - attribute.value.count % 4) % 4))
        }
        var out = Self.be16(Self.messageType(method: method, cls: cls))
        out.append(Self.be16(UInt16(body.count + extra)))
        out.append(Self.magicCookie)
        out.append(transactionID)
        out.append(body)
        return out
    }

    public init?(decoding raw: Data) {
        let bytes = [UInt8](raw)
        guard bytes.count >= 20, bytes[0] & 0xC0 == 0, Array(bytes[4..<8]) == [0x21, 0x12, 0xA4, 0x42] else { return nil }
        let length = Int(Self.be16(bytes, 2))
        guard length % 4 == 0, 20 + length == bytes.count else { return nil }
        let type = Self.be16(bytes, 0)
        guard let cls = Class(rawValue: type & 0x0110),
              let method = Method(rawValue: Self.method(of: type)),
              let attributes = Self.parseAttributes(Array(bytes[20...]))
        else { return nil }
        self.init(method: method, cls: cls, transactionID: Data(bytes[8..<20]), attributes: attributes)
        self.raw = Data(bytes)
    }

    private static func parseAttributes(_ body: [UInt8]) -> [Attribute]? {
        var out: [Attribute] = []
        var offset = 0
        while offset + 4 <= body.count {
            let length = Int(be16(body, offset + 2))
            let start = offset + 4
            guard start + length <= body.count else { return nil }
            out.append(Attribute(type: be16(body, offset), value: Data(body[start..<(start + length)])))
            offset = start + (length + 3) / 4 * 4
        }
        return offset >= body.count ? out : nil
    }

    /// RFC 8489 §5: the 12 method bits are interleaved with the two class bits.
    public static func messageType(method: Method, cls: Class) -> UInt16 {
        let m = method.rawValue
        return (m & 0xF80) << 2 | (m & 0x70) << 1 | (m & 0x0F) | cls.rawValue
    }

    private static func method(of type: UInt16) -> UInt16 {
        (type & 0x3E00) >> 2 | (type & 0x00E0) >> 1 | (type & 0x000F)
    }

    // MARK: - Integrity

    /// Appends MESSAGE-INTEGRITY (long-term key, RFC 8489 §18.5.1) then FINGERPRINT.
    public func signed(username: String, realm: String, password: String) -> Data {
        sign(key: Self.longTermKey(username: username, realm: realm, password: password))
    }

    /// Short-term credentials use the password itself as the key (RFC 8489 §9.1.1).
    public func signedShortTerm(password: String) -> Data {
        sign(key: Data(password.utf8))
    }

    public func verify(username: String, realm: String, password: String) -> Bool {
        verify(key: Self.longTermKey(username: username, realm: realm, password: password))
    }

    public func verifyShortTerm(password: String) -> Bool {
        verify(key: Data(password.utf8))
    }

    private func sign(key: Data) -> Data {
        let mac = Self.hmac(encode(attributes, extra: 24), key: key)
        var list = attributes
        list.append(Attribute(type: STUNAttribute.messageIntegrity, value: mac))
        var out = encode(list, extra: 8)
        let crc = Self.crc32(out) ^ 0x5354_554E
        out.append(contentsOf: [0x80, 0x28, 0x00, 0x04])
        out.append(Self.be32(crc))
        return out
    }

    private func verify(key: Data) -> Bool {
        guard let index = attributes.firstIndex(where: { $0.type == STUNAttribute.messageIntegrity }) else { return false }
        let preimage = raw.flatMap { truncated($0, before: index) } ?? encode(Array(attributes[..<index]), extra: 24)
        return Self.hmac(preimage, key: key) == attributes[index].value
    }

    /// The received bytes up to MESSAGE-INTEGRITY, with the header length rewritten to cover it.
    private func truncated(_ raw: Data, before index: Int) -> Data? {
        let end = 20 + attributes[..<index].reduce(0) { $0 + 4 + ($1.value.count + 3) / 4 * 4 }
        guard raw.count >= end else { return nil }
        var out = Data(raw.prefix(end))
        out[out.startIndex + 2] = UInt8((end - 20 + 24) >> 8)
        out[out.startIndex + 3] = UInt8((end - 20 + 24) & 0xFF)
        return out
    }

    /// FINGERPRINT covers everything before it, with the header length already counting it (RFC 8489 §14.7).
    public static func verifyFingerprint(_ raw: Data) -> Bool {
        let bytes = [UInt8](raw)
        guard bytes.count >= 28, bytes[bytes.count - 8] == 0x80, bytes[bytes.count - 7] == 0x28 else { return false }
        let covered = Data(bytes[..<(bytes.count - 8)])
        let stated = UInt32(be16(bytes, bytes.count - 4)) << 16 | UInt32(be16(bytes, bytes.count - 2))
        return crc32(covered) ^ 0x5354_554E == stated
    }

    private static func longTermKey(username: String, realm: String, password: String) -> Data {
        Data(Insecure.MD5.hash(data: Data("\(username):\(realm):\(password)".utf8)))
    }

    private static func hmac(_ data: Data, key: Data) -> Data {
        Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }

    // MARK: - Addresses

    /// XOR-MAPPED/PEER/RELAYED-ADDRESS value: reserved byte, family, xor'd port, xor'd address (RFC 8489 §14.2).
    public static func xorAddress(_ value: Data, transactionID: Data) -> (host: String, port: UInt16)? {
        let bytes = [UInt8](value)
        guard bytes.count >= 8, bytes[1] == 0x01 || bytes[1] == 0x02 else { return nil }
        let size = bytes[1] == 0x02 ? 16 : 4
        guard bytes.count >= 4 + size else { return nil }
        let mask = [UInt8](magicCookie + transactionID)
        let raw = (0..<size).map { bytes[4 + $0] ^ mask[$0] }
        return (literal(raw, v6: size == 16), be16(bytes, 2) ^ 0x2112)
    }

    /// Nil when `host` is not a numeric IP literal.
    public static func xorAddressAttribute(host: String, port: UInt16, transactionID: Data) -> Data? {
        let v6 = host.contains(":")
        var raw = [UInt8](repeating: 0, count: v6 ? 16 : 4)
        guard inet_pton(v6 ? AF_INET6 : AF_INET, host, &raw) == 1 else { return nil }
        let mask = [UInt8](magicCookie + transactionID)
        var out = Data([0, v6 ? 0x02 : 0x01])
        out.append(be16(port ^ 0x2112))
        out.append(contentsOf: (0..<raw.count).map { raw[$0] ^ mask[$0] })
        return out
    }

    /// ERROR-CODE value: two zero bytes, a class digit, a number byte, then a UTF-8 reason (RFC 8489 §14.8).
    public static func errorCode(_ value: Data) -> (code: Int, reason: String)? {
        let bytes = [UInt8](value)
        guard bytes.count >= 4 else { return nil }
        return (Int(bytes[2] & 0x07) * 100 + Int(bytes[3]), String(decoding: bytes[4...], as: UTF8.self))
    }

    private static func literal(_ bytes: [UInt8], v6: Bool) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        _ = bytes.withUnsafeBufferPointer { inet_ntop(v6 ? AF_INET6 : AF_INET, $0.baseAddress, &buffer, socklen_t(buffer.count)) }
        return String(cString: buffer)
    }

    // MARK: - Integers

    private static func be16(_ value: UInt16) -> Data { Data([UInt8(value >> 8), UInt8(value & 0xFF)]) }

    private static func be32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    private static func be16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    public static func uint32(_ value: UInt32) -> Data { be32(value) }
}

/// TURN's ChannelData framing (RFC 8656 §12.4): channel number, length, payload padded to four bytes.
public enum ChannelData {
    public static func encode(channel: UInt16, payload: Data) -> Data {
        var out = Data([UInt8(channel >> 8), UInt8(channel & 0xFF),
                        UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        out.append(payload)
        out.append(Data(repeating: 0, count: (4 - payload.count % 4) % 4))
        return out
    }

    public static func decode(_ data: Data) -> (channel: UInt16, payload: Data)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        let channel = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        guard (0x4000...0x7FFF).contains(channel) else { return nil }
        let length = Int(bytes[2]) << 8 | Int(bytes[3])
        guard 4 + length <= bytes.count else { return nil }
        return (channel, Data(bytes[4..<(4 + length)]))
    }
}

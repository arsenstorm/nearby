import Foundation
import Testing
@testable import NearbyCore

/// Vectors are the sample messages of RFC 5769.
private func hex(_ text: String) -> Data {
    let digits = Array(text.filter { !$0.isWhitespace })
    return Data(stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! })
}

private let sampleRequest = hex("""
    00 01 00 58  21 12 a4 42  b7 e7 a7 01  bc 34 d6 86  fa 87 df ae
    80 22 00 10  53 54 55 4e  20 74 65 73  74 20 63 6c  69 65 6e 74
    00 24 00 04  6e 00 01 ff
    80 29 00 08  93 2f f9 b1  51 26 3b 36
    00 06 00 09  65 76 74 6a  3a 68 36 76  59 20 20 20
    00 08 00 14  9a ea a7 0c  bf d8 cb 56  78 1e f2 b5  b2 d3 f2 49  c1 b5 71 a2
    80 28 00 04  e5 7a 3b cf
    """)

private let sampleIPv4Response = hex("""
    01 01 00 3c  21 12 a4 42  b7 e7 a7 01  bc 34 d6 86  fa 87 df ae
    80 22 00 0b  74 65 73 74  20 76 65 63  74 6f 72 20
    00 20 00 08  00 01 a1 47  e1 12 a6 43
    00 08 00 14  2b 91 f5 99  fd 9e 90 c3  8c 74 89 f9  2a f9 ba 53  f0 6b e7 d7
    80 28 00 04  c0 7d 4c 96
    """)

private let sampleIPv6Response = hex("""
    01 01 00 48  21 12 a4 42  b7 e7 a7 01  bc 34 d6 86  fa 87 df ae
    80 22 00 0b  74 65 73 74  20 76 65 63  74 6f 72 20
    00 20 00 14  00 02 a1 47  01 13 a9 fa  a5 d3 f1 79  bc 25 f4 b5  be d2 b9 d9
    00 08 00 14  a3 82 95 4e  4b e6 7b f1  17 84 c9 7c  82 92 c2 75  bd e3 cc cc
    80 28 00 04  c8 fb 0b 4c
    """)

private let sampleLongTermRequest = hex("""
    00 01 00 60  21 12 a4 42  78 ad 34 33  c6 ad 72 c0  29 da 41 2e
    00 06 00 12  e3 83 9e e3  83 88 e3 83  aa e3 83 83  e3 82 af e3  82 b9 00 00
    00 15 00 1c  66 2f 2f 34  39 39 6b 39  35 34 64 36  4f 4c 33 34
                 6f 4c 39 46  53 54 76 79  36 34 73 41
    00 14 00 0b  65 78 61 6d  70 6c 65 2e  6f 72 67 20
    00 08 00 14  f6 70 24 65  6d d6 4a 3e  02 b8 e0 71  2e 85 c9 a2  8a d5 26 6f
    """)

@Suite struct STUNMessageTests {
    @Test func decodesSampleRequest() throws {
        let message = try #require(STUNMessage(decoding: sampleRequest))
        #expect(message.method == .binding)
        #expect(message.cls == .request)
        #expect(message.attribute(STUNAttribute.software).map { String(decoding: $0, as: UTF8.self) } == "STUN test client")
        #expect(message.attribute(0x0024) == Data([0x6e, 0x00, 0x01, 0xff]))
        #expect(message.attribute(0x8029) == hex("93 2f f9 b1 51 26 3b 36"))
        #expect(message.attribute(STUNAttribute.username).map { String(decoding: $0, as: UTF8.self) } == "evtj:h6vY")
    }

    @Test func sampleRequestIntegrityAndFingerprint() throws {
        let message = try #require(STUNMessage(decoding: sampleRequest))
        #expect(message.verifyShortTerm(password: "VOkJxbRl1RmTxUk/WvJxBt"))
        #expect(!message.verifyShortTerm(password: "wrong"))
        #expect(STUNMessage.verifyFingerprint(sampleRequest))
    }

    /// The RFC pads attributes with spaces; the encoder pads with zeros, so only the framing can match byte for byte.
    @Test func reencodingReproducesSampleRequest() throws {
        let message = try #require(STUNMessage(decoding: sampleRequest))
        let reencoded = message.encode()
        #expect(reencoded.count == sampleRequest.count)
        #expect(reencoded.prefix(24) == sampleRequest.prefix(24))
        #expect(STUNMessage(decoding: reencoded) == message)
    }

    /// Reference MESSAGE-INTEGRITY and FINGERPRINT for this message computed with openssl and zlib.
    @Test func signAndVerifyRoundTrip() throws {
        let message = STUNMessage(
            method: .allocate, cls: .request, transactionID: Data(0..<12),
            attributes: [.init(type: STUNAttribute.requestedTransport, value: Data([17, 0, 0, 0])),
                         .init(type: STUNAttribute.username, value: Data("user".utf8)),
                         .init(type: STUNAttribute.realm, value: Data("realm".utf8)),
                         .init(type: STUNAttribute.nonce, value: Data("nonce".utf8))])
        let signed = message.signed(username: "user", realm: "realm", password: "pass")
        let decoded = try #require(STUNMessage(decoding: signed))
        #expect(signed.count == 92)
        #expect(decoded.attribute(STUNAttribute.messageIntegrity) == hex("823db1e8 f47c5aae 7520765a 703e6f2c 6f361a16"))
        #expect(decoded.attribute(STUNAttribute.fingerprint) == hex("8a 19 91 c0"))
        #expect(decoded.verify(username: "user", realm: "realm", password: "pass"))
        #expect(!decoded.verify(username: "user", realm: "realm", password: "nope"))
        #expect(STUNMessage.verifyFingerprint(signed))
        #expect(decoded.encode() == signed)
    }

    @Test func decodesIPv4Response() throws {
        let message = try #require(STUNMessage(decoding: sampleIPv4Response))
        #expect(message.cls == .success)
        let value = try #require(message.attribute(STUNAttribute.xorMappedAddress))
        let mapped = try #require(STUNMessage.xorAddress(value, transactionID: message.transactionID))
        #expect(mapped.host == "192.0.2.1")
        #expect(mapped.port == 32853)
        #expect(message.verifyShortTerm(password: "VOkJxbRl1RmTxUk/WvJxBt"))
    }

    @Test func decodesIPv6Response() throws {
        let message = try #require(STUNMessage(decoding: sampleIPv6Response))
        let value = try #require(message.attribute(STUNAttribute.xorMappedAddress))
        let mapped = try #require(STUNMessage.xorAddress(value, transactionID: message.transactionID))
        #expect(mapped.host == "2001:db8:1234:5678:11:2233:4455:6677")
        #expect(mapped.port == 32853)
    }

    @Test func xorAddressRoundTrips() throws {
        let id = STUNMessage.newTransactionID()
        for host in ["192.0.2.1", "2001:db8:1234:5678:11:2233:4455:6677"] {
            let attribute = try #require(STUNMessage.xorAddressAttribute(host: host, port: 32853, transactionID: id))
            let back = try #require(STUNMessage.xorAddress(attribute, transactionID: id))
            #expect(back.host == host)
            #expect(back.port == 32853)
        }
        #expect(STUNMessage.xorAddressAttribute(host: "not-an-ip", port: 1, transactionID: id) == nil)
    }

    @Test func decodesLongTermRequest() throws {
        let message = try #require(STUNMessage(decoding: sampleLongTermRequest))
        #expect(message.attribute(STUNAttribute.username).map { String(decoding: $0, as: UTF8.self) } == "マトリックス")
        #expect(message.attribute(STUNAttribute.realm).map { String(decoding: $0, as: UTF8.self) } == "example.org")
        #expect(message.attribute(STUNAttribute.nonce).map { String(decoding: $0, as: UTF8.self) }
            == "f//499k954d6OL34oL9FSTvy64sA")
        #expect(message.attributes.map(\.type) == [0x0006, 0x0015, 0x0014, 0x0008])
    }

    @Test func decodeRejectsBadCookieAndLength() {
        var bad = sampleRequest
        bad[4] = 0x22
        #expect(STUNMessage(decoding: bad) == nil)
        #expect(STUNMessage(decoding: sampleRequest.prefix(40)) == nil)
        #expect(STUNMessage(decoding: Data([0x00, 0x01])) == nil)
    }

    @Test func messageTypePacksMethodAndClass() {
        #expect(STUNMessage.messageType(method: .allocate, cls: .request) == 0x0003)
        #expect(STUNMessage.messageType(method: .allocate, cls: .success) == 0x0103)
        #expect(STUNMessage.messageType(method: .data, cls: .indication) == 0x0017)
        #expect(STUNMessage.messageType(method: .createPermission, cls: .request) == 0x0008)
        #expect(STUNMessage.messageType(method: .channelBind, cls: .request) == 0x0009)
        #expect(STUNMessage.messageType(method: .refresh, cls: .request) == 0x0004)
        #expect(STUNMessage.messageType(method: .binding, cls: .error) == 0x0111)
    }

    @Test func errorCodeParses() throws {
        let value = Data([0, 0, 4, 1]) + Data("Unauthorized".utf8)
        let parsed = try #require(STUNMessage.errorCode(value))
        #expect(parsed.code == 401)
        #expect(parsed.reason == "Unauthorized")
    }

    @Test func channelDataRoundTrips() throws {
        let payload = Data([1, 2, 3, 4, 5])
        let framed = ChannelData.encode(channel: 0x4001, payload: payload)
        #expect(framed.count == 12)
        #expect(Array(framed.prefix(4)) == [0x40, 0x01, 0x00, 0x05])
        let decoded = try #require(ChannelData.decode(framed))
        #expect(decoded.channel == 0x4001)
        #expect(decoded.payload == payload)
        #expect(ChannelData.decode(Data([0x00, 0x01, 0x00, 0x00])) == nil)
        #expect(ChannelData.decode(Data([0x40, 0x01, 0x00, 0x08, 1, 2])) == nil)
    }
}

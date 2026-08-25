import CryptoKit
import Foundation
import Testing
@testable import NearbyCore

@Suite struct IdentityTests {
    @Test func sameSeedSameNodeID() throws {
        let seed = Data(repeating: 7, count: 32)
        let a = try Identity(seed: seed)
        let b = try Identity(seed: seed)
        #expect(a.nodeID == b.nodeID)
        #expect(a.signingPublicKey == b.signingPublicKey)
        #expect(a.agreementPublicKey == b.agreementPublicKey)
    }

    @Test func randomIdentitiesDiffer() {
        let a = Identity()
        let b = Identity()
        #expect(a.nodeID != b.nodeID)
    }

    @Test func badSeedLengthThrows() {
        #expect(throws: IdentityError.badSeed) {
            _ = try Identity(seed: Data(repeating: 1, count: 31))
        }
    }
}

@Suite struct HelloTests {
    @Test func signedHelloVerifies() throws {
        let identity = Identity()
        let hello = try Hello(identity: identity, name: "alice", timestampMs: 1000)
        #expect(hello.verify())
    }

    @Test func tamperedNameFailsVerify() throws {
        let identity = Identity()
        var hello = try Hello(identity: identity, name: "alice", timestampMs: 1000)
        hello.name = "mallory"
        #expect(!hello.verify())
    }

    @Test func replacedNodeIDFailsVerify() throws {
        let identity = Identity()
        var hello = try Hello(identity: identity, name: "alice", timestampMs: 1000)
        hello.nodeID = Identity().nodeID
        #expect(!hello.verify())
    }

    @Test func encodeDecodeRoundTrip() throws {
        let identity = Identity()
        let hello = try Hello(identity: identity, name: "alice", timestampMs: 1000)
        let data = try hello.encode()
        let decoded = try Hello.decode(data)
        #expect(decoded == hello)
        #expect(decoded.verify())
    }
}

@Suite struct PeerStoreTests {
    @Test func firstObserveSaves() throws {
        var store = PeerStore()
        let identity = Identity()
        let hello = try Hello(identity: identity, name: "alice", timestampMs: 1)
        let record = try store.observe(hello, now: .now)
        #expect(record.id == identity.nodeID)
        #expect(store.record(for: identity.nodeID) == record)
    }

    @Test func secondObserveSameKeysUpdatesName() throws {
        var store = PeerStore()
        let identity = Identity()
        let hello1 = try Hello(identity: identity, name: "alice", timestampMs: 1)
        _ = try store.observe(hello1, now: .now)
        let hello2 = try Hello(identity: identity, name: "alice2", timestampMs: 2)
        let record = try store.observe(hello2, now: .now)
        #expect(record.name == "alice2")
        #expect(store.records.count == 1)
    }

    @Test func helloWithForeignNodeIDFailsVerifyAndObserve() throws {
        var store = PeerStore()
        let a = Identity()
        let b = Identity()
        var hello = try Hello(identity: b, name: "bob", timestampMs: 1)
        hello.nodeID = a.nodeID
        #expect(throws: PeerStoreError.badSignature) {
            _ = try store.observe(hello, now: .now)
        }
    }

    @Test func observeWithDifferentKeysThrowsKeyChanged() throws {
        let a = Identity()
        let c = Identity()
        let existing = PeerRecord(
            id: a.nodeID,
            signingPublicKey: c.signingPublicKey,
            agreementPublicKey: c.agreementPublicKey,
            name: "impostor",
            firstSeen: .now
        )
        let snapshotData = try JSONEncoder().encode([existing])
        var store = try PeerStore(snapshot: snapshotData)

        let realHello = try Hello(identity: a, name: "alice", timestampMs: 1)
        #expect(throws: PeerStoreError.self) {
            _ = try store.observe(realHello, now: .now)
        }
        do {
            _ = try store.observe(realHello, now: .now)
        } catch PeerStoreError.keyChanged(let existingRecord) {
            #expect(existingRecord.id == a.nodeID)
            #expect(existingRecord.signingPublicKey == c.signingPublicKey)
        } catch {
            Issue.record("expected keyChanged, got \(error)")
        }
    }

    @Test func snapshotRoundTrip() throws {
        var store = PeerStore()
        let a = Identity()
        let hello = try Hello(identity: a, name: "alice", timestampMs: 1)
        _ = try store.observe(hello, now: .now)
        let snapshot = try store.snapshot()
        let restored = try PeerStore(snapshot: snapshot)
        #expect(restored.record(for: a.nodeID) == store.record(for: a.nodeID))
    }

    @Test func trustOverwritesKeys() throws {
        let a = Identity()
        let c = Identity()
        let existing = PeerRecord(
            id: a.nodeID,
            signingPublicKey: c.signingPublicKey,
            agreementPublicKey: c.agreementPublicKey,
            name: "impostor",
            firstSeen: .now
        )
        var store = try PeerStore(snapshot: try JSONEncoder().encode([existing]))
        let realHello = try Hello(identity: a, name: "alice", timestampMs: 1)
        let record = try store.trust(realHello, now: .now)
        #expect(record.signingPublicKey == a.signingPublicKey)
        #expect(record.agreementPublicKey == a.agreementPublicKey)
        #expect(store.record(for: a.nodeID)?.signingPublicKey == a.signingPublicKey)
    }
}

@Suite struct AEADTests {
    private func header(source: NodeID = NodeID(raw: 1), stream: UInt8 = 0, sequence: UInt32 = 0) -> PacketHeader {
        PacketHeader(type: .voice, source: source, stream: stream, sequence: sequence)
    }

    @Test func nonceIs12Bytes() {
        #expect(AEAD.nonce(for: header()).count == 12)
    }

    @Test func nonceDiffersOnSequenceStreamSource() {
        let base = header()
        let bySequence = header(sequence: 1)
        let byStream = header(stream: 1)
        // nonce uses only the top 7 of the 8 source-id bytes, so the differing
        // source must vary outside the lowest byte to change the nonce.
        let bySource = header(source: NodeID(raw: 0x0200_0000_0000_0000))
        #expect(AEAD.nonce(for: base) != AEAD.nonce(for: bySequence))
        #expect(AEAD.nonce(for: base) != AEAD.nonce(for: byStream))
        #expect(AEAD.nonce(for: base) != AEAD.nonce(for: bySource))
    }

    @Test func sealOpenRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let h = header()
        let sealed = try AEAD.seal(Data("hello".utf8), key: key, header: h)
        let opened = try AEAD.open(sealed, key: key, header: h)
        #expect(opened == Data("hello".utf8))
    }

    @Test func flippedCiphertextByteFailsOpen() throws {
        let key = SymmetricKey(size: .bits256)
        let h = header()
        var sealed = try AEAD.seal(Data("hello".utf8), key: key, header: h)
        sealed[sealed.startIndex] ^= 0xFF
        #expect(throws: AEADError.self) {
            _ = try AEAD.open(sealed, key: key, header: h)
        }
    }

    @Test func ttlChangeDoesNotBreakOpen() throws {
        let key = SymmetricKey(size: .bits256)
        var h = header()
        h.ttl = PacketHeader.initialTTL
        let sealed = try AEAD.seal(Data("hello".utf8), key: key, header: h)
        var opened = h
        opened.ttl = h.ttl - 1
        let plaintext = try AEAD.open(sealed, key: key, header: opened)
        #expect(plaintext == Data("hello".utf8))
    }

    @Test func headerFieldChangesBreakOpen() throws {
        let key = SymmetricKey(size: .bits256)
        let h = header()
        let sealed = try AEAD.seal(Data("hello".utf8), key: key, header: h)

        var byType = h
        byType.type = .control
        #expect(throws: AEADError.self) { _ = try AEAD.open(sealed, key: key, header: byType) }

        var byDestination = h
        byDestination.destination = NodeID(raw: 99)
        #expect(throws: AEADError.self) { _ = try AEAD.open(sealed, key: key, header: byDestination) }

        var byStream = h
        byStream.stream = 5
        #expect(throws: AEADError.self) { _ = try AEAD.open(sealed, key: key, header: byStream) }

        var bySequence = h
        bySequence.sequence = 42
        #expect(throws: AEADError.self) { _ = try AEAD.open(sealed, key: key, header: bySequence) }

        var bySource = h
        bySource.source = NodeID(raw: 42)
        #expect(throws: AEADError.self) { _ = try AEAD.open(sealed, key: key, header: bySource) }
    }
}

@Suite struct PairwiseSessionTests {
    @Test func mutualDerivationInteroperates() throws {
        let a = Identity()
        let b = Identity()
        let sessionA = try PairwiseSession(identity: a, remoteID: b.nodeID, remoteAgreementPublicKey: b.agreementPublicKey)
        let sessionB = try PairwiseSession(identity: b, remoteID: a.nodeID, remoteAgreementPublicKey: a.agreementPublicKey)

        let header = PacketHeader(type: .control, source: a.nodeID, destination: b.nodeID, sequence: 1)
        let sealed = try sessionA.seal(Data("secret".utf8), header: header)
        let opened = try sessionB.open(sealed, header: header)
        #expect(opened == Data("secret".utf8))
    }

    @Test func thirdPartyCannotOpen() throws {
        let a = Identity()
        let b = Identity()
        let c = Identity()
        let sessionA = try PairwiseSession(identity: a, remoteID: b.nodeID, remoteAgreementPublicKey: b.agreementPublicKey)
        let sessionC = try PairwiseSession(identity: c, remoteID: a.nodeID, remoteAgreementPublicKey: a.agreementPublicKey)

        let header = PacketHeader(type: .control, source: a.nodeID, destination: b.nodeID, sequence: 1)
        let sealed = try sessionA.seal(Data("secret".utf8), header: header)
        #expect(throws: AEADError.self) {
            _ = try sessionC.open(sealed, header: header)
        }
    }
}

@Suite struct RoomKeyTests {
    @Test func sealOpenRoundTrip() throws {
        let key = RoomKey()
        let header = PacketHeader(type: .voice, source: NodeID(raw: 1), sequence: 0)
        let sealed = try key.seal(Data("voice".utf8), header: header)
        let opened = try key.open(sealed, header: header)
        #expect(opened == Data("voice".utf8))
    }

    @Test func wrongKeyFailsOpen() throws {
        let key = RoomKey()
        let other = RoomKey()
        let header = PacketHeader(type: .voice, source: NodeID(raw: 1), sequence: 0)
        let sealed = try key.seal(Data("voice".utf8), header: header)
        #expect(throws: AEADError.self) {
            _ = try other.open(sealed, header: header)
        }
    }

    @Test func relayCannotDecryptVoice() throws {
        let host = Identity()
        let relay = Identity()
        let roomKey = RoomKey()
        let header = PacketHeader(type: .voice, source: host.nodeID, sequence: 0)
        let sealed = try roomKey.seal(Data("voice-payload".utf8), header: header)

        let pairwise = try PairwiseSession(
            identity: relay, remoteID: host.nodeID, remoteAgreementPublicKey: host.agreementPublicKey
        )
        #expect(throws: AEADError.self) {
            _ = try pairwise.open(sealed, header: header)
        }
    }

    @Test func codeKeyDeterministicPerRoom() {
        let k1 = RoomKey.codeKey(code: "abc123", roomID: 1)
        let k2 = RoomKey.codeKey(code: "abc123", roomID: 1)
        let k3 = RoomKey.codeKey(code: "abc123", roomID: 2)
        #expect(dataOf(k1) == dataOf(k2))
        #expect(dataOf(k1) != dataOf(k3))
    }

    private func dataOf(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }
}

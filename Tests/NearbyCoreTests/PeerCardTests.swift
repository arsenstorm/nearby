import Foundation
import Testing
@testable import NearbyCore

@Suite struct PeerCardTests {
    @Test func urlRoundTrips() throws {
        let card = PeerCard(identity: Identity(), name: "Alice & Bob")
        let decoded = try #require(PeerCard(url: card.url))
        #expect(decoded == card)
        #expect(card.url.scheme == "nearby")
    }

    @Test func rejectsWrongSchemeAndShortKey() {
        #expect(PeerCard(url: URL(string: "https://example.com/abc")!) == nil)
        #expect(PeerCard(url: URL(string: "nearby://AAAA")!) == nil)
    }

    @Test func scannedRecordAcceptsMatchingHelloAndRejectsImpostor() throws {
        let alice = Identity(), mallory = Identity()
        var store = PeerStore()
        let record = store.add(PeerCard(identity: alice, name: "alice"), now: .now)
        #expect(record.id == alice.nodeID)
        _ = try store.observe(try Hello(identity: alice, name: "Alice", timestampMs: 1), now: .now)
        #expect(store.record(for: alice.nodeID)?.name == "Alice")
        var forged = try Hello(identity: mallory, name: "alice", timestampMs: 2)
        forged.nodeID = alice.nodeID
        #expect(throws: PeerStoreError.self) { _ = try store.observe(forged, now: .now) }
    }

    @Test func addNeverOverwritesKnownPeer() {
        let alice = Identity()
        var store = PeerStore()
        _ = store.add(PeerCard(identity: alice, name: "first"), now: .now)
        let again = store.add(PeerCard(signingPublicKey: Identity().signingPublicKey, name: "x"), now: .now)
        #expect(again.name == "x")
        #expect(store.add(PeerCard(identity: alice, name: "second"), now: .now).name == "first")
    }
}

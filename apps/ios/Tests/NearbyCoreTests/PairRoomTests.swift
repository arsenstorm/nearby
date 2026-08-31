import Foundation
import Testing
@testable import NearbyCore

@Suite struct PairRoomTests {
    @Test func nameIsOrderIndependentAndMatchesVector() {
        let a = NodeID(raw: 1)
        let b = NodeID(raw: 2)
        #expect(PairRoom.name(a, b) == "8c7654ecfd7b0b623b803e2f4e02ad1cc84278efdfcd7c4c9208edd81f17e115")
        #expect(PairRoom.name(b, a) == PairRoom.name(a, b))
    }

    @Test func authSignatureVerifies() throws {
        let identity = Identity()
        let room = PairRoom.name(identity.nodeID, NodeID(raw: 9))
        var nonce = Data((0..<32).map { UInt8($0) })
        let signature = try PairRoom.authSignature(identity: identity, nonce: nonce, room: room)
        let signed = PairRoom.domain + nonce + Data(room.utf8)
        #expect(Identity.verify(signature: signature, for: signed, signingPublicKey: identity.signingPublicKey))

        nonce[0] ^= 1
        let tampered = PairRoom.domain + nonce + Data(room.utf8)
        #expect(!Identity.verify(signature: signature, for: tampered, signingPublicKey: identity.signingPublicKey))
    }
}

import Foundation
import Testing
@testable import NearbyCore

@Suite struct ControlMessageTests {
    private func roundTrip(_ message: ControlMessage) throws {
        let decoded = try ControlMessage.decode(message.encode())
        #expect(decoded == message)
    }

    @Test func roomAnnounceRoundTrips() throws {
        try roundTrip(.roomAnnounce(RoomAnnounce(roomID: 1, name: "Room", host: NodeID(raw: 1), hasCode: false)))
    }

    @Test func joinRequestRoundTrips() throws {
        try roundTrip(.joinRequest(JoinRequest(roomID: 1, name: "Alice", codeProof: Data([1, 2, 3]))))
    }

    @Test func joinAcceptRoundTrips() throws {
        let members = [Member(id: NodeID(raw: 1), name: "Alice")]
        try roundTrip(.joinAccept(JoinAccept(roomID: 1, roomKey: Data(repeating: 9, count: 32), members: members)))
    }

    @Test func joinRejectRoundTrips() throws {
        try roundTrip(.joinReject(roomID: 1, reason: "full"))
    }

    @Test func memberListRoundTrips() throws {
        let members = [Member(id: NodeID(raw: 1), name: "Alice")]
        try roundTrip(.memberList(roomID: 1, members: members, roomKey: Data(repeating: 7, count: 32)))
    }

    @Test func leaveRoundTrips() throws {
        try roundTrip(.leave(roomID: 1))
    }

    @Test func profileRoundTrips() throws {
        try roundTrip(.profile(name: "Ada"))
    }

    @Test func onlyRoomAnnounceIsBroadcastable() {
        #expect(ControlMessage.roomAnnounce(RoomAnnounce(roomID: 1, name: "r", host: NodeID(raw: 1), hasCode: false)).isBroadcastable)
        #expect(!ControlMessage.profile(name: "Ada").isBroadcastable)
        #expect(!ControlMessage.memberList(roomID: 1, members: [], roomKey: Data(count: 32)).isBroadcastable)
        #expect(!ControlMessage.leave(roomID: 1).isBroadcastable)
    }
}

@Suite struct HostRoomTests {
    private func makeRoom() -> HostRoom {
        HostRoom(id: 1, name: "Room", host: Member(id: NodeID(raw: 1), name: "Host"))
    }

    @Test func requestAddsToPending() {
        var room = makeRoom()
        let alice = Member(id: NodeID(raw: 2), name: "Alice")
        room.request(from: alice)
        #expect(room.pending == [alice])
    }

    @Test func duplicateRequestIgnored() {
        var room = makeRoom()
        let alice = Member(id: NodeID(raw: 2), name: "Alice")
        room.request(from: alice)
        room.request(from: alice)
        #expect(room.pending == [alice])
    }

    @Test func acceptMovesToMembersAndRotatesKey() {
        var room = makeRoom()
        let alice = Member(id: NodeID(raw: 2), name: "Alice")
        room.request(from: alice)
        let oldKey = room.roomKey

        let accept = room.accept(alice.id)

        #expect(accept != nil)
        #expect(accept?.roomKey.count == 32)
        #expect(accept?.roomKey != oldKey)
        #expect(accept?.roomKey == room.roomKey)
        #expect(accept?.members == room.members)
        #expect(room.members.contains(alice))
        #expect(!room.pending.contains(alice))
    }

    @Test func acceptOfUnknownIDReturnsNil() {
        var room = makeRoom()
        #expect(room.accept(NodeID(raw: 99)) == nil)
    }

    @Test func rejectRemovesFromPending() {
        var room = makeRoom()
        let alice = Member(id: NodeID(raw: 2), name: "Alice")
        room.request(from: alice)
        room.reject(alice.id)
        #expect(room.pending.isEmpty)
    }

    @Test func removeMemberRotatesKeyAndReturnsMemberList() {
        var room = makeRoom()
        let alice = Member(id: NodeID(raw: 2), name: "Alice")
        room.request(from: alice)
        _ = room.accept(alice.id)
        let oldKey = room.roomKey

        let message = room.remove(alice.id)

        guard case .memberList(let roomID, let members, let roomKey) = message else {
            Issue.record("expected memberList")
            return
        }
        #expect(roomID == room.id)
        #expect(members == room.members)
        #expect(roomKey == room.roomKey)
        #expect(roomKey != oldKey)
        #expect(!room.members.contains(alice))
    }

    @Test func removeOfHostReturnsNil() {
        var room = makeRoom()
        #expect(room.remove(room.host.id) == nil)
    }

    @Test func takeoverKeepsMembersAndKey() {
        let host = Member(id: NodeID(raw: 1), name: "a")
        let other = Member(id: NodeID(raw: 2), name: "b")
        let key = Data(repeating: 7, count: 32)
        let room = HostRoom(takingOver: 9, name: "r", host: host, members: [other], roomKey: key)
        #expect(room.members == [host, other])
        #expect(room.roomKey == key)
        #expect(room.announce.host == host.id)
    }

    @Test func announceSignatureBindsToHostIdentity() {
        let identity = Identity()
        let room = HostRoom(id: 5, name: "r", host: Member(id: identity.nodeID, name: "a"))
        let signed = room.announce.signed(by: identity)
        #expect(signed.verify(signingPublicKey: identity.signingPublicKey))
        // Unsigned, or checked against another node's key, it is rejected.
        #expect(!room.announce.verify(signingPublicKey: identity.signingPublicKey))
        #expect(!signed.verify(signingPublicKey: Identity().signingPublicKey))
        // Tampering with a signed field breaks the signature.
        var forged = signed
        forged.host = NodeID(raw: 2)
        #expect(!forged.verify(signingPublicKey: identity.signingPublicKey))
    }
}

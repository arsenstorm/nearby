import Foundation
import Testing
@testable import NearbyCore

@Suite struct MeshTests {
    let a = NodeID(raw: 1)
    let b = NodeID(raw: 2)
    let c = NodeID(raw: 3)

    @Test func lineTopologyViaLSAs() {
        var mesh = Mesh(localID: a)
        let now = Date(timeIntervalSince1970: 0)
        let linkAB = LinkID(transport: .lan, endpoint: "b")

        mesh.linkUp(linkAB, bandwidthKbps: 1000, now: now)
        mesh.bind(linkAB, to: b)
        _ = mesh.localAdvertisement(now: now)

        let bLSA = LinkStateAdvertisement(origin: b, sequence: 1, neighbors: [Neighbor(id: a, cost: 10), Neighbor(id: c, cost: 10)])
        let cLSA = LinkStateAdvertisement(origin: c, sequence: 1, neighbors: [Neighbor(id: b, cost: 10)])
        #expect(mesh.apply(bLSA, now: now) == true)
        #expect(mesh.apply(cLSA, now: now) == true)

        let route = mesh.route(to: c)
        #expect(route?.nextHop == b)
        #expect(route?.hops == 2)

        #expect(mesh.nextLink(to: c) == linkAB)
        #expect(mesh.nextLink(to: b) == linkAB)
        #expect(mesh.reachable() == [b, c])
    }

    @Test func twoLinksToSameNeighborSortedByCost() {
        var mesh = Mesh(localID: a)
        let now = Date(timeIntervalSince1970: 0)
        let lan = LinkID(transport: .lan, endpoint: "b")
        let ble = LinkID(transport: .ble, endpoint: "b")

        mesh.linkUp(lan, bandwidthKbps: 1000, now: now)
        mesh.bind(lan, to: b)
        mesh.linkUp(ble, bandwidthKbps: 1000, now: now)
        mesh.bind(ble, to: b)

        mesh.probeSent(on: lan, sequence: 1, at: now)
        let lanRtt = mesh.probeReply(on: lan, sequence: 1, at: now.addingTimeInterval(0.010))
        mesh.probeSent(on: ble, sequence: 1, at: now)
        let bleRtt = mesh.probeReply(on: ble, sequence: 1, at: now.addingTimeInterval(0.060))
        #expect(abs((lanRtt ?? 0) - 10) < 0.01)
        #expect(abs((bleRtt ?? 0) - 60) < 0.01)

        #expect(mesh.links(to: b).first == lan)
        #expect(mesh.alternateLink(to: b) == ble)
        #expect(mesh.alternateLink(to: b) != mesh.nextLink(to: b))
    }

    @Test func expiredProbeCountsAsLoss() {
        var mesh = Mesh(localID: a)
        let now = Date(timeIntervalSince1970: 0)
        let link = LinkID(transport: .lan, endpoint: "b")

        mesh.linkUp(link, bandwidthKbps: 1000, now: now)
        mesh.probeSent(on: link, sequence: 1, at: now)
        mesh.expireProbes(now: now.addingTimeInterval(1.5))

        #expect(mesh.metrics(for: link, now: now.addingTimeInterval(1.5))?.lossFraction == 1.0)
        #expect(mesh.probeReply(on: link, sequence: 99, at: now.addingTimeInterval(2)) == nil)
    }

    @Test func replyMarksOlderOutstandingProbesAsLost() {
        var mesh = Mesh(localID: a)
        let now = Date(timeIntervalSince1970: 0)
        let link = LinkID(transport: .lan, endpoint: "b")

        mesh.linkUp(link, bandwidthKbps: 1000, now: now)
        mesh.probeSent(on: link, sequence: 1, at: now)
        mesh.probeSent(on: link, sequence: 2, at: now.addingTimeInterval(0.5))
        let rtt = mesh.probeReply(on: link, sequence: 2, at: now.addingTimeInterval(0.6))

        #expect(abs((rtt ?? 0) - 100) < 0.01)
        #expect(mesh.metrics(for: link, now: now.addingTimeInterval(0.6))?.lossFraction == 0.5)
    }

    @Test func applyingOwnOriginIsRejected() {
        var mesh = Mesh(localID: a)
        let now = Date(timeIntervalSince1970: 0)
        let ownLSA = LinkStateAdvertisement(origin: a, sequence: 1, neighbors: [])
        #expect(mesh.apply(ownLSA, now: now) == false)
    }

    @Test func localAdvertisementSequenceAndMinCost() {
        var mesh = Mesh(localID: a)
        let now = Date(timeIntervalSince1970: 0)
        let linkB1 = LinkID(transport: .lan, endpoint: "b1")
        let linkB2 = LinkID(transport: .ble, endpoint: "b2")
        let linkC = LinkID(transport: .lan, endpoint: "c")

        mesh.linkUp(linkB1, bandwidthKbps: 1000, now: now)
        mesh.bind(linkB1, to: b)
        mesh.linkUp(linkB2, bandwidthKbps: 1000, now: now)
        mesh.bind(linkB2, to: b)
        mesh.probeSent(on: linkB2, sequence: 1, at: now)
        _ = mesh.probeReply(on: linkB2, sequence: 1, at: now.addingTimeInterval(0.020))
        mesh.linkUp(linkC, bandwidthKbps: 1000, now: now)
        mesh.bind(linkC, to: c)

        let lsa1 = mesh.localAdvertisement(now: now)
        #expect(lsa1.neighbors.count == 2)
        #expect(abs((lsa1.neighbors.first { $0.id == b }?.cost ?? 0) - 40) < 0.01)

        let lsa2 = mesh.localAdvertisement(now: now)
        #expect(lsa2.sequence == lsa1.sequence &+ 1)
    }

    @Test func expireRemovesRemoteOriginAndItsRoute() {
        var mesh = Mesh(localID: a)
        let now = Date(timeIntervalSince1970: 0)
        let link = LinkID(transport: .lan, endpoint: "b")

        mesh.linkUp(link, bandwidthKbps: 1000, now: now)
        mesh.bind(link, to: b)
        _ = mesh.localAdvertisement(now: now)
        _ = mesh.apply(LinkStateAdvertisement(origin: b, sequence: 1, neighbors: [Neighbor(id: a, cost: 10), Neighbor(id: c, cost: 10)]), now: now)
        #expect(mesh.route(to: c) != nil)

        _ = mesh.localAdvertisement(now: now.addingTimeInterval(5))
        let removed = mesh.expire(now: now.addingTimeInterval(11))

        #expect(removed == [b])
        #expect(mesh.route(to: c) == nil)
        #expect(mesh.route(to: b) != nil)
    }

    @Test func linkDownRemovesLinkAndNeighbor() {
        var mesh = Mesh(localID: a)
        let now = Date(timeIntervalSince1970: 0)
        let link = LinkID(transport: .lan, endpoint: "b")

        mesh.linkUp(link, bandwidthKbps: 1000, now: now)
        mesh.bind(link, to: b)
        #expect(mesh.neighbors == [b])

        mesh.linkDown(link, now: now)
        #expect(mesh.neighbors.isEmpty)
        #expect(mesh.node(for: link) == nil)
        #expect(mesh.allLinks.isEmpty)
    }
}

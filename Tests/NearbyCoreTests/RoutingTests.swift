import Foundation
import Testing
@testable import NearbyCore

@Suite struct LinkMetricsTests {
    @Test func costFormula() {
        let metrics = LinkMetrics(latencyMs: 50, lossFraction: 0.1, jitterMs: 4, ageSeconds: 10, bandwidthKbps: 1000)
        #expect(metrics.cost == 90)
    }

    @Test func youngLinkPenaltyBelowFiveSeconds() {
        let metrics = LinkMetrics(latencyMs: 50, lossFraction: 0, jitterMs: 0, ageSeconds: 4.9, bandwidthKbps: 1000)
        #expect(metrics.cost == 80)
    }

    @Test func noPenaltyAtFiveSeconds() {
        let metrics = LinkMetrics(latencyMs: 50, lossFraction: 0, jitterMs: 0, ageSeconds: 5, bandwidthKbps: 1000)
        #expect(metrics.cost == 50)
    }
}

@Suite struct LinkMetricsEstimatorTests {
    @Test func firstProbeSetsLatencyDirectly() {
        var estimator = LinkMetricsEstimator(bandwidthKbps: 1000, upSince: Date(timeIntervalSince1970: 0))
        estimator.recordProbe(rttMs: 30)
        #expect(estimator.metrics(now: Date(timeIntervalSince1970: 0)).latencyMs == 15)
    }

    @Test func secondProbeAppliesEwma() {
        var estimator = LinkMetricsEstimator(bandwidthKbps: 1000, upSince: Date(timeIntervalSince1970: 0))
        estimator.recordProbe(rttMs: 30)
        estimator.recordProbe(rttMs: 50)
        #expect(estimator.metrics(now: Date(timeIntervalSince1970: 0)).latencyMs == 17)
    }

    @Test func jitterAfterTwoProbes() {
        var estimator = LinkMetricsEstimator(bandwidthKbps: 1000, upSince: Date(timeIntervalSince1970: 0))
        estimator.recordProbe(rttMs: 20)
        estimator.recordProbe(rttMs: 40)
        #expect(estimator.metrics(now: Date(timeIntervalSince1970: 0)).jitterMs == 0.2 * 10)
    }

    @Test func lossFractionAfterThreeProbesAndOneLoss() {
        var estimator = LinkMetricsEstimator(bandwidthKbps: 1000, upSince: Date(timeIntervalSince1970: 0))
        estimator.recordProbe(rttMs: 20)
        estimator.recordProbe(rttMs: 20)
        estimator.recordProbe(rttMs: 20)
        estimator.recordLoss()
        #expect(estimator.metrics(now: Date(timeIntervalSince1970: 0)).lossFraction == 0.25)
    }

    @Test func lossWindowEvicts() {
        var estimator = LinkMetricsEstimator(bandwidthKbps: 1000, upSince: Date(timeIntervalSince1970: 0))
        for _ in 0..<40 { estimator.recordLoss() }
        for _ in 0..<32 { estimator.recordProbe(rttMs: 20) }
        #expect(estimator.metrics(now: Date(timeIntervalSince1970: 0)).lossFraction == 0)
    }

    @Test func flappedResetsAge() {
        var estimator = LinkMetricsEstimator(bandwidthKbps: 1000, upSince: Date(timeIntervalSince1970: 0))
        estimator.flapped(at: Date(timeIntervalSince1970: 100))
        let ageSeconds = estimator.metrics(now: Date(timeIntervalSince1970: 130)).ageSeconds
        #expect(ageSeconds == 30)
    }
}

@Suite struct LinkStateAdvertisementTests {
    @Test func encodeDecodeRoundTrip() throws {
        let lsa = LinkStateAdvertisement(
            origin: NodeID(raw: 1),
            sequence: 7,
            neighbors: [Neighbor(id: NodeID(raw: 2), cost: 10), Neighbor(id: NodeID(raw: 3), cost: 15)]
        )
        let data = try lsa.encode()
        let decoded = try LinkStateAdvertisement.decode(data)
        #expect(decoded == lsa)
    }
}

@Suite struct LinkStateTableTests {
    @Test func applySequenceOrdering() {
        var table = LinkStateTable()
        let origin = NodeID(raw: 1)
        let now = Date(timeIntervalSince1970: 0)

        let first = LinkStateAdvertisement(origin: origin, sequence: 5, neighbors: [])
        #expect(table.apply(first, now: now) == true)

        let same = LinkStateAdvertisement(origin: origin, sequence: 5, neighbors: [])
        #expect(table.apply(same, now: now) == false)

        let lower = LinkStateAdvertisement(origin: origin, sequence: 4, neighbors: [])
        #expect(table.apply(lower, now: now) == false)

        let higher = LinkStateAdvertisement(origin: origin, sequence: 6, neighbors: [])
        #expect(table.apply(higher, now: now) == true)
    }

    @Test func expireRemovesOldOriginsAndKeepsFresh() {
        var table = LinkStateTable()
        let stale = NodeID(raw: 1)
        let fresh = NodeID(raw: 2)

        _ = table.apply(LinkStateAdvertisement(origin: stale, sequence: 1, neighbors: []), now: Date(timeIntervalSince1970: 0))
        _ = table.apply(LinkStateAdvertisement(origin: fresh, sequence: 1, neighbors: []), now: Date(timeIntervalSince1970: 9))

        let removed = table.expire(now: Date(timeIntervalSince1970: 11))
        #expect(removed == [stale])
        #expect(table.origins == [fresh])
    }

    @Test func adjacencyReflectsLatestLsaOnly() {
        var table = LinkStateTable()
        let origin = NodeID(raw: 1)
        let neighbor = NodeID(raw: 2)
        let now = Date(timeIntervalSince1970: 0)

        _ = table.apply(LinkStateAdvertisement(origin: origin, sequence: 1, neighbors: [Neighbor(id: neighbor, cost: 5)]), now: now)
        _ = table.apply(LinkStateAdvertisement(origin: origin, sequence: 2, neighbors: [Neighbor(id: neighbor, cost: 9)]), now: now)

        #expect(table.adjacency[origin]?[neighbor] == 9)
    }
}

@Suite struct PathComputerTests {
    static func makeTable(_ edges: [(NodeID, NodeID, Double)], sequence: UInt32 = 1) -> LinkStateTable {
        var byOrigin: [NodeID: [Neighbor]] = [:]
        for (a, b, cost) in edges {
            byOrigin[a, default: []].append(Neighbor(id: b, cost: cost))
        }
        var table = LinkStateTable()
        let now = Date(timeIntervalSince1970: 0)
        for (origin, neighbors) in byOrigin {
            _ = table.apply(LinkStateAdvertisement(origin: origin, sequence: sequence, neighbors: neighbors), now: now)
        }
        return table
    }

    @Test func lineTopology() {
        let a = NodeID(raw: 1), b = NodeID(raw: 2), c = NodeID(raw: 3)
        let table = Self.makeTable([(a, b, 10), (b, a, 10), (b, c, 10), (c, b, 10)])
        let routing = PathComputer.compute(from: a, table: table)

        #expect(routing.routes[c] == Route(nextHop: b, cost: 20, hops: 2))
        #expect(routing.alternateNextHop(to: c) == nil)
    }

    @Test func diamondTopologyPrimaryAndAlternate() {
        let a = NodeID(raw: 1), b = NodeID(raw: 2), c = NodeID(raw: 3), d = NodeID(raw: 4)
        let table = Self.makeTable([
            (a, b, 10), (b, a, 10),
            (a, c, 15), (c, a, 15),
            (b, d, 10), (d, b, 10),
            (c, d, 10), (d, c, 10),
        ])
        let routing = PathComputer.compute(from: a, table: table)

        #expect(routing.routes[d] == Route(nextHop: b, cost: 20, hops: 2))
        #expect(routing.alternateNextHop(to: d) == c)
    }

    @Test func directedEdgeIsNotTraversedBackwards() {
        let a = NodeID(raw: 1), b = NodeID(raw: 2)
        let table = Self.makeTable([(a, b, 10)])
        let routing = PathComputer.compute(from: b, table: table)

        #expect(routing.nextHop(to: a) == nil)
    }

    @Test func unreachableNodeIsAbsent() {
        let a = NodeID(raw: 1), b = NodeID(raw: 2), c = NodeID(raw: 3)
        let table = Self.makeTable([(a, b, 10), (b, a, 10)])
        let routing = PathComputer.compute(from: a, table: table)

        #expect(routing.routes[c] == nil)
    }

    @Test func tieBreaksBySmallerNodeID() {
        let a = NodeID(raw: 1), b = NodeID(raw: 2), c = NodeID(raw: 3), d = NodeID(raw: 4)
        let table = Self.makeTable([
            (a, b, 10), (b, a, 10),
            (a, c, 10), (c, a, 10),
            (b, d, 0), (d, b, 0),
            (c, d, 0), (d, c, 0),
        ])
        let routing = PathComputer.compute(from: a, table: table)

        #expect(routing.routes[d]?.nextHop == b)
    }
}

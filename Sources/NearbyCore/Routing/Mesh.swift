import Foundation

/// Pure mesh state for one node: per-link metrics, link-state table, and the routing table derived from them.
public struct Mesh: Sendable {
    public let localID: NodeID
    public static let probeTimeout: TimeInterval = 1

    private struct LinkRecord: Sendable {
        var estimator: LinkMetricsEstimator
        var node: NodeID?
        var outstanding: [UInt32: Date] = [:]
    }

    private var links: [LinkID: LinkRecord] = [:]
    private var table = LinkStateTable()
    // Seeded from the clock so a relaunch is not rejected as stale by peers for 10 s.
    private var localSequence = UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970))
    public private(set) var routingTable = RoutingTable()

    public init(localID: NodeID) {
        self.localID = localID
    }

    // MARK: - Links

    public mutating func linkUp(_ link: LinkID, bandwidthKbps: Double, now: Date) {
        if links[link] != nil {
            links[link]!.estimator.flapped(at: now)
        } else {
            links[link] = LinkRecord(estimator: LinkMetricsEstimator(bandwidthKbps: bandwidthKbps, upSince: now), node: nil)
        }
    }

    public mutating func linkDown(_ link: LinkID, now: Date) {
        links.removeValue(forKey: link)
        recompute()
    }

    public mutating func bind(_ link: LinkID, to node: NodeID) {
        guard links[link] != nil else { return }
        links[link]!.node = node
        recompute()
    }

    public func node(for link: LinkID) -> NodeID? {
        links[link]?.node
    }

    public func links(to neighbor: NodeID) -> [LinkID] {
        let now = Date()
        return links
            .filter { $0.value.node == neighbor }
            .keys
            .sorted { a, b in
                let costA = cost(for: a, now: now)
                let costB = cost(for: b, now: now)
                if costA != costB { return costA < costB }
                return a.description < b.description
            }
    }

    public var neighbors: [NodeID] {
        Set(links.values.compactMap(\.node)).sorted()
    }

    public var allLinks: [LinkID] {
        Array(links.keys)
    }

    // MARK: - Probes

    public mutating func probeSent(on link: LinkID, sequence: UInt32, at: Date) {
        links[link]?.outstanding[sequence] = at
    }

    public mutating func probeReply(on link: LinkID, sequence: UInt32, at: Date) -> Double? {
        guard var record = links[link], let sentAt = record.outstanding.removeValue(forKey: sequence) else { return nil }
        let rtt = at.timeIntervalSince(sentAt) * 1000
        record.estimator.recordProbe(rttMs: rtt)
        let staleKeys = record.outstanding.filter { $0.value < sentAt }.map(\.key)
        for key in staleKeys {
            record.estimator.recordLoss()
            record.outstanding.removeValue(forKey: key)
        }
        links[link] = record
        return rtt
    }

    public mutating func expireProbes(now: Date) {
        for key in links.keys {
            var record = links[key]!
            let staleKeys = record.outstanding.filter { now.timeIntervalSince($0.value) > Self.probeTimeout }.map(\.key)
            guard !staleKeys.isEmpty else { continue }
            for probeSeq in staleKeys {
                record.estimator.recordLoss()
                record.outstanding.removeValue(forKey: probeSeq)
            }
            links[key] = record
        }
    }

    public func metrics(for link: LinkID, now: Date) -> LinkMetrics? {
        links[link]?.estimator.metrics(now: now)
    }

    private func cost(for link: LinkID, now: Date) -> Double {
        guard let record = links[link] else { return .infinity }
        let measured = record.estimator.metrics(now: now)
        guard record.estimator.sampleCount == 0 else { return measured.cost }
        return LinkMetrics(latencyMs: 50, lossFraction: 0, jitterMs: 0, ageSeconds: measured.ageSeconds, bandwidthKbps: measured.bandwidthKbps).cost
    }

    // MARK: - Link state

    public mutating func localAdvertisement(now: Date) -> LinkStateAdvertisement {
        var costByNeighbor: [NodeID: Double] = [:]
        for (linkID, record) in links {
            guard let node = record.node else { continue }
            let linkCost = cost(for: linkID, now: now)
            costByNeighbor[node] = min(costByNeighbor[node] ?? .infinity, linkCost)
        }
        localSequence &+= 1
        let lsa = LinkStateAdvertisement(
            origin: localID,
            sequence: localSequence,
            neighbors: costByNeighbor.map { Neighbor(id: $0.key, cost: $0.value) }.sorted { $0.id < $1.id }
        )
        _ = table.apply(lsa, now: now)
        recompute()
        return lsa
    }

    public mutating func apply(_ lsa: LinkStateAdvertisement, now: Date) -> Bool {
        guard lsa.origin != localID else { return false }
        let applied = table.apply(lsa, now: now)
        recompute()
        return applied
    }

    public mutating func expire(now: Date) -> [NodeID] {
        let removed = table.expire(now: now)
        recompute()
        return removed
    }

    private mutating func recompute() {
        routingTable = PathComputer.compute(from: localID, table: table)
    }

    // MARK: - Routing

    public func route(to: NodeID) -> Route? {
        routingTable.routes[to]
    }

    public func nextLink(to destination: NodeID) -> LinkID? {
        if let node = primaryNextHopNode(to: destination) {
            return links(to: node).first
        }
        return nil
    }

    public func alternateLink(to destination: NodeID) -> LinkID? {
        if let altNode = routingTable.alternates[destination] {
            return links(to: altNode).first
        }
        guard let primaryNode = primaryNextHopNode(to: destination) else { return nil }
        let candidates = links(to: primaryNode)
        guard candidates.count > 1 else { return nil }
        return candidates[1]
    }

    private func primaryNextHopNode(to destination: NodeID) -> NodeID? {
        if let route = route(to: destination) { return route.nextHop }
        if neighbors.contains(destination) { return destination }
        return nil
    }

    public func reachable() -> [NodeID] {
        var all = Set(routingTable.routes.keys)
        all.formUnion(neighbors)
        all.remove(localID)
        return all.sorted()
    }
}

import Foundation

public struct Route: Sendable, Equatable {
    public var nextHop: NodeID
    public var cost: Double
    public var hops: Int

    public init(nextHop: NodeID, cost: Double, hops: Int) {
        self.nextHop = nextHop
        self.cost = cost
        self.hops = hops
    }
}

public struct RoutingTable: Sendable, Equatable {
    public var routes: [NodeID: Route]
    public var alternates: [NodeID: NodeID]

    public init(routes: [NodeID: Route] = [:], alternates: [NodeID: NodeID] = [:]) {
        self.routes = routes
        self.alternates = alternates
    }

    public func nextHop(to destination: NodeID) -> NodeID? { routes[destination]?.nextHop }

    public func alternateNextHop(to destination: NodeID) -> NodeID? { alternates[destination] }
}

public enum PathComputer {
    private struct DijkstraResult {
        var dist: [NodeID: Double]
        var prev: [NodeID: NodeID]
        var hops: [NodeID: Int]
    }

    public static func compute(from source: NodeID, table: LinkStateTable) -> RoutingTable {
        let adjacency = table.adjacency
        guard let sourceEdges = adjacency[source] else { return RoutingTable() }

        var nodes: Set<NodeID> = Set(adjacency.keys)
        for edges in adjacency.values { nodes.formUnion(edges.keys) }
        nodes.insert(source)

        let primary = dijkstra(from: source, adjacency: adjacency, nodes: nodes)

        var routes: [NodeID: Route] = [:]
        for destination in nodes where destination != source {
            guard let cost = primary.dist[destination], cost.isFinite else { continue }
            guard let nextHop = nextHopOnPath(to: destination, prev: primary.prev, source: source) else { continue }
            routes[destination] = Route(nextHop: nextHop, cost: cost, hops: primary.hops[destination] ?? 0)
        }

        var distFromNeighbor: [NodeID: [NodeID: Double]] = [:]
        for neighbor in sourceEdges.keys {
            distFromNeighbor[neighbor] = dijkstra(from: neighbor, adjacency: adjacency, nodes: nodes).dist
        }

        var alternates: [NodeID: NodeID] = [:]
        for (destination, route) in routes {
            var bestNeighbor: NodeID?
            var bestCost = Double.infinity
            for (neighbor, edgeCost) in sourceEdges where neighbor != route.nextHop {
                guard let rest = distFromNeighbor[neighbor]?[destination], rest.isFinite else { continue }
                let candidate = edgeCost + rest
                if candidate < bestCost || (candidate == bestCost && (bestNeighbor == nil || neighbor < bestNeighbor!)) {
                    bestCost = candidate
                    bestNeighbor = neighbor
                }
            }
            if let bestNeighbor { alternates[destination] = bestNeighbor }
        }

        return RoutingTable(routes: routes, alternates: alternates)
    }

    /// Walks the shortest-path tree back from `destination` to the node adjacent to `source`.
    private static func nextHopOnPath(to destination: NodeID, prev: [NodeID: NodeID], source: NodeID) -> NodeID? {
        var current = destination
        while let predecessor = prev[current] {
            if predecessor == source { return current }
            current = predecessor
        }
        return nil
    }

    private static func dijkstra(from start: NodeID, adjacency: [NodeID: [NodeID: Double]], nodes: Set<NodeID>) -> DijkstraResult {
        var dist: [NodeID: Double] = [start: 0]
        var prev: [NodeID: NodeID] = [:]
        var hops: [NodeID: Int] = [start: 0]
        var visited: Set<NodeID> = []

        while true {
            var current: NodeID?
            var currentDist = Double.infinity
            for node in nodes where !visited.contains(node) {
                guard let d = dist[node], d.isFinite else { continue }
                if current == nil || d < currentDist || (d == currentDist && node < current!) {
                    current = node
                    currentDist = d
                }
            }
            guard let u = current else { break }
            visited.insert(u)

            for (neighbor, cost) in adjacency[u] ?? [:] {
                let newDist = currentDist + cost
                let existing = dist[neighbor] ?? Double.infinity
                let isTieWithSmallerPredecessor = newDist == existing && (prev[neighbor].map { u < $0 } ?? false)
                if newDist < existing || isTieWithSmallerPredecessor {
                    dist[neighbor] = newDist
                    prev[neighbor] = u
                    hops[neighbor] = (hops[u] ?? 0) + 1
                }
            }
        }

        return DijkstraResult(dist: dist, prev: prev, hops: hops)
    }
}

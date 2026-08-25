import Foundation

public struct Neighbor: Codable, Sendable, Equatable {
    public var id: NodeID
    public var cost: Double
    public init(id: NodeID, cost: Double) {
        self.id = id
        self.cost = cost
    }
}

public struct LinkStateAdvertisement: Codable, Sendable, Equatable {
    public var origin: NodeID
    public var sequence: UInt32
    public var neighbors: [Neighbor]

    public init(origin: NodeID, sequence: UInt32, neighbors: [Neighbor]) {
        self.origin = origin
        self.sequence = sequence
        self.neighbors = neighbors
    }

    public func encode() throws -> Data { try JSONEncoder().encode(self) }

    public static func decode(_ data: Data) throws -> LinkStateAdvertisement {
        try JSONDecoder().decode(LinkStateAdvertisement.self, from: data)
    }
}

public struct LinkStateTable: Sendable {
    public static let maxAgeSeconds: TimeInterval = 10

    private var entries: [NodeID: (lsa: LinkStateAdvertisement, receivedAt: Date)] = [:]

    public init() {}

    /// Stores the LSA when its sequence is greater than the stored one for that origin (or none stored). Returns true when stored, meaning the caller must flood it.
    public mutating func apply(_ lsa: LinkStateAdvertisement, now: Date) -> Bool {
        if let existing = entries[lsa.origin], lsa.sequence <= existing.lsa.sequence {
            return false
        }
        entries[lsa.origin] = (lsa, now)
        return true
    }

    /// Removes origins whose last LSA is older than maxAgeSeconds. Returns removed origins.
    public mutating func expire(now: Date) -> [NodeID] {
        var removed: [NodeID] = []
        for (origin, entry) in entries where now.timeIntervalSince(entry.receivedAt) > Self.maxAgeSeconds {
            removed.append(origin)
        }
        for origin in removed { entries.removeValue(forKey: origin) }
        return removed
    }

    public var origins: [NodeID] { Array(entries.keys) }

    /// Directed adjacency as advertised: adjacency[a]?[b] is a's cost to b.
    public var adjacency: [NodeID: [NodeID: Double]] {
        var result: [NodeID: [NodeID: Double]] = [:]
        for (origin, entry) in entries {
            var edges: [NodeID: Double] = [:]
            for neighbor in entry.lsa.neighbors {
                edges[neighbor.id] = neighbor.cost
            }
            result[origin] = edges
        }
        return result
    }

    public func sequence(for origin: NodeID) -> UInt32? {
        entries[origin]?.lsa.sequence
    }
}

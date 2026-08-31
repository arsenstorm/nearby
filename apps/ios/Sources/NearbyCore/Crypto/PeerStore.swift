import Foundation

public struct PeerRecord: Codable, Sendable, Equatable {
    public var id: NodeID
    public var signingPublicKey: Data
    public var name: String
    public var firstSeen: Date
}

public enum PeerStoreError: Error, Sendable, Equatable {
    case badSignature
    case keyChanged(existing: PeerRecord)
}

public struct PeerStore: Sendable {
    public private(set) var records: [NodeID: PeerRecord]

    public init() {
        self.records = [:]
    }

    public init(snapshot: Data) throws {
        let list = try JSONDecoder().decode([PeerRecord].self, from: snapshot)
        self.records = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    public func snapshot() throws -> Data {
        try JSONEncoder().encode(Array(records.values))
    }

    public mutating func observe(_ hello: Hello, now: Date) throws(PeerStoreError) -> PeerRecord {
        guard hello.verify() else { throw PeerStoreError.badSignature }
        if let existing = records[hello.nodeID] {
            guard existing.signingPublicKey == hello.signingPublicKey else {
                throw PeerStoreError.keyChanged(existing: existing)
            }
            var updated = existing
            // The name now arrives sealed via a profile message; the Hello carries an empty name, so
            // an empty one never overwrites a name we already learned.
            if !hello.name.isEmpty { updated.name = hello.name }
            records[hello.nodeID] = updated
            return updated
        }
        let record = PeerRecord(
            id: hello.nodeID,
            signingPublicKey: hello.signingPublicKey,
            name: hello.name,
            firstSeen: now
        )
        records[hello.nodeID] = record
        return record
    }

    public mutating func trust(_ hello: Hello, now: Date) throws(PeerStoreError) -> PeerRecord {
        guard hello.verify() else { throw PeerStoreError.badSignature }
        let firstSeen = records[hello.nodeID]?.firstSeen ?? now
        let record = PeerRecord(
            id: hello.nodeID,
            signingPublicKey: hello.signingPublicKey,
            name: hello.name,
            firstSeen: firstSeen
        )
        records[hello.nodeID] = record
        return record
    }

    /// A scanned card is trusted as-is; the first Hello must then carry this exact signing key.
    /// Never overwrites a record we already hold: the key we saw in person outranks a scanned one.
    public mutating func add(_ card: PeerCard, now: Date) -> PeerRecord {
        if let existing = records[card.nodeID] { return existing }
        let record = PeerRecord(id: card.nodeID, signingPublicKey: card.signingPublicKey, name: card.name, firstSeen: now)
        records[card.nodeID] = record
        return record
    }

    /// Applies a name learned from a sealed profile message; no-op for an unknown peer.
    public mutating func rename(_ id: NodeID, to name: String) {
        guard var record = records[id] else { return }
        record.name = name
        records[id] = record
    }

    public mutating func remove(_ id: NodeID) {
        records[id] = nil
    }

    public func record(for id: NodeID) -> PeerRecord? {
        records[id]
    }
}

extension PeerStore: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let list = try container.decode([PeerRecord].self)
        self.records = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Array(records.values))
    }
}

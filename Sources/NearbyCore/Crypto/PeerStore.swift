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
            updated.name = hello.name
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

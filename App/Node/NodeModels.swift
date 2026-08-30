import Foundation
import NearbyCore

struct PeerSummary: Identifiable, Equatable, Sendable {
    let id: NodeID
    var name: String
    var lastSeen: Date
    var links: [LinkID]
}

struct JoinedRoom: Equatable, Sendable {
    let id: RoomID
    var name: String
    var host: NodeID
    var members: [Member]
    var roomKey: Data
}

enum JoinState: Equatable, Sendable {
    case idle
    case requested(RoomID)
    case rejected(String)
}

struct PeerKeyWarning: Equatable, Sendable {
    let hello: Hello
    let existing: PeerRecord
}

struct TransportState: Equatable, Sendable {
    var supported: Bool
    var enabled: Bool
    var active: Bool
    var linkCount: Int
}

struct PathInfo: Equatable, Sendable {
    var hops: Int
    var costMs: Double
    var nextLink: LinkID?
    var latencyMs: Double
    var lossFraction: Double
    var jitterMs: Double
}

/// A relayed edge is the only way to `peer` and this device holds no entitlement (PRD R5).
struct PaywallPrompt: Identifiable, Equatable, Sendable {
    let peer: NodeID
    var id: NodeID { peer }
}

struct PacketCounters: Equatable, Sendable {
    var sent = 0
    var received = 0
    var relayed = 0
    var droppedDedup = 0
    var droppedTTL = 0
}

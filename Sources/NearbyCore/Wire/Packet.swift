import Foundation

public enum PacketType: UInt8, Sendable, CaseIterable {
    case hello = 0, linkState = 1, control = 2, voice = 3, ack = 4, probe = 5
}

/// Fixed 32-byte header. Bytes 0-22 are the AEAD associated data; TTL (byte 23) is excluded because relays decrement it.
public struct PacketHeader: Hashable, Sendable {
    public static let size = 32
    public static let version: UInt8 = 1
    public static let initialTTL: UInt8 = 8

    public var type: PacketType
    public var source: NodeID
    public var destination: NodeID
    public var stream: UInt8
    public var sequence: UInt32
    public var ttl: UInt8

    public init(type: PacketType, source: NodeID, destination: NodeID = .broadcast,
                stream: UInt8 = 0, sequence: UInt32, ttl: UInt8 = PacketHeader.initialTTL) {
        self.type = type; self.source = source; self.destination = destination
        self.stream = stream; self.sequence = sequence; self.ttl = ttl
    }

    public func encode() -> Data {
        var d = Data(capacity: Self.size)
        d.append(Self.version)
        d.append(type.rawValue)
        d.append(source.bytes)
        d.append(destination.bytes)
        d.append(stream)
        d.append(contentsOf: withUnsafeBytes(of: sequence.bigEndian) { Array($0) })
        d.append(ttl)
        d.append(Data(count: 8))
        return d
    }

    /// nil when shorter than 32 bytes, wrong version, or unknown type.
    public init?(decoding data: Data) {
        guard data.count >= Self.size else { return nil }
        let b = [UInt8](data.prefix(Self.size))
        guard b[0] == Self.version, let type = PacketType(rawValue: b[1]) else { return nil }
        func u64(_ o: Int) -> UInt64 { b[o..<o + 8].reduce(0) { ($0 << 8) | UInt64($1) } }
        self.type = type
        self.source = NodeID(raw: u64(2))
        self.destination = NodeID(raw: u64(10))
        self.stream = b[18]
        self.sequence = b[19..<23].reduce(0) { ($0 << 8) | UInt32($1) }
        self.ttl = b[23]
    }

    public var associatedData: Data { encode().prefix(23) }
}

public struct Packet: Hashable, Sendable {
    public static let maxSize = 1200

    public var header: PacketHeader
    public var payload: Data

    public init(header: PacketHeader, payload: Data) { self.header = header; self.payload = payload }

    public func encode() -> Data { header.encode() + payload }

    public init?(decoding data: Data) {
        guard data.count <= Self.maxSize, let header = PacketHeader(decoding: data) else { return nil }
        self.header = header
        self.payload = data.dropFirst(PacketHeader.size)
    }
}

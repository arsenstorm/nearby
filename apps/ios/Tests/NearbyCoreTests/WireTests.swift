import Foundation
import Testing
@testable import NearbyCore

@Suite struct PacketHeaderTests {
    @Test func roundTrip() {
        let source = NodeID(raw: 0x8000_0000_0000_0001)
        let destination = NodeID(raw: 0x8000_0000_0000_0002)
        let header = PacketHeader(type: .voice, source: source, destination: destination,
                                   stream: 7, sequence: 0xDEADBEEF, ttl: 3)
        let decoded = PacketHeader(decoding: header.encode())
        #expect(decoded?.type == .voice)
        #expect(decoded?.source == source)
        #expect(decoded?.destination == destination)
        #expect(decoded?.stream == 7)
        #expect(decoded?.sequence == 0xDEADBEEF)
        #expect(decoded?.ttl == 3)
    }

    @Test func decodeRejectsShortData() {
        let header = PacketHeader(type: .voice, source: .broadcast, sequence: 1)
        let truncated = header.encode().prefix(31)
        #expect(PacketHeader(decoding: truncated) == nil)
    }

    @Test func decodeRejectsWrongVersion() {
        let header = PacketHeader(type: .voice, source: .broadcast, sequence: 1)
        var data = header.encode()
        data[0] = PacketHeader.version &+ 1
        #expect(PacketHeader(decoding: data) == nil)
    }

    @Test func associatedDataMatchesEncodePrefix() {
        let header = PacketHeader(type: .voice, source: .broadcast, sequence: 1)
        let encoded = header.encode()
        #expect(header.associatedData == encoded.prefix(header.associatedData.count))
    }
}

@Suite struct PacketTests {
    @Test func decodeRejectsOversizedData() {
        let data = Data(count: 1201)
        #expect(Packet(decoding: data) == nil)
    }
}

@Suite struct DedupTests {
    @Test func firstIsNew() {
        var dedup = Dedup()
        #expect(dedup.check(source: NodeID(raw: 1), stream: 0, sequence: 1) == true)
    }

    @Test func duplicateIsDropped() {
        var dedup = Dedup()
        let source = NodeID(raw: 1)
        #expect(dedup.check(source: source, stream: 0, sequence: 1) == true)
        #expect(dedup.check(source: source, stream: 0, sequence: 1) == false)
    }

    @Test func newerIsAccepted() {
        var dedup = Dedup()
        let source = NodeID(raw: 1)
        #expect(dedup.check(source: source, stream: 0, sequence: 1) == true)
        #expect(dedup.check(source: source, stream: 0, sequence: 2) == true)
    }

    @Test func olderThanWindowIsDropped() {
        var dedup = Dedup(windowSize: 8)
        let source = NodeID(raw: 1)
        #expect(dedup.check(source: source, stream: 0, sequence: 100) == true)
        #expect(dedup.check(source: source, stream: 0, sequence: 91) == false)
    }

    @Test func droppedCountMatchesFalseResults() {
        var dedup = Dedup(windowSize: 8)
        let source = NodeID(raw: 1)
        var falses = 0
        for result in [
            dedup.check(source: source, stream: 0, sequence: 100),
            dedup.check(source: source, stream: 0, sequence: 100),
            dedup.check(source: source, stream: 0, sequence: 91),
            dedup.check(source: source, stream: 0, sequence: 101),
        ] {
            if !result { falses += 1 }
        }
        #expect(dedup.dropped == falses)
    }

    @Test func streamsAreIndependent() {
        var dedup = Dedup()
        let source = NodeID(raw: 1)
        #expect(dedup.check(source: source, stream: 0, sequence: 1) == true)
        #expect(dedup.check(source: source, stream: 1, sequence: 1) == true)
    }
}

import Foundation

/// Opus frames keyed by sequence, reordered and depaced for playback.
public struct JitterBuffer: Sendable {
    public enum Output: Sendable, Equatable {
        case frame(Data)
        case missing
    }

    public struct Stats: Sendable, Equatable {
        public var received = 0
        public var played = 0
        public var missing = 0
        public var late = 0
        public var reset = 0
        public var skipped = 0
    }

    public var targetDepth: Int
    private let maxDepth: Int
    public private(set) var stats = Stats()

    private var frames: [UInt32: Data] = [:]
    private var nextSequence: UInt32?
    private var buffering = true

    public init(targetDepth: Int = 3, maxDepth: Int = 50) {
        self.targetDepth = targetDepth
        self.maxDepth = maxDepth
    }

    public var isBuffering: Bool { buffering }
    public var depth: Int { frames.count }

    public mutating func push(sequence: UInt32, frame: Data) {
        stats.received += 1

        if nextSequence == nil {
            nextSequence = sequence
        }
        guard let next = nextSequence else { return }

        if sequence < next {
            stats.late += 1
            return
        }
        if sequence >= next + UInt32(maxDepth) {
            stats.reset += 1
            frames.removeAll()
            nextSequence = sequence
            buffering = true
        }

        frames[sequence] = frame
        if buffering && frames.count >= targetDepth {
            buffering = false
        }
    }

    public mutating func pop() -> Output? {
        guard !buffering, var seq = nextSequence else { return nil }
        // A burst after a stall leaves the buffer deep forever; skip ahead so latency comes back down.
        if frames.count > targetDepth * 2 {
            let keep = frames.keys.sorted().suffix(targetDepth)
            let first = keep.first!
            frames = frames.filter { $0.key >= first }
            stats.skipped += Int(first - seq)
            seq = first
        }
        nextSequence = seq + 1

        if let f = frames.removeValue(forKey: seq) {
            stats.played += 1
            return .frame(f)
        } else if frames.isEmpty {
            buffering = true
            nextSequence = seq
            return nil
        } else {
            stats.missing += 1
            return .missing
        }
    }

    public mutating func reset() {
        frames.removeAll()
        nextSequence = nil
        buffering = true
    }
}

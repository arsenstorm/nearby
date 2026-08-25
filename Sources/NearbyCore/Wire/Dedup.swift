public struct Dedup: Sendable {
    private struct Key: Hashable {
        var source: NodeID
        var stream: UInt8
    }

    private struct State {
        var highest: UInt32
        var seen: Set<UInt32>
    }

    private let windowSize: UInt32
    private var state: [Key: State] = [:]
    public private(set) var dropped = 0

    public init(windowSize: UInt32 = 1024) {
        self.windowSize = windowSize
    }

    public mutating func check(source: NodeID, stream: UInt8, sequence: UInt32) -> Bool {
        let key = Key(source: source, stream: stream)

        guard var entry = state[key] else {
            state[key] = State(highest: sequence, seen: [sequence])
            return true
        }

        if sequence > entry.highest {
            entry.seen.insert(sequence)
            entry.highest = sequence
            if entry.highest >= windowSize {
                let cutoff = entry.highest &- windowSize
                entry.seen = entry.seen.filter { $0 >= cutoff }
            }
            state[key] = entry
            return true
        } else if entry.highest - sequence >= windowSize {
            dropped += 1
            return false
        } else if entry.seen.contains(sequence) {
            dropped += 1
            return false
        } else {
            entry.seen.insert(sequence)
            state[key] = entry
            return true
        }
    }
}

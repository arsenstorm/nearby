import Foundation

/// Decides per frame whether captured audio is worth sending. Silence still lets one frame per
/// second through so the receiver sees a live stream. Tracks the noise floor so a quiet room and a
/// windy helmet get the same relative threshold.
public struct SilenceGate: Sendable {
    public static let keepaliveInterval = 1000 / Opus.frameMs

    private let ratio: Float
    private let hangoverFrames: Int
    private var floor: Float
    private var hangover = 0
    private var gatedFrames = 0

    /// - ratio: how far above the tracked noise floor a frame must be to count as speech (3 ≈ +10 dB).
    /// - hangoverMs: how long after the last speech frame to keep sending, so word tails survive.
    public init(ratio: Float = 3, hangoverMs: Int = 300, initialFloor: Float = 0.002) {
        self.ratio = ratio
        self.hangoverFrames = hangoverMs / Opus.frameMs
        self.floor = initialFloor
    }

    /// True when the frame should be encoded and sent.
    public mutating func admits(rms: Float) -> Bool {
        // Floor follows quiet frames quickly and loud ones slowly, so speech does not lift it.
        floor += (rms < floor ? 0.2 : 0.005) * (rms - floor)
        if rms > max(floor * ratio, 0.001) {
            hangover = hangoverFrames
            gatedFrames = 0
            return true
        }
        if hangover > 0 {
            hangover -= 1
            return true
        }
        gatedFrames += 1
        if gatedFrames >= Self.keepaliveInterval {
            gatedFrames = 0
            return true
        }
        return false
    }

    public static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}

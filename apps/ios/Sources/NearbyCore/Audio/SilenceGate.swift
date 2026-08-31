import Foundation

/// Decides per frame whether captured audio is worth sending. Silence still lets one frame per
/// second through so the receiver sees a live stream. Tracks the noise floor so a quiet room and a
/// windy helmet get the same relative threshold.
public struct SilenceGate: Sendable {
    public static let keepaliveInterval = 1000 / Opus.frameMs

    private let ratio: Float
    private let hangoverFrames: Int
    private let onsetFrames: Int
    private var floor: Float
    private var hangover = 0
    private var onset = 0
    private var gatedFrames = 0
    public private(set) var justOpened = false

    /// - ratio: how far above the tracked noise floor a frame must be to count as speech (3 ≈ +10 dB).
    /// - hangoverMs: how long after the last speech frame to keep sending, so word tails survive.
    /// - onsetMs: how long a sound must stay above threshold before it opens the gate; a keyboard
    ///   click is over inside one frame, a word is not.
    public init(ratio: Float = 3, hangoverMs: Int = 300, onsetMs: Int = 0, initialFloor: Float = 0.002) {
        self.ratio = ratio
        self.hangoverFrames = hangoverMs / Opus.frameMs
        self.onsetFrames = max(onsetMs / Opus.frameMs, 1)
        self.floor = initialFloor
    }

    /// True when the frame should be encoded and sent.
    public mutating func admits(rms: Float) -> Bool {
        justOpened = false
        // Floor follows quiet frames quickly and loud ones slowly, so speech does not lift it.
        floor += (rms < floor ? 0.2 : 0.005) * (rms - floor)
        if rms > max(floor * ratio, 0.001) {
            onset += 1
            if onset >= onsetFrames {
                justOpened = (hangover == 0 && onsetFrames > 1)
                hangover = hangoverFrames
                gatedFrames = 0
                return true
            }
        } else {
            onset = 0
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

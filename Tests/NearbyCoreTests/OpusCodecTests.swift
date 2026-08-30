import Foundation
import Testing
@testable import NearbyCore

@Suite struct OpusCodecTests {
    @Test func roundTripPreservesATone() throws {
        let encoder = try OpusEncoder()
        let decoder = try OpusDecoder()
        var input = [Float](repeating: 0, count: Opus.frameSamples)
        // The decoder writes whatever the packet holds, so its buffer is sized for the largest frame.
        var output = [Float](repeating: 0, count: Opus.internetFrameSamples)
        var packetSizes: [Int] = []
        var lastEnergy: Float = 0
        for frame in 0..<10 {
            for i in 0..<Opus.frameSamples {
                let t = Float(frame * Opus.frameSamples + i) / Float(Opus.sampleRate)
                input[i] = 0.5 * sin(2 * .pi * 440 * t)
            }
            let packet = try input.withUnsafeMutableBufferPointer { try encoder.encode($0) }
            packetSizes.append(packet.count)
            _ = try output.withUnsafeMutableBufferPointer { try decoder.decode(packet, into: $0) }
            lastEnergy = output[0..<Opus.frameSamples].reduce(0) { $0 + $1 * $1 } / Float(Opus.frameSamples)
        }
        #expect(packetSizes.allSatisfy { $0 > 10 && $0 < 200 })
        // 0.5 amplitude sine has mean power 0.125; allow codec loss.
        #expect(lastEnergy > 0.06 && lastEnergy < 0.2)
    }

    @Test func twentyMsRoundTrip() throws {
        let encoder = try OpusEncoder(frameMs: Opus.internetFrameMs)
        let decoder = try OpusDecoder(frameMs: Opus.internetFrameMs)
        var input = [Float](repeating: 0, count: Opus.internetFrameSamples)
        var output = [Float](repeating: 0, count: Opus.internetFrameSamples)
        var produced = 0
        var lastEnergy: Float = 0
        for frame in 0..<10 {
            for i in 0..<Opus.internetFrameSamples {
                let t = Float(frame * Opus.internetFrameSamples + i) / Float(Opus.sampleRate)
                input[i] = 0.5 * sin(2 * .pi * 440 * t)
            }
            let packet = try input.withUnsafeMutableBufferPointer { try encoder.encode($0) }
            produced = try output.withUnsafeMutableBufferPointer { try decoder.decode(packet, into: $0) }
            lastEnergy = output.reduce(0) { $0 + $1 * $1 } / Float(Opus.internetFrameSamples)
        }
        #expect(produced == Opus.internetFrameSamples)
        #expect(lastEnergy > 0.06 && lastEnergy < 0.2)
    }

    /// AudioConverter is built around one frame size: each size gets its own decoder, and each
    /// yields its own sample count into a buffer sized for the larger one.
    @Test func eachFrameSizeDecodesThroughItsOwnDecoder() throws {
        let narrow = try OpusEncoder()
        let wide = try OpusEncoder(frameMs: Opus.internetFrameMs)
        var tone = [Float](repeating: 0, count: Opus.internetFrameSamples)
        for i in 0..<tone.count {
            tone[i] = 0.5 * sin(2 * .pi * 440 * Float(i) / Float(Opus.sampleRate))
        }
        var short = Array(tone[0..<Opus.frameSamples])
        let narrowPacket = try short.withUnsafeMutableBufferPointer { try narrow.encode($0) }
        let widePacket = try tone.withUnsafeMutableBufferPointer { try wide.encode($0) }

        // The first packet through a decoder loses the codec's 120-sample pre-skip; the second is full.
        var output = [Float](repeating: 0, count: Opus.internetFrameSamples)
        let narrowDecoder = try OpusDecoder()
        let wideDecoder = try OpusDecoder(frameMs: Opus.internetFrameMs)
        var narrowCount = 0
        var wideCount = 0
        for _ in 0..<2 {
            narrowCount = try output.withUnsafeMutableBufferPointer { try narrowDecoder.decode(narrowPacket, into: $0) }
            wideCount = try output.withUnsafeMutableBufferPointer { try wideDecoder.decode(widePacket, into: $0) }
        }
        #expect(narrowCount == Opus.frameSamples)
        #expect(wideCount == Opus.internetFrameSamples)
    }
}

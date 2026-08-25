import Foundation
import Testing
@testable import NearbyCore

@Suite struct OpusCodecTests {
    @Test func roundTripPreservesATone() throws {
        let encoder = try OpusEncoder()
        let decoder = try OpusDecoder()
        var input = [Float](repeating: 0, count: Opus.frameSamples)
        var output = [Float](repeating: 0, count: Opus.frameSamples)
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
            lastEnergy = output.reduce(0) { $0 + $1 * $1 } / Float(Opus.frameSamples)
        }
        #expect(packetSizes.allSatisfy { $0 > 10 && $0 < 200 })
        // 0.5 amplitude sine has mean power 0.125; allow codec loss.
        #expect(lastEnergy > 0.06 && lastEnergy < 0.2)
    }
}

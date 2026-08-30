import Foundation
import Testing
@testable import NearbyCore

@Suite struct SilenceGateTests {
    private func admitted(_ gate: inout SilenceGate, rms: Float, frames: Int) -> Int {
        var count = 0
        for _ in 0..<frames where gate.admits(rms: rms) { count += 1 }
        return count
    }

    @Test func silenceSendsOneKeepalivePerSecond() {
        var gate = SilenceGate()
        _ = admitted(&gate, rms: 0.0005, frames: 100)
        let twoSeconds = admitted(&gate, rms: 0.0005, frames: 200)
        #expect(twoSeconds == 2)
    }

    @Test func speechPassesEveryFrame() {
        var gate = SilenceGate()
        #expect(admitted(&gate, rms: 0.1, frames: 50) == 50)
    }

    @Test func hangoverKeepsWordTails() {
        var gate = SilenceGate()
        _ = gate.admits(rms: 0.1)
        let tail = admitted(&gate, rms: 0.0005, frames: 30)
        #expect(tail == 30)
        let afterHangover = gate.admits(rms: 0.0005)
        #expect(!afterHangover)
    }

    @Test func floorAdaptsToSteadyNoise() {
        var gate = SilenceGate()
        _ = admitted(&gate, rms: 0.02, frames: 300)
        let steady = admitted(&gate, rms: 0.02, frames: 100)
        #expect(steady <= 1)
        let loud = gate.admits(rms: 0.2)
        #expect(loud)
    }

    @Test func rmsOfSilenceIsZero() {
        let zeros = [Float](repeating: 0, count: 480)
        #expect(zeros.withUnsafeBufferPointer { SilenceGate.rms($0) } == 0)
    }
}

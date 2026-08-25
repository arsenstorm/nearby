import Foundation
import Testing
@testable import NearbyCore

@Suite struct JitterBufferTests {
    @Test func popBeforeTargetDepthReturnsNil() {
        var buffer = JitterBuffer(targetDepth: 3)
        buffer.push(sequence: 0, frame: Data([0]))
        #expect(buffer.pop() == nil)
    }

    @Test func popsInOrderOnceAtTargetDepth() {
        var buffer = JitterBuffer(targetDepth: 3)
        buffer.push(sequence: 0, frame: Data([0]))
        buffer.push(sequence: 1, frame: Data([1]))
        buffer.push(sequence: 2, frame: Data([2]))
        #expect(buffer.pop() == .frame(Data([0])))
        #expect(buffer.pop() == .frame(Data([1])))
        #expect(buffer.pop() == .frame(Data([2])))
    }

    @Test func gapYieldsMissing() {
        var buffer = JitterBuffer(targetDepth: 3)
        buffer.push(sequence: 0, frame: Data([0]))
        buffer.push(sequence: 1, frame: Data([1]))
        buffer.push(sequence: 3, frame: Data([3]))
        #expect(buffer.pop() == .frame(Data([0])))
        #expect(buffer.pop() == .frame(Data([1])))
        #expect(buffer.pop() == .missing)
        #expect(buffer.pop() == .frame(Data([3])))
        #expect(buffer.stats.missing == 1)
    }

    @Test func lateFrameIsCountedAndDropped() {
        var buffer = JitterBuffer(targetDepth: 1)
        buffer.push(sequence: 5, frame: Data([5]))
        buffer.push(sequence: 2, frame: Data([2]))
        #expect(buffer.stats.late == 1)
        #expect(buffer.pop() == .frame(Data([5])))
    }

    @Test func farAheadFrameTriggersReset() {
        var buffer = JitterBuffer(targetDepth: 3, maxDepth: 5)
        buffer.push(sequence: 0, frame: Data([0]))
        buffer.push(sequence: 10, frame: Data([10]))
        #expect(buffer.stats.reset == 1)
        #expect(buffer.isBuffering == true)
    }

    @Test func underrunAfterDrainingSetsBuffering() {
        var buffer = JitterBuffer(targetDepth: 1)
        buffer.push(sequence: 0, frame: Data([0]))
        #expect(buffer.pop() == .frame(Data([0])))
        #expect(buffer.isBuffering == false)
        #expect(buffer.pop() == nil)
        #expect(buffer.isBuffering == true)
    }

    @Test func resetClearsDepth() {
        var buffer = JitterBuffer(targetDepth: 1)
        buffer.push(sequence: 0, frame: Data([0]))
        buffer.push(sequence: 1, frame: Data([1]))
        buffer.reset()
        #expect(buffer.depth == 0)
    }
}

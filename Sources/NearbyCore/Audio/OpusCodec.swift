import AudioToolbox
import Foundation

public enum Opus {
    public static let sampleRate: Double = 48000
    public static let frameMs = 10
    public static let frameSamples = Int(sampleRate) * frameMs / 1000
    public static let maxPacketBytes = 1275

    static var pcmFormat: AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    }

    static var opusFormat: AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(frameSamples), mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
    }
}

public struct OpusError: Error, Sendable { public let status: OSStatus }

/// Returned by the input callbacks once a frame is consumed. A zero-packet return would mark end of stream and silence every later call.
private let noMoreInputNow: OSStatus = 0x6E6D6F72  // 'nmor'

/// One converter call per frame. Not thread-safe: the caller serializes.
public final class OpusEncoder: @unchecked Sendable {
    private var converter: AudioConverterRef?
    private var pending: UnsafeMutableBufferPointer<Float>?
    private var consumed = false

    public init(bitrate: UInt32 = 24000) throws {
        var input = Opus.pcmFormat
        var output = Opus.opusFormat
        var status = AudioConverterNew(&input, &output, &converter)
        guard status == noErr, let converter else { throw OpusError(status: status) }
        var rate = bitrate
        status = AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &rate)
        guard status == noErr else { throw OpusError(status: status) }
    }

    deinit { if let converter { AudioConverterDispose(converter) } }

    /// `pcm` must hold exactly `Opus.frameSamples` samples.
    public func encode(_ pcm: UnsafeMutableBufferPointer<Float>) throws -> Data {
        precondition(pcm.count == Opus.frameSamples)
        pending = pcm
        consumed = false
        var out = Data(count: Opus.maxPacketBytes)
        var packets: UInt32 = 1
        var description = AudioStreamPacketDescription()
        let status: OSStatus = out.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            return AudioConverterFillComplexBuffer(
                converter!, encoderInput, Unmanaged.passUnretained(self).toOpaque(),
                &packets, &list, &description)
        }
        guard status == noErr || status == noMoreInputNow, packets == 1 else { throw OpusError(status: status) }
        return out.prefix(Int(description.mDataByteSize))
    }
}

private func encoderInput(
    _ converter: AudioConverterRef, _ packetCount: UnsafeMutablePointer<UInt32>,
    _ ioData: UnsafeMutablePointer<AudioBufferList>,
    _ descriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    let encoder = Unmanaged<OpusEncoder>.fromOpaque(userData!).takeUnretainedValue()
    return encoder.supply(packetCount, ioData)
}

extension OpusEncoder {
    fileprivate func supply(_ packetCount: UnsafeMutablePointer<UInt32>, _ ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard !consumed, let pending else {
            packetCount.pointee = 0
            return noMoreInputNow
        }
        consumed = true
        packetCount.pointee = UInt32(pending.count)
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mNumberChannels = 1
        ioData.pointee.mBuffers.mDataByteSize = UInt32(pending.count * 4)
        ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(pending.baseAddress)
        return noErr
    }
}

/// Not thread-safe: the caller serializes.
public final class OpusDecoder: @unchecked Sendable {
    private var converter: AudioConverterRef?
    private var packet: Data?
    private var consumed = false
    private var packetDescription = AudioStreamPacketDescription()

    public init() throws {
        var input = Opus.opusFormat
        var output = Opus.pcmFormat
        let status = AudioConverterNew(&input, &output, &converter)
        guard status == noErr, converter != nil else { throw OpusError(status: status) }
    }

    deinit { if let converter { AudioConverterDispose(converter) } }

    /// Writes `Opus.frameSamples` samples into `pcm`.
    @discardableResult
    public func decode(_ packet: Data, into pcm: UnsafeMutableBufferPointer<Float>) throws -> Int {
        precondition(pcm.count >= Opus.frameSamples)
        self.packet = packet
        consumed = false
        var frames = UInt32(Opus.frameSamples)
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 1, mDataByteSize: UInt32(pcm.count * 4), mData: UnsafeMutableRawPointer(pcm.baseAddress)))
        let status = AudioConverterFillComplexBuffer(
            converter!, decoderInput, Unmanaged.passUnretained(self).toOpaque(), &frames, &list, nil)
        guard status == noErr || status == noMoreInputNow else { throw OpusError(status: status) }
        let produced = Int(frames)
        if produced < Opus.frameSamples {
            for i in produced..<Opus.frameSamples { pcm[i] = 0 }
        }
        return Opus.frameSamples
    }

    fileprivate func supply(
        _ packetCount: UnsafeMutablePointer<UInt32>, _ ioData: UnsafeMutablePointer<AudioBufferList>,
        _ descriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?
    ) -> OSStatus {
        guard !consumed, let packet else {
            packetCount.pointee = 0
            return noMoreInputNow
        }
        consumed = true
        packetCount.pointee = 1
        packetDescription = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mNumberChannels = 1
        ioData.pointee.mBuffers.mDataByteSize = UInt32(packet.count)
        // The packet buffer lives in self.packet until the next call, so the pointer stays valid for this pull.
        ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: (packet as NSData).bytes)
        withUnsafeMutablePointer(to: &packetDescription) { descriptions?.pointee = $0 }
        return noErr
    }
}

private func decoderInput(
    _ converter: AudioConverterRef, _ packetCount: UnsafeMutablePointer<UInt32>,
    _ ioData: UnsafeMutablePointer<AudioBufferList>,
    _ descriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    let decoder = Unmanaged<OpusDecoder>.fromOpaque(userData!).takeUnretainedValue()
    return decoder.supply(packetCount, ioData, descriptions)
}

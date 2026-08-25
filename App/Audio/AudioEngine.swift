import AVFoundation
import Foundation
import NearbyCore
import os

/// Owns AVAudioSession and AVAudioEngine. Encoded frames leave through onFrame; received frames arrive through push.
final class AudioEngine: @unchecked Sendable {
    private final class Stream: @unchecked Sendable {
        var jitter: JitterBuffer
        let decoder: OpusDecoder
        var pcm = [Float](repeating: 0, count: Opus.frameSamples)
        var readIndex = Opus.frameSamples

        init(jitter: JitterBuffer, decoder: OpusDecoder) {
            self.jitter = jitter
            self.decoder = decoder
        }
    }

    private struct Shared {
        var streams: [NodeID: Stream] = [:]
        var targetDepth = 3
        var running = false
    }

    private let onFrame: @Sendable (Data) -> Void
    private let engine = AVAudioEngine()
    private let codecFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Opus.sampleRate, channels: 1, interleaved: false)!

    /// Stream table, target depth and run flag; every access takes the lock.
    private let shared = OSAllocatedUnfairLock(initialState: Shared())

    /// Tap thread only.
    private var encoder: OpusEncoder?
    /// Tap thread only.
    private var converter: AVAudioConverter?
    /// Tap thread only.
    private var converterInputFormat: AVAudioFormat?
    /// Tap thread only.
    private var accumulator: [Float] = []
    /// Tap thread only.
    private var scratch = [Float](repeating: 0, count: Opus.frameSamples)

    /// start/stop only.
    private var sourceNode: AVAudioSourceNode?
    /// start/stop only.
    private var observers: [NSObjectProtocol] = []

    init(onFrame: @escaping @Sendable (Data) -> Void) {
        self.onFrame = onFrame
    }

    var isRunning: Bool { shared.withLock { $0.running } }

    var ioLatencyMs: Double {
        guard isRunning else { return 0 }
        let session = AVAudioSession.sharedInstance()
        return (session.inputLatency + session.outputLatency + session.ioBufferDuration) * 1000
    }

    var jitterTargetDepth: Int {
        get { shared.withLock { $0.targetDepth } }
        set {
            shared.withLock {
                $0.targetDepth = newValue
                for stream in $0.streams.values { stream.jitter.targetDepth = newValue }
            }
        }
    }

    func start() throws {
        guard !isRunning else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord, mode: .voiceChat,
            options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker])
        try session.setPreferredSampleRate(Opus.sampleRate)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
        try? session.setPreferredInput(Self.preferredInput())
        installObservers()

        // Echo cancellation must be enabled before the tap is installed and the engine starts.
        try engine.inputNode.setVoiceProcessingEnabled(true)

        encoder = try OpusEncoder()
        converter = nil
        converterInputFormat = nil
        accumulator.removeAll(keepingCapacity: true)

        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(Opus.frameSamples),
                         format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            self?.captured(buffer)
        }

        let source = AVAudioSourceNode(format: codecFormat) { [weak self] _, _, frameCount, audioBufferList in
            self?.render(frameCount, audioBufferList) ?? noErr
        }
        sourceNode = source
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: codecFormat)

        engine.prepare()
        try engine.start()
        shared.withLock { $0.running = true }
    }

    // MARK: - Input selection

    private static let preferredInputKey = "audio.preferredInputUID"

    /// Inputs the session can use; requires the record category to be set, which start() does anyway.
    static func availableInputs() -> [AVAudioSessionPortDescription] {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat,
                                 options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker])
        return session.availableInputs ?? []
    }

    static var preferredInputUID: String? {
        get { UserDefaults.standard.string(forKey: preferredInputKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: preferredInputKey)
            try? AVAudioSession.sharedInstance().setPreferredInput(preferredInput())
        }
    }

    /// nil means the system default; a stored UID that is no longer available also falls back to it.
    private static func preferredInput() -> AVAudioSessionPortDescription? {
        guard let uid = preferredInputUID else { return nil }
        return AVAudioSession.sharedInstance().availableInputs?.first { $0.uid == uid }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let sourceNode {
            engine.detach(sourceNode)
            self.sourceNode = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
        encoder = nil
        shared.withLock { $0.running = false }
    }

    func addStream(_ peer: NodeID) {
        shared.withLock {
            guard $0.streams[peer] == nil, let decoder = try? OpusDecoder() else { return }
            $0.streams[peer] = Stream(jitter: JitterBuffer(targetDepth: $0.targetDepth), decoder: decoder)
        }
    }

    func removeStream(_ peer: NodeID) {
        shared.withLock { $0.streams[peer] = nil }
    }

    func push(_ peer: NodeID, sequence: UInt32, frame: Data) {
        shared.withLock { $0.streams[peer]?.jitter.push(sequence: sequence, frame: frame) }
    }

    func stats(for peer: NodeID) -> JitterBuffer.Stats? {
        shared.withLock { $0.streams[peer]?.jitter.stats }
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended,
                  let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                  AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            else { return }
            self.restart()
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self, !self.engine.isRunning else { return }
            self.restart()
        })
        // Enabling voice processing reconfigures the I/O unit right after start; the engine stops itself and
        // stays stopped unless restarted from here.
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.restart()
        })
    }

    private func restart() {
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()
    }

    private func captured(_ buffer: AVAudioPCMBuffer) {
        guard let encoder, buffer.frameLength > 0 else { return }
        let inputFormat = buffer.format

        if converterInputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: codecFormat)
            converterInputFormat = inputFormat
        }
        guard let converter, inputFormat.sampleRate > 0 else { return }

        let ratio = codecFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + AVAudioFrameCount(Opus.frameSamples)
        guard let converted = AVAudioPCMBuffer(pcmFormat: codecFormat, frameCapacity: capacity) else { return }

        // The input block runs synchronously inside convert, on this same thread.
        nonisolated(unsafe) let source = buffer
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return source
        }
        guard error == nil, let samples = converted.floatChannelData?[0] else { return }
        accumulator.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(converted.frameLength)))

        while accumulator.count >= Opus.frameSamples {
            for i in 0..<Opus.frameSamples { scratch[i] = accumulator[i] }
            accumulator.removeFirst(Opus.frameSamples)
            if let packet = try? scratch.withUnsafeMutableBufferPointer({ try encoder.encode($0) }), !packet.isEmpty {
                onFrame(packet)
            }
        }
    }

    private func render(_ frameCount: AVAudioFrameCount, _ audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard let mData = audioBufferList.pointee.mBuffers.mData else { return noErr }
        nonisolated(unsafe) let out = mData.assumingMemoryBound(to: Float.self)
        let count = Int(frameCount)
        out.update(repeating: 0, count: count)

        // ponytail: the render thread takes an unfair lock; acceptable for a handful of peers.
        shared.withLock { state in
            for stream in state.streams.values {
                var written = 0
                while written < count {
                    if stream.readIndex >= stream.pcm.count {
                        var decoded = false
                        if case .frame(let data) = stream.jitter.pop(), !data.isEmpty {
                            decoded = (try? stream.pcm.withUnsafeMutableBufferPointer {
                                try stream.decoder.decode(data, into: $0)
                            }) != nil
                        }
                        if !decoded {
                            for i in 0..<stream.pcm.count { stream.pcm[i] = 0 }
                        }
                        stream.readIndex = 0
                    }
                    let take = min(count - written, stream.pcm.count - stream.readIndex)
                    for i in 0..<take { out[written + i] += stream.pcm[stream.readIndex + i] }
                    written += take
                    stream.readIndex += take
                }
            }
        }

        for i in 0..<count { out[i] = min(max(out[i], -1), 1) }
        return noErr
    }
}

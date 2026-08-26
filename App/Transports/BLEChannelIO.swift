import Foundation

/// Length-prefixed framing over an L2CAP channel's stream pair. Owned entirely by the
/// "nearby.ble" run loop thread; BLETransport's queue reaches it only through `onChannelThread`.
final class ChannelIO: NSObject, StreamDelegate {
    enum Event {
        case up
        case down
        case frame(Data)
    }

    private let input: InputStream
    private let output: OutputStream
    private let handler: (Event) -> Void
    private var inBuffer = Data()
    private var outBuffer = Data()
    private var closed = false

    init(input: InputStream, output: OutputStream, handler: @escaping (Event) -> Void) {
        self.input = input
        self.output = output
        self.handler = handler
        super.init()
    }

    func open() {
        input.delegate = self
        output.delegate = self
        input.schedule(in: .current, forMode: .default)
        output.schedule(in: .current, forMode: .default)
        input.open()
        output.open()
    }

    func close() {
        guard !closed else { return }
        closed = true
        input.delegate = nil
        output.delegate = nil
        input.close()
        output.close()
        input.remove(from: .current, forMode: .default)
        output.remove(from: .current, forMode: .default)
    }

    func enqueue(_ payload: Data) {
        guard !closed else { return }
        outBuffer.append(UInt8(truncatingIfNeeded: payload.count >> 8))
        outBuffer.append(UInt8(truncatingIfNeeded: payload.count))
        outBuffer.append(payload)
        flush()
    }

    func stream(_ stream: Stream, handle event: Stream.Event) {
        switch event {
        case .openCompleted where stream === input:
            handler(.up)
        case .hasBytesAvailable:
            drain()
        case .hasSpaceAvailable:
            flush()
        case .errorOccurred, .endEncountered:
            fail()
        default:
            break
        }
    }

    private func fail() {
        guard !closed else { return }
        close()
        handler(.down)
    }

    private func drain() {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while input.hasBytesAvailable {
            let count = input.read(&chunk, maxLength: chunk.count)
            guard count > 0 else {
                fail()
                return
            }
            inBuffer.append(contentsOf: chunk[0..<count])
        }
        while inBuffer.count >= 2 {
            let start = inBuffer.startIndex
            let length = Int(inBuffer[start]) << 8 | Int(inBuffer[start + 1])
            guard inBuffer.count >= 2 + length else { return }
            handler(.frame(inBuffer.subdata(in: (start + 2)..<(start + 2 + length))))
            inBuffer.removeFirst(2 + length)
        }
    }

    private func flush() {
        while !outBuffer.isEmpty, output.hasSpaceAvailable {
            let written = outBuffer.withUnsafeBytes { raw in
                output.write(raw.bindMemory(to: UInt8.self).baseAddress!, maxLength: raw.count)
            }
            guard written > 0 else {
                fail()
                return
            }
            outBuffer.removeFirst(written)
        }
    }
}

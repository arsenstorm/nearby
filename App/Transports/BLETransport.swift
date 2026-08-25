import CoreBluetooth
import Foundation
import NearbyCore

/// TransportError lives in DatagramTransport.swift and has no case for these two.
private enum BLETransportError: Error {
    case bluetoothUnsupported
    case frameTooLarge
}

/// L2CAP channels over BLE. Every device advertises a channel and scans for others; the lexicographic
/// tie-break in `didUpdateValueFor` keeps a pair from opening two channels to each other.
final class BLETransport: NSObject, Transport, @unchecked Sendable {
    // CBUUID is not Sendable but is immutable once constructed.
    nonisolated(unsafe) static let serviceUUID = CBUUID(string: "6E400001-1A2B-4C3D-8E9F-00A1B2C3D4E5")
    nonisolated(unsafe) static let psmCharacteristicUUID = CBUUID(string: "6E400002-1A2B-4C3D-8E9F-00A1B2C3D4E5")
    nonisolated(unsafe) static let nameCharacteristicUUID = CBUUID(string: "6E400003-1A2B-4C3D-8E9F-00A1B2C3D4E5")

    let id: TransportID = .ble
    let events: AsyncStream<TransportEvent>

    var isSupported: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        queue.sync { centralState != .unsupported }
        #endif
    }

    /// start() waits for the first central state so "unsupported" surfaces as a thrown error.
    private var pendingStart: CheckedContinuation<Void, Error>?

    private struct Remote {
        var name: String?
        var psm: UInt16?
        var dialled = false
        var yielded = false   // lost the dial tie-break; the other side dials us
    }

    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let queue = DispatchQueue(label: "nearby.transport.ble")
    private let serviceName: String

    private var central: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var centralState: CBManagerState = .unknown
    private var running = false
    private var publishedPSM: CBL2CAPPSM?

    private var discovered: [UUID: CBPeripheral] = [:]
    private var remotes: [UUID: Remote] = [:]
    private var links: [LinkID: ChannelIO] = [:]
    private var readyLinks: Set<LinkID> = []

    private var channelThread: Thread?
    private var channelRunLoop: CFRunLoop?

    init(serviceName: String) {
        self.serviceName = serviceName
        (self.events, self.continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        super.init()
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard centralState != .unsupported else {
                    cont.resume(throwing: BLETransportError.bluetoothUnsupported)
                    return
                }
                running = true
                startChannelThread()

                if peripheralManager == nil {
                    peripheralManager = CBPeripheralManager(delegate: self, queue: queue)
                } else if peripheralManager?.state == .poweredOn {
                    startPublishing()
                }
                if central == nil {
                    pendingStart = cont
                    central = CBCentralManager(delegate: self, queue: queue)
                    return
                }
                if central?.state == .poweredOn { startScanning() }
                cont.resume()
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                running = false
                central?.stopScan()
                peripheralManager?.stopAdvertising()
                peripheralManager?.removeAllServices()

                for io in links.values {
                    onChannelThread { io.close() }
                }
                links.removeAll()
                readyLinks.removeAll()

                for peripheral in discovered.values {
                    central?.cancelPeripheralConnection(peripheral)
                }
                discovered.removeAll()
                remotes.removeAll()
                cont.resume()
            }
        }
    }

    func send(_ data: Data, over link: LinkID) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard let io = links[link] else {
                    cont.resume(throwing: TransportError.unknownLink(link))
                    return
                }
                guard data.count <= 0xFFFF else {
                    cont.resume(throwing: BLETransportError.frameTooLarge)
                    return
                }
                onChannelThread { io.enqueue(data) }
                cont.resume()
            }
        }
    }

    // MARK: - Channel run loop

    private func startChannelThread() {
        guard channelThread == nil else { return }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            channelRunLoop = CFRunLoopGetCurrent()
            ready.signal()
            RunLoop.current.add(Port(), forMode: .default)
            while !Thread.current.isCancelled {
                _ = RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }
        thread.name = "nearby.ble"
        channelThread = thread
        thread.start()
        ready.wait()
    }

    private func onChannelThread(_ block: @escaping () -> Void) {
        guard let runLoop = channelRunLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    // MARK: - Links

    private func adopt(_ channel: CBL2CAPChannel, endpoint: String) {
        let link = LinkID(transport: id, endpoint: endpoint)
        guard running, links[link] == nil else {
            channel.inputStream.close()
            channel.outputStream.close()
            return
        }
        let io = ChannelIO(input: channel.inputStream, output: channel.outputStream) { [weak self] event in
            guard let self else { return }
            queue.async { self.handle(event, for: link) }
        }
        links[link] = io
        onChannelThread { io.open() }
    }

    private func handle(_ event: ChannelIO.Event, for link: LinkID) {
        switch event {
        case .up:
            guard links[link] != nil, readyLinks.insert(link).inserted else { return }
            continuation.yield(.linkUp(link))
        case .frame(let payload):
            guard links[link] != nil else { return }
            continuation.yield(.received(payload, link))
        case .down:
            drop(link)
        }
    }

    private func drop(_ link: LinkID) {
        guard let io = links.removeValue(forKey: link) else { return }
        onChannelThread { io.close() }
        if readyLinks.remove(link) != nil {
            continuation.yield(.linkDown(link))
        }
    }

    // MARK: - Peripheral side

    private func startPublishing() {
        if let psm = publishedPSM {
            addService(psm: psm)
        } else {
            peripheralManager?.publishL2CAPChannel(withEncryption: false)
        }
    }

    private func addService(psm: CBL2CAPPSM) {
        var value = psm.littleEndian
        let psmData = Data(bytes: &value, count: MemoryLayout<CBL2CAPPSM>.size).prefix(2)
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [
            CBMutableCharacteristic(
                type: Self.psmCharacteristicUUID, properties: .read, value: Data(psmData), permissions: .readable),
            CBMutableCharacteristic(
                type: Self.nameCharacteristicUUID, properties: .read, value: Data(serviceName.utf8),
                permissions: .readable),
        ]
        peripheralManager?.removeAllServices()
        peripheralManager?.add(service)
    }

    // MARK: - Central side

    private func startScanning() {
        central?.scanForPeripherals(
            withServices: [Self.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func forget(_ peripheral: CBPeripheral) {
        // A yielded peripheral stays in `discovered`, or rediscovery would reconnect and cancel it in a loop.
        if remotes[peripheral.identifier]?.yielded == true { return }
        discovered[peripheral.identifier] = nil
        if let name = remotes.removeValue(forKey: peripheral.identifier)?.name {
            drop(LinkID(transport: id, endpoint: name))
        }
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLETransport: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn, running else { return }
        startPublishing()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        guard error == nil else { return }
        publishedPSM = PSM
        guard running else { return }
        addService(psm: PSM)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil, running else { return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let channel, error == nil else { return }
        adopt(channel, endpoint: "in:" + channel.peer.identifier.uuidString)
    }
}

// MARK: - CBCentralManagerDelegate

extension BLETransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        centralState = manager.state
        if let pending = pendingStart, manager.state != .unknown {
            pendingStart = nil
            if manager.state == .unsupported {
                running = false
                pending.resume(throwing: BLETransportError.bluetoothUnsupported)
                return
            }
            pending.resume()
        }
        guard manager.state == .poweredOn, running else { return }
        startScanning()
    }

    func centralManager(
        _ manager: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        guard running, discovered[peripheral.identifier] == nil else { return }
        discovered[peripheral.identifier] = peripheral
        manager.connect(peripheral)
    }

    func centralManager(_ manager: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(
        _ manager: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        forget(peripheral)
    }

    func centralManager(
        _ manager: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        forget(peripheral)
    }
}

// MARK: - CBPeripheralDelegate

extension BLETransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else { return }
        peripheral.discoverCharacteristics(
            [Self.psmCharacteristicUUID, Self.nameCharacteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            peripheral.readValue(for: characteristic)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard let value = characteristic.value else { return }
        var remote = remotes[peripheral.identifier] ?? Remote()
        switch characteristic.uuid {
        case Self.nameCharacteristicUUID:
            remote.name = String(data: value, encoding: .utf8)
        case Self.psmCharacteristicUUID where value.count >= 2:
            remote.psm =
                UInt16(value[value.startIndex]) | (UInt16(value[value.startIndex + 1]) << 8)
        default:
            break
        }
        remotes[peripheral.identifier] = remote

        guard !remote.dialled, let name = remote.name, let psm = remote.psm else { return }
        // Only the smaller name dials, so a pair opens one channel instead of two racing ones.
        guard serviceName < name else {
            remotes[peripheral.identifier]?.yielded = true
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        remotes[peripheral.identifier]?.dialled = true
        peripheral.openL2CAPChannel(psm)
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let channel, error == nil, let name = remotes[peripheral.identifier]?.name else { return }
        adopt(channel, endpoint: name)
    }
}

/// Owned entirely by the "nearby.ble" run loop thread; the transport queue reaches it only through
/// `onChannelThread`.
private final class ChannelIO: NSObject, StreamDelegate {
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

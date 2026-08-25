import Foundation
import Network
import NearbyCore
import WiFiAware

/// UDP over Wi-Fi Aware. Publishes `_nearby._udp` to all paired devices and subscribes to the same
/// service on all paired devices, so a pair that has been through the system pairing flow once
/// connects with no network at all.
///
/// All mutable state is guarded by the single `lock` below.
final class WiFiAwareTransport: Transport, @unchecked Sendable {
    static let serviceType = "_nearby._udp"

    let id: TransportID = .wifiAware
    let events: AsyncStream<TransportEvent>

    private let continuation: AsyncStream<TransportEvent>.Continuation
    /// Kept for parity with the other transports. Wi-Fi Aware advertises the service name from
    /// Info.plist, not a per-node name, so there is nothing to advertise this under.
    private let serviceName: String

    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    private var links: [LinkID: NetworkConnection<UDP>] = [:]
    private var dialling: Set<WAPairedDevice.ID> = []

    init(serviceName: String) {
        self.serviceName = serviceName
        (self.events, self.continuation) = AsyncStream.makeStream(of: TransportEvent.self)
    }

    var isSupported: Bool {
        WACapabilities.supportedFeatures.contains(.wifiAware)
            && WAPublishableService.allServices[Self.serviceType] != nil
    }

    func start() async throws {
        guard let publishable = WAPublishableService.allServices[Self.serviceType],
              let subscribable = WASubscribableService.allServices[Self.serviceType],
              WACapabilities.supportedFeatures.contains(.wifiAware) else {
            throw TransportError.notStarted
        }
        let publish = Task { [weak self] in _ = await self?.publish(publishable) }
        let subscribe = Task { [weak self] in _ = await self?.subscribe(subscribable) }
        lock.withLock { tasks += [publish, subscribe] }
    }

    func stop() async {
        let running = lock.withLock { () -> [Task<Void, Never>] in
            let running = tasks
            tasks.removeAll()
            links.removeAll()
            dialling.removeAll()
            return running
        }
        for task in running { task.cancel() }
    }

    func send(_ data: Data, over link: LinkID) async throws {
        guard let connection = lock.withLock({ links[link] }) else {
            throw TransportError.unknownLink(link)
        }
        try await connection.send(data)
    }

    // MARK: - Publish / subscribe

    private func publish(_ service: WAPublishableService) async {
        do {
            let listener = try NetworkListener(
                for: .wifiAware(.connecting(to: service, from: .allPairedDevices))
            ) { UDP() }
            try await listener.run { [weak self] connection in
                let name = connection.remoteEndpoint?.debugDescription ?? connection.id
                await self?.serve(connection, endpoint: "in:" + name)
            }
        } catch {
            // Listener died (cancelled, no entitlement, no radio). Nothing to retry against here.
        }
    }

    private func subscribe(_ service: WASubscribableService) async {
        do {
            let browser = NetworkBrowser(
                for: .wifiAware(.connecting(to: .allPairedDevices, from: service))
            )
            try await browser.run { [weak self] endpoints in
                guard let self else { return }
                for endpoint in endpoints { self.dial(endpoint) }
            }
        } catch {
            // Browser died. Same as above.
        }
    }

    private func dial(_ endpoint: WAEndpoint) {
        let device = endpoint.device.id
        guard lock.withLock({ dialling.insert(device).inserted }) else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            let connection = NetworkConnection(to: endpoint) { UDP() }
            await self.serve(connection, endpoint: String(device))
            self.lock.withLock { _ = self.dialling.remove(device) }
        }
        lock.withLock { tasks.append(task) }
    }

    // MARK: - One connection

    private func serve(_ connection: NetworkConnection<UDP>, endpoint: String) async {
        let link = LinkID(transport: id, endpoint: endpoint)
        do {
            try await waitForReady(connection)
        } catch {
            return
        }
        lock.withLock { links[link] = connection }
        continuation.yield(.linkUp(link))
        do {
            for try await message in connection.messages where !message.content.isEmpty {
                continuation.yield(.received(message.content, link))
            }
        } catch {
            // Peer went away or the task was cancelled; both mean the link is down.
        }
        lock.withLock { links[link] = nil }
        continuation.yield(.linkDown(link))
    }

    private func waitForReady(_ connection: NetworkConnection<UDP>) async throws {
        let (states, feed) = AsyncStream.makeStream(of: NetworkChannel<UDP>.State.self)
        connection.onStateUpdate { _, state in feed.yield(state) }
        if connection.state == .ready { return }
        for await state in states {
            switch state {
            case .ready: return
            case .failed(let error): throw error
            case .cancelled: throw TransportError.notStarted
            default: continue
            }
        }
        throw TransportError.notStarted
    }
}

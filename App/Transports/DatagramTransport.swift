import Foundation
import Network
import NearbyCore

enum TransportError: Error {
    case unknownLink(LinkID)
    case notStarted
}

/// UDP over Bonjour. peerToPeer=false is the LAN transport; peerToPeer=true is Apple peer-to-peer Wi-Fi. Same code, one flag.
final class DatagramTransport: Transport, @unchecked Sendable {
    static let serviceType = "_nearby._udp"

    let id: TransportID
    let isSupported: Bool = true
    let events: AsyncStream<TransportEvent>

    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let queue: DispatchQueue
    private let peerToPeer: Bool
    private let serviceName: String
    private let params: NWParameters

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var links: [LinkID: NWConnection] = [:]
    private var readyLinks: Set<LinkID> = []

    init(id: TransportID, peerToPeer: Bool, serviceName: String) {
        self.id = id
        self.peerToPeer = peerToPeer
        self.serviceName = serviceName
        self.queue = DispatchQueue(label: "nearby.transport.\(id)")
        let params = NWParameters.udp
        params.includePeerToPeer = peerToPeer
        self.params = params
        (self.events, self.continuation) = AsyncStream.makeStream(of: TransportEvent.self)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    let listener = try NWListener(using: params)
                    listener.service = NWListener.Service(name: serviceName, type: Self.serviceType)
                    listener.newConnectionHandler = { [weak self] connection in
                        guard let self else { return }
                        self.adopt(connection, endpoint: "in:" + connection.endpoint.debugDescription)
                    }
                    self.listener = listener

                    let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: params)
                    browser.browseResultsChangedHandler = { [weak self] results, changes in
                        guard let self else { return }
                        self.handleBrowseChanges(changes)
                    }
                    self.browser = browser

                    listener.start(queue: queue)
                    browser.start(queue: queue)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func handleBrowseChanges(_ changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            switch change {
            case .added(let result):
                // Bonjour renames a stale re-registration of our own service to "<name> (2)"; never dial ourselves.
                guard case .service(let name, _, _, _) = result.endpoint, !name.hasPrefix(serviceName) else { continue }
                // Only the lexicographically smaller name dials, so each pair opens one connection instead of two.
                guard serviceName < name else { continue }
                let connection = NWConnection(to: result.endpoint, using: params)
                adopt(connection, endpoint: name)
            case .removed(let result):
                guard case .service(let name, _, _, _) = result.endpoint else { continue }
                let link = LinkID(transport: id, endpoint: name)
                links[link]?.cancel()
            default:
                break
            }
        }
    }

    private func adopt(_ connection: NWConnection, endpoint: String) {
        let link = LinkID(transport: id, endpoint: endpoint)
        guard links[link] == nil else {
            connection.cancel()
            return
        }
        links[link] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                self.handleState(state, for: link, connection: connection)
            }
        }
        connection.start(queue: queue)
    }

    private func handleState(_ state: NWConnection.State, for link: LinkID, connection: NWConnection) {
        switch state {
        case .ready:
            readyLinks.insert(link)
            continuation.yield(.linkUp(link))
            receive(on: connection, link: link)
        case .failed, .cancelled:
            links[link] = nil
            if readyLinks.remove(link) != nil {
                continuation.yield(.linkDown(link))
            }
        default:
            break
        }
    }

    private func receive(on connection: NWConnection, link: LinkID) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            self.queue.async {
                if let content, !content.isEmpty {
                    self.continuation.yield(.received(content, link))
                }
                if error == nil, connection.state != .cancelled {
                    self.receive(on: connection, link: link)
                } else if error != nil {
                    connection.cancel()
                }
            }
        }
    }

    func send(_ data: Data, over link: LinkID) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard let connection = links[link] else {
                    cont.resume(throwing: TransportError.unknownLink(link))
                    return
                }
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                })
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                browser?.cancel()
                browser = nil
                listener?.cancel()
                listener = nil
                for (_, connection) in links {
                    connection.cancel()
                }
                links.removeAll()
                readyLinks.removeAll()
                cont.resume()
            }
        }
    }
}

import Foundation
import NearbyCore
import os

struct TURNCredentials {
    let server: (host: String, port: UInt16)
    let username: String
    let password: String
    let ttl: TimeInterval
}

enum TURNError: Error {
    case unreachable
    case rejected(code: Int, reason: String)
    case badAllocation
}

/// A TURN client (RFC 8656) on a UDP socket of its own, bound for the life of the allocation.
/// Every method runs on the transport queue.
final class TURNClient: @unchecked Sendable {
    var onRelayed: ((_ relayed: (host: String, port: UInt16)) -> Void)?
    var onData: ((_ payload: Data, _ peerHost: String, _ peerPort: UInt16) -> Void)?
    var onFailure: ((Error) -> Void)?

    private struct Pending {
        let method: STUNMessage.Method
        let build: (Data) -> [STUNMessage.Attribute]
        let signed: Bool
        let retried: Bool
        let onSuccess: (STUNMessage) -> Void
        var attempt = 0
    }

    private struct Channel {
        let number: UInt16
        var bound: Bool
        let host: String
        let port: UInt16
    }

    private static let lifetime: UInt32 = 600
    private static let permissionInterval: TimeInterval = 240
    private static let maxAttempts = 7

    let credentials: TURNCredentials
    /// The address the relay hands out for this allocation; nil until it does.
    private(set) var relayedAddress: (host: String, port: UInt16)?

    /// Each allocation needs a 5-tuple of its own: RFC 8656 §6.2 answers a second Allocate on one
    /// already in use with 437, so a renewed allocation cannot share the transport's socket.
    private let socket: UDPSocket
    private let queue: DispatchQueue
    private let logger = Logger(subsystem: "com.arsenstorm.nearby", category: "turn")

    /// UDPSocket only sends to numeric literals, so the server name is resolved once up front.
    // Prefer IPv4: the v6 record answers nothing from some networks, and a relayed peer is v4 anyway.
    private lazy var serverAddress: String = {
        let addresses = NATProbe.addresses(credentials.server.host)
        return addresses.first { !$0.contains(":") } ?? addresses.first ?? credentials.server.host
    }()
    private var realm: String?
    private var nonce: Data?
    private var pending: [Data: Pending] = [:]
    private var permitted: Set<String> = []
    private var channels: [String: Channel] = [:]
    private var nextChannel: UInt16 = 0x4000
    private var closed = false

    init(credentials: TURNCredentials, queue: DispatchQueue) throws {
        self.credentials = credentials
        self.queue = queue
        socket = try UDPSocket(port: .random(in: 20000...60000), queue: queue)
        socket.onReceive = { [weak self] data, host, port in self?.handle(data, from: host, port: port) }
    }

    // MARK: - Allocation

    func allocate() {
        logger.debug("allocating at \(self.serverAddress, privacy: .public):\(self.credentials.server.port) (\(self.credentials.server.host, privacy: .public))")
        // REQUESTED-TRANSPORT carries the IANA protocol number; 17 is UDP (RFC 8656 §14.7).
        request(.allocate, signed: false) { _ in
            [.init(type: STUNAttribute.requestedTransport, value: Data([17, 0, 0, 0])),
             .init(type: STUNAttribute.lifetime, value: STUNMessage.uint32(Self.lifetime))]
        } onSuccess: { [weak self] response in
            self?.allocated(response)
        }
    }

    private func allocated(_ response: STUNMessage) {
        guard let value = response.attribute(STUNAttribute.xorRelayedAddress),
              let relayed = STUNMessage.xorAddress(value, transactionID: response.transactionID)
        else { return fail(TURNError.badAllocation) }
        logger.notice("relay \(relayed.host, privacy: .public):\(relayed.port)")
        relayedAddress = relayed
        scheduleRefresh()
        onRelayed?(relayed)
    }

    func refresh() {
        request(.refresh) { _ in
            [.init(type: STUNAttribute.lifetime, value: STUNMessage.uint32(Self.lifetime))]
        } onSuccess: { [weak self] _ in
            self?.scheduleRefresh()
        }
    }

    private func scheduleRefresh() {
        queue.asyncAfter(deadline: .now() + credentials.ttl / 2) { [weak self] in
            guard let self, !closed else { return }
            refresh()
        }
    }

    func close() {
        guard !closed else { return }
        request(.refresh) { _ in
            [.init(type: STUNAttribute.lifetime, value: STUNMessage.uint32(0))]
        } onSuccess: { _ in }
        closed = true
        pending.removeAll()
        permitted.removeAll()
        channels.removeAll()
        socket.shutdown()
    }

    // MARK: - Peers

    func permit(host: String) {
        guard !permitted.contains(host) else { return }
        permitted.insert(host)
        createPermission(host)
    }

    /// Permissions expire after five minutes (RFC 8656 §9), so they are reinstalled well inside that.
    private func createPermission(_ host: String) {
        guard !closed, permitted.contains(host) else { return }
        request(.createPermission) { id in
            STUNMessage.xorAddressAttribute(host: host, port: 0, transactionID: id)
                .map { [STUNMessage.Attribute(type: STUNAttribute.xorPeerAddress, value: $0)] } ?? []
        } onSuccess: { [weak self] _ in
            self?.queue.asyncAfter(deadline: .now() + Self.permissionInterval) { [weak self] in
                self?.createPermission(host)
            }
        }
    }

    func send(_ payload: Data, to host: String, port: UInt16) {
        let key = "\(host):\(port)"
        if let channel = channels[key], channel.bound {
            return transmit(ChannelData.encode(channel: channel.number, payload: payload))
        }
        if channels[key] == nil { bindChannel(key: key, host: host, port: port) }
        sendIndication(payload, host: host, port: port)
    }

    /// A bound channel replaces the 36-byte Send indication header with 4 bytes (RFC 8656 §12).
    private func bindChannel(key: String, host: String, port: UInt16) {
        let number = nextChannel
        nextChannel = number >= 0x7FFE ? 0x4000 : number + 1
        channels[key] = Channel(number: number, bound: false, host: host, port: port)
        request(.channelBind) { id in
            guard let peer = STUNMessage.xorAddressAttribute(host: host, port: port, transactionID: id) else { return [] }
            return [.init(type: STUNAttribute.channelNumber, value: Data([UInt8(number >> 8), UInt8(number & 0xFF), 0, 0])),
                    .init(type: STUNAttribute.xorPeerAddress, value: peer)]
        } onSuccess: { [weak self] _ in
            self?.channels[key]?.bound = true
        }
    }

    private func sendIndication(_ payload: Data, host: String, port: UInt16) {
        let id = STUNMessage.newTransactionID()
        guard let peer = STUNMessage.xorAddressAttribute(host: host, port: port, transactionID: id) else { return }
        // Indications are never authenticated (RFC 8656 §10.1).
        let message = STUNMessage(method: .send, cls: .indication, transactionID: id,
                                  attributes: [.init(type: STUNAttribute.xorPeerAddress, value: peer),
                                               .init(type: STUNAttribute.data, value: payload)])
        transmit(message.encode())
    }

    // MARK: - Transactions

    private func request(_ method: STUNMessage.Method, signed: Bool = true, retried: Bool = false,
                         build: @escaping (Data) -> [STUNMessage.Attribute],
                         onSuccess: @escaping (STUNMessage) -> Void) {
        guard !closed else { return }
        let id = STUNMessage.newTransactionID()
        pending[id] = Pending(method: method, build: build, signed: signed, retried: retried, onSuccess: onSuccess)
        retransmit(id)
    }

    /// RFC 8489 §6.2.1: RTO of 500 ms, doubling, seven sends before the transaction is lost.
    private func retransmit(_ id: Data) {
        guard var state = pending[id] else { return }
        guard state.attempt < Self.maxAttempts else {
            pending[id] = nil
            logger.error("turn \(String(describing: state.method), privacy: .public) unanswered after \(state.attempt) sends to \(self.serverAddress, privacy: .public)")
            return fail(TURNError.unreachable)
        }
        let attributes = state.build(id)
        guard !attributes.isEmpty else {
            pending[id] = nil
            return logger.error("turn request with no attributes, peer address is not a literal")
        }
        state.attempt += 1
        pending[id] = state
        transmit(encode(state.method, id: id, attributes: attributes, signed: state.signed))
        queue.asyncAfter(deadline: .now() + 0.5 * pow(2, Double(state.attempt - 1))) { [weak self] in
            self?.retransmit(id)
        }
    }

    private func encode(_ method: STUNMessage.Method, id: Data, attributes: [STUNMessage.Attribute], signed: Bool) -> Data {
        guard signed, let realm, let nonce else {
            return STUNMessage(method: method, cls: .request, transactionID: id, attributes: attributes).encode()
        }
        var list = attributes
        list.append(.init(type: STUNAttribute.username, value: Data(credentials.username.utf8)))
        list.append(.init(type: STUNAttribute.realm, value: Data(realm.utf8)))
        list.append(.init(type: STUNAttribute.nonce, value: nonce))
        return STUNMessage(method: method, cls: .request, transactionID: id, attributes: list)
            .signed(username: credentials.username, realm: realm, password: credentials.password)
    }

    private func complete(_ message: STUNMessage) {
        guard let state = pending.removeValue(forKey: message.transactionID) else { return }
        guard message.cls == .error else { return state.onSuccess(message) }
        let error = message.attribute(STUNAttribute.errorCode).flatMap(STUNMessage.errorCode) ?? (code: 0, reason: "")
        // 401 hands out the realm and nonce to sign with; 438 replaces a stale one (RFC 8489 §9.2.5).
        guard error.code == 401 || error.code == 438, !state.retried, adoptCredentials(message) else {
            // A refused permission or channel loses one peer path; only the allocation itself is fatal.
            guard state.method == .allocate || state.method == .refresh else {
                return logger.error("turn \(String(describing: state.method), privacy: .public) refused: \(error.code) \(error.reason, privacy: .public)")
            }
            return fail(TURNError.rejected(code: error.code, reason: error.reason))
        }
        request(state.method, signed: true, retried: true, build: state.build, onSuccess: state.onSuccess)
    }

    private func adoptCredentials(_ message: STUNMessage) -> Bool {
        guard let realmValue = message.attribute(STUNAttribute.realm),
              let nonceValue = message.attribute(STUNAttribute.nonce)
        else { return false }
        realm = String(decoding: realmValue, as: UTF8.self)
        nonce = nonceValue
        return true
    }

    private func fail(_ error: Error) {
        logger.error("turn: \(String(describing: error), privacy: .public)")
        onFailure?(error)
    }

    private func transmit(_ data: Data) {
        socket.send(data, to: serverAddress, port: credentials.server.port)
    }

    // MARK: - Inbound

    /// Nothing but the relay server has this socket's address, so anything else is junk.
    private func handle(_ datagram: Data, from host: String, port: UInt16) {
        guard host == serverAddress, port == credentials.server.port else {
            return logger.debug("ignored \(datagram.count) bytes from \(host, privacy: .public):\(port), server is \(self.serverAddress, privacy: .public)")
        }
        if let framed = ChannelData.decode(datagram) {
            guard let channel = channels.values.first(where: { $0.number == framed.channel }) else { return }
            return onData?(framed.payload, channel.host, channel.port) ?? ()
        }
        guard let message = STUNMessage(decoding: datagram) else { return }
        if message.cls == .indication { deliver(message) } else { complete(message) }
    }

    private func deliver(_ indication: STUNMessage) {
        guard indication.method == .data,
              let payload = indication.attribute(STUNAttribute.data),
              let value = indication.attribute(STUNAttribute.xorPeerAddress),
              let peer = STUNMessage.xorAddress(value, transactionID: indication.transactionID)
        else { return }
        onData?(payload, peer.host, peer.port)
    }
}

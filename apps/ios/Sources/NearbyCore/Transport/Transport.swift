import Foundation

public enum TransportID: String, Sendable, Codable, CaseIterable {
    case lan, p2pWiFi, ble, wifiAware, internet
}

/// One transport-level path to one neighbour. A neighbour on two transports has two links.
public struct LinkID: Hashable, Sendable, CustomStringConvertible {
    public let transport: TransportID
    public let endpoint: String

    public init(transport: TransportID, endpoint: String) { self.transport = transport; self.endpoint = endpoint }

    public var description: String { "\(transport.rawValue):\(endpoint)" }
}

public enum TransportEvent: Sendable {
    case linkUp(LinkID)
    case linkDown(LinkID)
    case received(Data, LinkID)
}

public protocol Transport: AnyObject, Sendable {
    var id: TransportID { get }
    var isSupported: Bool { get }
    var events: AsyncStream<TransportEvent> { get }
    func start() async throws
    func stop() async
    func send(_ data: Data, over link: LinkID) async throws
}

import Foundation

/// What a QR code or shared link carries: the full signing key, because the 64-bit NodeID is only a
/// wire address and too short to pin an identity against a targeted collision. The name is a label
/// until the first signed Hello replaces it.
public struct PeerCard: Equatable, Sendable {
    public static let scheme = "nearby"

    public let signingPublicKey: Data
    public let name: String

    public init(signingPublicKey: Data, name: String) {
        self.signingPublicKey = signingPublicKey
        self.name = name
    }

    public init(identity: Identity, name: String) {
        self.init(signingPublicKey: identity.signingPublicKey, name: name)
    }

    public var nodeID: NodeID { NodeID(publicKey: signingPublicKey) }

    /// nearby://<base64url key>?name=<label>
    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.base64url(signingPublicKey)
        if !name.isEmpty { components.queryItems = [URLQueryItem(name: "name", value: name)] }
        return components.url!
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, let key = Self.unbase64url(host), key.count == 32
        else { return nil }
        self.signingPublicKey = key
        self.name = components.queryItems?.first { $0.name == "name" }?.value ?? ""
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func unbase64url(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

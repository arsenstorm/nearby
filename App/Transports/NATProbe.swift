import Foundation

enum CandidateKind: String, Codable { case v6, host, srflx, relay }

struct Candidate: Codable, Hashable {
    let kind: CandidateKind
    let host: String
    let port: UInt16

    var text: String { "\(kind.rawValue):\(host):\(port)" }

    init(kind: CandidateKind, host: String, port: UInt16) {
        self.kind = kind
        self.host = host
        self.port = port
    }

    init?(text: String) {
        // A v6 literal is full of colons, so the port is whatever follows the last one.
        guard let portMark = text.lastIndex(of: ":"),
              let port = UInt16(text[text.index(after: portMark)...])
        else { return nil }
        let head = text[..<portMark]
        guard let kindMark = head.firstIndex(of: ":"),
              let kind = CandidateKind(rawValue: String(head[..<kindMark]))
        else { return nil }
        self.kind = kind
        self.host = String(head[head.index(after: kindMark)...])
        self.port = port
        if host.isEmpty { return nil }
    }
}

enum NATProbeError: Error {
    case stunTimeout
    case stunBadResponse
}

/// Gathers candidates on a socket the transport owns, so the peer punches the same NAT mapping STUN reported.
final class NATProbe: @unchecked Sendable {
    var localPort: UInt16 { socket.port }

    private static let stunServers: [(host: String, port: UInt16)] = [("stun.cloudflare.com", 3478), ("stun.l.google.com", 19302)]
    private static let cookie = Data([0x21, 0x12, 0xA4, 0x42])

    private let queue = DispatchQueue(label: "nearby.natprobe")
    private let socket: UDPSocket
    private var stunWaiters: [Data: (Data) -> Void] = [:]

    init(socket: UDPSocket) {
        self.socket = socket
    }

    /// STUN responses start with 0x01 and carry the transaction id at bytes 8..<20; anything else is the caller's.
    func handleDatagram(_ data: Data) -> Bool {
        guard data.count >= 20, data[data.startIndex] == 0x01 else { return false }
        let txid = data.subdata(in: 8..<20)
        guard let waiter = queue.sync(execute: { stunWaiters.removeValue(forKey: txid) }) else { return false }
        waiter(data)
        return true
    }

    // MARK: - Candidates

    func gatherCandidates() async throws -> [Candidate] {
        let local = hostAddresses()
        var out = local.filter { $0.kind == .v6 } + local.filter { $0.kind == .host }
        out.append(try await stunQuery(v6: false, server: Self.stunServers[0]))
        // A second server answering with a different port means the NAT maps per destination (symmetric):
        // the peer cannot reach the port the first server saw.
        if let second = try? await stunQuery(v6: false, server: Self.stunServers[1]) { out.append(second) }
        // No global v6 address means no v6 socket to map; a v6 STUN failure is not fatal either.
        if local.contains(where: { $0.kind == .v6 }), let srflx = try? await stunQuery(v6: true, server: Self.stunServers[0]) {
            out.append(srflx)
        }
        return out
    }

    func hostAddresses() -> [Candidate] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [Candidate] = []
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let addr = ifa.pointee.ifa_addr,
                  let candidate = candidate(from: addr), !out.contains(candidate)
            else { continue }
            out.append(candidate)
        }
        return out
    }

    /// Every address on every interface, unfiltered, for the gather log: shows why a candidate is missing.
    func interfaceDump() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        return sequence(first: first, next: { $0.pointee.ifa_next }).compactMap { ifa in
            guard let addr = ifa.pointee.ifa_addr, let host = Self.numericHost(addr) else { return nil }
            let up = Int32(ifa.pointee.ifa_flags) & IFF_UP != 0 ? "up" : "down"
            return "\(String(cString: ifa.pointee.ifa_name)) \(up) \(host)"
        }
    }

    private static func numericHost(_ addr: UnsafeMutablePointer<sockaddr>) -> String? {
        let family = Int32(addr.pointee.sa_family)
        guard family == AF_INET || family == AF_INET6 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0
        else { return nil }
        return String(cString: buffer)
    }

    private func candidate(from addr: UnsafeMutablePointer<sockaddr>) -> Candidate? {
        guard let scoped = Self.numericHost(addr) else { return nil }
        // getnameinfo appends "%en0" to scoped addresses; the peer cannot use our scope id.
        let host = String(scoped.split(separator: "%").first ?? "")
        guard !host.isEmpty else { return nil }
        // 169.254/16 is link-local: it only reaches a directly attached peer, which is not what this probe measures.
        if Int32(addr.pointee.sa_family) == AF_INET {
            return host.hasPrefix("169.254.") ? nil : Candidate(kind: .host, host: host, port: localPort)
        }
        // Link-local and unique-local v6 never route past the peer's edge.
        guard !host.hasPrefix("fe80"), !host.hasPrefix("fd"), !host.hasPrefix("fc"), host != "::1" else { return nil }
        return Candidate(kind: .v6, host: host, port: localPort)
    }
    // MARK: - STUN

    private func stunQuery(v6: Bool, server: (host: String, port: UInt16)) async throws -> Candidate {
        guard let address = Self.addresses(server.host).first(where: { $0.contains(":") == v6 }) else {
            throw NATProbeError.stunTimeout
        }
        let request = stunRequest()
        let txid = request.subdata(in: 8..<20)
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.stunWaiters[txid] = { response in
                    guard let mapped = Self.parseStunResponse(response, txid: txid) else {
                        return cont.resume(throwing: NATProbeError.stunBadResponse)
                    }
                    cont.resume(returning: Candidate(kind: .srflx, host: mapped.0, port: mapped.1))
                }
                self.socket.send(request, to: address, port: server.port)
                self.queue.asyncAfter(deadline: .now() + 2) {
                    guard self.stunWaiters.removeValue(forKey: txid) != nil else { return }
                    cont.resume(throwing: NATProbeError.stunTimeout)
                }
            }
        }
    }

    static func addresses(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(result) }
        return sequence(first: first, next: { $0.pointee.ai_next }).compactMap { numericHost($0.pointee.ai_addr) }
    }

    /// RFC 5389 Binding Request: type, zero length, magic cookie, 12-byte transaction id.
    private func stunRequest() -> Data {
        var data = Data([0x00, 0x01, 0x00, 0x00])
        data.append(Self.cookie)
        data.append(contentsOf: (0..<12).map { _ in UInt8.random(in: .min ... .max) })
        return data
    }

    private static func parseStunResponse(_ response: Data, txid: Data) -> (String, UInt16)? {
        let data = Data(response)
        // Binding Success is 0x0101; the transaction id sits at bytes 8..<20 of the 20-byte header.
        guard data.count >= 20, be16(data, 0) == 0x0101, data.subdata(in: 8..<20) == txid else { return nil }
        var offset = 20
        var fallback: (String, UInt16)?
        while offset + 4 <= data.count {
            let type = be16(data, offset)
            let length = Int(be16(data, offset + 2))
            let value = offset + 4
            guard value + length <= data.count else { break }
            let body = data.subdata(in: value..<(value + length))
            if type == 0x0020, let mapped = address(body, xorWith: cookie + txid) { return mapped }
            if type == 0x0001, fallback == nil { fallback = address(body, xorWith: nil) }
            // Attribute values are padded out to a 4-byte boundary.
            offset = value + (length + 3) / 4 * 4
        }
        return fallback
    }

    /// Attribute value: reserved byte, family, port, then 4 (v4) or 16 (v6) address bytes.
    private static func address(_ attribute: Data, xorWith mask: Data?) -> (String, UInt16)? {
        let value = Data(attribute)
        guard value.count >= 8, value[1] == 0x01 || value[1] == 0x02 else { return nil }
        let size = value[1] == 0x02 ? 16 : 4
        guard value.count >= 4 + size else { return nil }
        var port = be16(value, 2)
        var bytes = [UInt8](value[4..<(4 + size)])
        if let mask {
            port ^= 0x2112
            for i in 0..<size { bytes[i] ^= mask[mask.startIndex + i] }
        }
        return (literal(bytes, v6: size == 16), port)
    }

    private static func be16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private static func literal(_ bytes: [UInt8], v6: Bool) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        _ = bytes.withUnsafeBufferPointer {
            inet_ntop(v6 ? AF_INET6 : AF_INET, $0.baseAddress, &buffer, socklen_t(buffer.count))
        }
        return String(cString: buffer)
    }
}

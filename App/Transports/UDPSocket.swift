import Foundation

/// One unconnected dual-stack UDP socket. Network.framework refuses a second NWConnection on a shared
/// local port (EADDRINUSE), but hole punching needs every probe and the STUN query to leave from one port.
final class UDPSocket {
    let port: UInt16
    var onReceive: ((Data, String, UInt16) -> Void)?

    private let fd: Int32
    private let source: DispatchSourceRead

    init(port: UInt16, queue: DispatchQueue) throws {
        let fd = socket(AF_INET6, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var off: Int32 = 0
        var on: Int32 = 1
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_any
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard bound == 0 else {
            let error = errno
            close(fd)
            throw POSIXError(.init(rawValue: error) ?? .EIO)
        }
        self.fd = fd
        self.port = port
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.resume()
    }

    deinit { shutdown() }

    func shutdown() {
        guard !source.isCancelled else { return }
        source.setCancelHandler { [fd] in close(fd) }
        source.cancel()
    }

    func send(_ data: Data, to host: String, port: UInt16) {
        guard let addr = Self.resolve(host, port: port) else { return }
        var storage = addr
        _ = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var from = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let count = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
        }
        guard count > 0, let (host, port) = Self.endpoint(of: from) else { return }
        onReceive?(Data(buffer.prefix(count)), host, port)
    }

    /// v4 literals become v4-mapped v6 addresses so one socket reaches both families.
    private static func resolve(_ host: String, port: UInt16) -> sockaddr_in6? {
        var hints = addrinfo()
        hints.ai_family = AF_INET6
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_flags = AI_NUMERICHOST | AI_V4MAPPED
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }
        return info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
    }

    private static func endpoint(of addr: sockaddr_in6) -> (String, UInt16)? {
        var copy = addr
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let ok = withUnsafePointer(to: &copy) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in6>.size), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
            }
        }
        guard ok == 0 else { return nil }
        var host = String(cString: buffer)
        if host.hasPrefix("::ffff:") { host.removeFirst(7) }
        return (host, UInt16(bigEndian: addr.sin6_port))
    }
}

import Foundation

// Mac endpoint for the NAT probe: the iOS Simulator ignores requiredLocalEndpoint, so it cannot stand in for a phone.
// Build: swiftc -O App/Transports/NATProbe.swift App/Transports/UDPSocket.swift scripts/natprobe/main.swift -o build/natprobe
// Run:   NATPROBE_PORT=40404 build/natprobe → prints this side's candidates and a NAT mapping verdict

let queue = DispatchQueue(label: "nearby.natprobe.cli")
let port = ProcessInfo.processInfo.environment["NATPROBE_PORT"].flatMap(UInt16.init) ?? .random(in: 20000...60000)
let udp = try! UDPSocket(port: port, queue: queue)
let probe = NATProbe(socket: udp)
udp.onReceive = { data, _, _ in _ = probe.handleDatagram(data) }

for line in probe.interfaceDump() { print("if \(line)") }
let semaphore = DispatchSemaphore(value: 0)
Task {
    do {
        let local = try await probe.gatherCandidates()
        print("\nLOCAL (send this to the phone):\n\(local.map(\.text).joined(separator: ","))\n")
        let report = await probe.classifyMapping()
        for m in report.mappings { print("reflector \(m.server) → \(m.host):\(m.port)") }
        print("NAT: \(report.verdict)")
    } catch {
        print("gather failed: \(error)")
    }
    semaphore.signal()
}
semaphore.wait()

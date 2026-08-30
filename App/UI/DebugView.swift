import NearbyCore
import SwiftUI

struct DebugView: View {
    @Environment(NearbyNode.self) private var node
    @AppStorage(InternetTransport.relayOnlyKey) private var relayOnly = false

    var body: some View {
        @Bindable var node = node
        Form {
            Section("Transports") {
                ForEach(TransportID.allCases, id: \.self) { id in
                    let state = node.transportStates[id]
                    VStack(alignment: .leading) {
                        Toggle(
                            id.rawValue,
                            isOn: Binding(
                                get: { node.transportStates[id]?.enabled ?? false },
                                set: { node.setTransport(id, enabled: $0) }
                            )
                        )
                        .disabled(state?.supported == false)
                        Text(detail(state))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("internet: relay only", isOn: $relayOnly)
                LabeledContent("Relay", value: relayLine)
                if let error = node.relayError {
                    LabeledContent("Last relay error", value: error).font(.footnote)
                }
                NavigationLink("Wi-Fi Aware pairing") { WiFiAwarePairingView() }
            }

            Section("Peers") {
                ForEach(node.peers) { peer in
                    VStack(alignment: .leading) {
                        Text(peer.name)
                        Text(peer.id.description).monospaced()
                        if let path = node.pathInfo[peer.id] {
                            Text(pathLine(path))
                        }
                        ForEach(peer.links, id: \.self) { link in
                            Text(link.description).monospaced()
                        }
                        Text(peer.lastSeen, style: .relative)
                    }
                    .font(.footnote)
                }
            }

            Section("Tuning") {
                Stepper(
                    "Jitter depth: \(node.jitterTargetDepth) frames (\(node.jitterTargetDepth * Opus.frameMs) ms)",
                    value: $node.jitterTargetDepth,
                    in: 1...25
                )
                Stepper(
                    "Internet jitter: \(node.internetJitterTargetDepth) × \(Opus.internetFrameMs) ms",
                    value: $node.internetJitterTargetDepth,
                    in: 1...10
                )
                VStack(alignment: .leading) {
                    Text("Multipath when loss > \(Int(node.multipathLossThreshold * 100))%")
                    Slider(value: $node.multipathLossThreshold, in: 0...0.5, step: 0.01)
                }
            }

            Section("Latency") {
                Text("Mouth to ear (estimate): \(Int(mouthToEarMs)) ms")
                Text("I/O \(Int(node.ioLatencyMs)) ms")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Voice \(node.inCall ? "on" : "off")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Packets") {
                LabeledContent("sent", value: "\(node.packetCounters.sent)")
                LabeledContent("received", value: "\(node.packetCounters.received)")
                LabeledContent("relayed", value: "\(node.packetCounters.relayed)")
                LabeledContent("dropped (dedup)", value: "\(node.packetCounters.droppedDedup)")
                LabeledContent("dropped (TTL)", value: "\(node.packetCounters.droppedTTL)")
            }

            Section("Node") {
                Text(node.nodeID.description).monospaced()
                Text(node.displayName)
            }
        }
        .navigationTitle("Debug")
    }

    private var relayLine: String {
        let entitlement = switch node.relayEntitlement {
        case .freeDirectOnly: "Free (direct only)"
        case .subscriber: "Subscriber"
        case .beta: "Beta build"
        }
        return "\(entitlement) · \(node.attestState)"
    }

    private var mouthToEarMs: Double {
        let path = node.voiceStats.keys.compactMap { node.pathInfo[$0]?.costMs }.min() ?? 0
        return path + Double((node.jitterTargetDepth + 1) * Opus.frameMs) + node.ioLatencyMs
    }

    private func pathLine(_ path: PathInfo) -> String {
        let via = path.nextLink?.transport.rawValue ?? "—"
        return "\(path.hops) hop(s) via \(via) · \(Int(path.latencyMs)) ms · loss \(Int(path.lossFraction * 100))% · jitter \(Int(path.jitterMs)) ms"
    }

    private func detail(_ state: TransportState?) -> String {
        guard let state, state.supported else { return "unsupported on this device" }
        return "\(state.active ? "active" : "inactive") · \(state.linkCount) links"
    }
}

import NearbyCore
import SwiftUI

struct DebugView: View {
    @Environment(NearbyNode.self) private var node

    var body: some View {
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
            }

            Section("Peers") {
                ForEach(node.peers) { peer in
                    VStack(alignment: .leading) {
                        Text(peer.name)
                        Text(peer.id.description).monospaced()
                        Text(peer.lastSeen, style: .relative)
                        ForEach(peer.links, id: \.self) { link in
                            Text(link.description)
                        }
                    }
                    .font(.footnote)
                }
            }

            Section("Node") {
                Text(node.nodeID.description).monospaced()
                Text(node.displayName)
            }
        }
        .navigationTitle("Debug")
    }

    private func detail(_ state: TransportState?) -> String {
        guard let state, state.supported else { return "unsupported on this device" }
        return "\(state.active ? "active" : "inactive") · \(state.linkCount) links"
    }
}

import NearbyCore
import SwiftUI

struct RoomView: View {
    @Environment(NearbyNode.self) private var node

    var body: some View {
        @Bindable var node = node

        List {
            if let hosted = node.hosted {
                if !hosted.pending.isEmpty {
                    Section("Requests") {
                        ForEach(hosted.pending, id: \.id) { member in
                            HStack {
                                Text(member.name)
                                Spacer()
                                Button("Accept") { node.accept(member.id) }
                                Button("Decline", role: .destructive) { node.reject(member.id) }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                callSection

                membersSection(hosted.members)

                Section {
                    Button("Close room", role: .destructive) { node.closeRoom() }
                }
            } else if let joined = node.joined {
                callSection

                membersSection(joined.members)

                Section {
                    Button("Leave room", role: .destructive) { node.leaveRoom() }
                }
            }
        }
        .navigationTitle(node.hosted?.name ?? node.joined?.name ?? "Room")
    }

    private var callSection: some View {
        @Bindable var node = node

        return Section("Call") {
            Toggle("Mute", isOn: $node.muted)
            Text(node.inCall ? "Voice on · I/O \(Int(node.ioLatencyMs)) ms" : "Voice off")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func membersSection(_ members: [Member]) -> some View {
        Section("Members") {
            ForEach(members, id: \.id) { member in
                VStack(alignment: .leading) {
                    Text(member.id == node.nodeID ? "\(member.name) (you)" : member.name)
                    if member.id != node.nodeID, let stats = node.voiceStats[member.id] {
                        Text("played \(stats.played) · missing \(stats.missing) · late \(stats.late)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

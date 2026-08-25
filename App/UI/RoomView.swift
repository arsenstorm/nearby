import NearbyCore
import SwiftUI

struct RoomView: View {
    @Environment(NearbyNode.self) private var node

    var body: some View {
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

                membersSection(hosted.members)

                Section {
                    Button("Close room", role: .destructive) { node.closeRoom() }
                } footer: {
                    Text("Voice arrives in the next build.")
                }
            } else if let joined = node.joined {
                membersSection(joined.members)

                Section {
                    Button("Leave room", role: .destructive) { node.leaveRoom() }
                } footer: {
                    Text("Voice arrives in the next build.")
                }
            }
        }
        .navigationTitle(node.hosted?.name ?? node.joined?.name ?? "Room")
    }

    private func membersSection(_ members: [Member]) -> some View {
        Section("Members") {
            ForEach(members, id: \.id) { member in
                Text(member.id == node.nodeID ? "\(member.name) (you)" : member.name)
            }
        }
    }
}

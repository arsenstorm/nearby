import NearbyCore
import SwiftUI

struct FriendsView: View {
    @Environment(NearbyNode.self) private var node
    @State private var forgetting: PeerRecord?

    private var friends: [PeerRecord] {
        node.peerStore.records.values
            .filter { !node.blocked.contains($0.id) }
            .sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }

    private var blocked: [NodeID] {
        node.blocked.sorted { $0.description < $1.description }
    }

    var body: some View {
        Form {
            Section("Friends") {
                if friends.isEmpty {
                    ContentUnavailableView(
                        "No friends yet",
                        systemImage: "person.crop.circle.badge.plus",
                        description: Text("Scan a friend's card to add them.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(friends, id: \.id) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            name(record)
                            if node.peers.contains(where: { $0.id == record.id }) {
                                Text("Online")
                                    .font(.footnote)
                                    .foregroundStyle(.green)
                            } else {
                                Text(record.id.description)
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button { node.block(record.id) } label: {
                                Label("Block", systemImage: "hand.raised")
                            }
                            .tint(.orange)
                            Button(role: .destructive) { forgetting = record } label: {
                                Label("Forget", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            if !blocked.isEmpty {
                Section("Blocked") {
                    ForEach(blocked, id: \.self) { id in
                        HStack {
                            blockedName(id)
                            Spacer()
                            Button("Unblock") { node.unblock(id) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .navigationTitle("Friends")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            forgetting.map { "Forget \(title(for: $0))?" } ?? "",
            // Dismissal clears the record; the setter must not fight the buttons.
            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
            titleVisibility: .visible,
            presenting: forgetting
        ) { record in
            Button("Forget", role: .destructive) { node.forgetPeer(record.id) }
        } message: { _ in
            Text("They'll need to scan your card again to reach you over the internet.")
        }
    }

    @ViewBuilder
    private func name(_ record: PeerRecord) -> some View {
        if record.name.isEmpty {
            Text(record.id.description).monospaced()
        } else {
            Text(record.name)
        }
    }

    @ViewBuilder
    private func blockedName(_ id: NodeID) -> some View {
        let name = node.peerStore.record(for: id)?.name ?? ""
        if name.isEmpty {
            Text(id.description).monospaced()
        } else {
            Text(name)
        }
    }

    private func title(for record: PeerRecord) -> String {
        record.name.isEmpty ? record.id.description : record.name
    }
}

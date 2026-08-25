import NearbyCore
import SwiftUI

struct RoomListView: View {
    @Environment(NearbyNode.self) private var node
    @State private var roomName = ""

    var body: some View {
        @Bindable var node = node

        List {
            Section {
                TextField("Name", text: $node.displayName)
            } header: {
                Text("You")
            } footer: {
                Text(node.nodeID.description).monospaced()
            }

            Section("Host") {
                TextField("Room name", text: $roomName)
                Button("Start room") { node.hostRoom(name: roomName) }
                    .disabled(roomName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Section("Nearby rooms") {
                if node.rooms.isEmpty {
                    ContentUnavailableView(
                        "No rooms nearby",
                        systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("Someone nearby needs to start a room.")
                    )
                } else {
                    ForEach(node.rooms, id: \.roomID) { room in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(room.name)
                                Text(hostName(of: room))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if node.joinState == .requested(room.roomID) {
                                ProgressView()
                            } else {
                                Button("Join") { node.requestJoin(room) }
                            }
                        }
                    }
                }
            }

            if case .rejected(let reason) = node.joinState {
                Section {
                    Text("Join declined: \(reason)")
                }
            }

            Section("Peers") {
                if node.peers.isEmpty {
                    Text("No peers yet")
                } else {
                    ForEach(node.peers) { peer in
                        VStack(alignment: .leading) {
                            Text(peer.name)
                            Text(peer.links.map(\.transport.rawValue).joined(separator: ", "))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Nearby")
        .task {
            if roomName.isEmpty { roomName = "\(node.displayName)'s room" }
        }
    }

    private func hostName(of room: RoomAnnounce) -> String {
        node.peers.first { $0.id == room.host }?.name ?? room.host.description
    }
}

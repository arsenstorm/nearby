import NearbyCore
import SwiftUI

struct RoomListView: View {
    @Environment(NearbyNode.self) private var node
    @State private var roomName = ""
    @State private var showRoomSettings = false

    var body: some View {
        VStack(spacing: 40) {
            StatusDot(
                state: node.peers.isEmpty ? .idle : .live,
                caption: node.peers.isEmpty ? "Looking for people nearby" : "\(node.peers.count) nearby"
            )
            .padding(.top, 96)
            HStack(spacing: 12) {
                Button { node.hostRoom(name: roomName) } label: {
                    Text("Start a room").frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.glassProminent)
                .disabled(roomName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button { showRoomSettings = true } label: {
                    Image(systemName: "slider.horizontal.3").padding(.vertical, 8)
                }
                .buttonStyle(.glass)
            }
            nearbyRooms
            Spacer()
        }
        .frame(maxWidth: 340)
        .padding()
        .frame(maxWidth: .infinity)
        .toolbarTitleDisplayMode(.inline)
        .task { if roomName.isEmpty { roomName = "\(node.displayName)'s room" } }
        .sheet(isPresented: $showRoomSettings) {
            NavigationStack {
                Form { TextField("Room name", text: $roomName) }
                    .navigationTitle("Room settings")
                    .toolbar { Button("Done") { showRoomSettings = false } }
            }
            .presentationDetents([.medium])
        }
    }

    @ViewBuilder
    private var nearbyRooms: some View {
        if node.rooms.isEmpty {
            Text("Nobody nearby has started a room yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Nearby rooms").font(.headline)
                if case .rejected(let reason) = node.joinState {
                    Text("Join declined: \(reason)").font(.footnote).foregroundStyle(.red)
                }
                ForEach(node.rooms, id: \.roomID) { room in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(room.name)
                            Text(hostName(of: room)).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if node.joinState == .requested(room.roomID) {
                            ProgressView()
                        } else {
                            Button("Join") { node.requestJoin(room) }.buttonStyle(.glass)
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(in: .rect(cornerRadius: 24))
        }
    }

    private func hostName(of room: RoomAnnounce) -> String {
        node.peers.first { $0.id == room.host }?.name ?? room.host.description
    }
}

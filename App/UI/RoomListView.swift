import NearbyCore
import SwiftUI

struct RoomListView: View {
    @Environment(NearbyNode.self) private var node
    @State private var roomName = ""
    @State private var editingName = false
    @State private var draftName = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Button { node.hostRoom(name: roomName) } label: {
                    Text("Start a room").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(roomName.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.top, 36)

                Button {
                    draftName = roomName
                    editingName = true
                } label: {
                    HStack(spacing: 5) {
                        Text(roomName.isEmpty ? "Name your room" : roomName).lineLimit(1)
                        Image(systemName: "pencil").font(.caption.weight(.semibold))
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Change room name")
                .padding(.top, 10)

                nearbyRooms
                    .padding(.top, 28)
                    .animation(.easeInOut(duration: 0.35), value: node.rooms.isEmpty)
            }
            .frame(maxWidth: 320)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .alert("Room name", isPresented: $editingName) {
            TextField("Room name", text: $draftName)
            Button("Save") {
                let trimmed = draftName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { roomName = trimmed }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task { if roomName.isEmpty { roomName = "\(node.displayName)'s room" } }
    }

    @ViewBuilder
    private var nearbyRooms: some View {
        if node.rooms.isEmpty {
            if !node.peers.isEmpty {
                Text("No rooms nearby yet.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("Nearby rooms")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                if case .rejected(let reason) = node.joinState {
                    Text("Join declined: \(reason).").font(.footnote).foregroundStyle(.red).padding(.bottom, 8)
                }
                ForEach(node.rooms, id: \.roomID) { room in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
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
                    .padding(.vertical, 11)
                    if room.roomID != node.rooms.last?.roomID { Divider() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func hostName(of room: RoomAnnounce) -> String {
        node.peers.first { $0.id == room.host }?.name ?? room.host.description
    }
}

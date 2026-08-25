import NearbyCore
import SwiftUI

struct RoomListView: View {
    @Environment(NearbyNode.self) private var node
    @State private var roomName = ""
    @State private var showRoomSettings = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            StatusDot(state: node.peers.isEmpty ? .idle : .live, searching: node.peers.isEmpty)

            VStack(spacing: 6) {
                Text(node.peers.isEmpty ? "Looking for people nearby" : "^[\(node.peers.count) person](inflect: true) nearby")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text(node.peers.isEmpty
                     ? "Keep the app open. People appear as they come into range."
                     : "Start a room and they can join you.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 4)

            Button { node.hostRoom(name: roomName) } label: {
                Text("Start a room").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(roomName.trimmingCharacters(in: .whitespaces).isEmpty)
            .padding(.top, 36)

            Button("Room settings") { showRoomSettings = true }
                .font(.subheadline)
                .padding(.top, 12)

            nearbyRooms
                .padding(.top, 28)

            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 320)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .font(.footnote)
                .foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("Nearby rooms")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
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
                    .padding(.vertical, 10)
                    if room.roomID != node.rooms.last?.roomID { Divider() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(in: .rect(cornerRadius: 20))
        }
    }

    private func hostName(of room: RoomAnnounce) -> String {
        node.peers.first { $0.id == room.host }?.name ?? room.host.description
    }
}

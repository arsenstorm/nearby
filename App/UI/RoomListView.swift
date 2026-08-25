import NearbyCore
import SwiftUI

struct RoomListView: View {
    @Environment(NearbyNode.self) private var node
    @State private var roomName = ""
    @State private var showRoomSettings = false

    var body: some View {
        VStack(spacing: 32) {
            status
            HStack(spacing: 12) {
                Button { node.hostRoom(name: roomName) } label: {
                    Text("Start a room").frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(roomName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button { showRoomSettings = true } label: {
                    Image(systemName: "slider.horizontal.3").padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
            }
            nearbyRooms
        }
        .padding()
        .navigationTitle("Nearby")
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

    private var status: some View {
        let active = node.transportStates.values.contains { $0.active }
        return VStack(spacing: 8) {
            Circle()
                .fill(!active ? .gray : node.peers.isEmpty ? .orange : .green)
                .frame(width: 56, height: 56)
            Text(!active ? "Offline" : node.peers.isEmpty ? "Looking for people nearby" : "\(node.peers.count) nearby")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 24)
    }

    private var nearbyRooms: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nearby rooms").font(.headline)
            if case .rejected(let reason) = node.joinState {
                Text("Join declined: \(reason)").font(.footnote).foregroundStyle(.red)
            }
            if node.rooms.isEmpty {
                Text("Nobody nearby has started a room yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
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
                            Button("Join") { node.requestJoin(room) }.buttonStyle(.bordered)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 16))
    }

    private func hostName(of room: RoomAnnounce) -> String {
        node.peers.first { $0.id == room.host }?.name ?? room.host.description
    }
}

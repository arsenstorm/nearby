import NearbyCore
import SwiftUI

struct RoomView: View {
    @Environment(NearbyNode.self) private var node

    var body: some View {
        @Bindable var node = node
        let members = node.hosted?.members ?? node.joined?.members ?? []

        VStack(spacing: 40) {
            StatusDot(state: dotState, caption: caption, level: { node.inputLevel })
                .padding(.top, 96)

            if let pending = node.hosted?.pending, !pending.isEmpty {
                card("Wants to join") {
                    ForEach(pending, id: \.id) { member in
                        HStack {
                            Text(member.name)
                            Spacer()
                            Button("Accept") { node.accept(member.id) }.buttonStyle(.glassProminent)
                            Button("Decline") { node.reject(member.id) }.buttonStyle(.glass)
                        }
                    }
                }
            }

            card(node.hosted?.name ?? node.joined?.name ?? "Room") {
                ForEach(members, id: \.id) { member in
                    Text(member.id == node.nodeID ? "\(member.name) (you)" : member.name)
                }
            }

            Spacer()

            HStack(spacing: 12) {
                Button { node.muted.toggle() } label: {
                    Label(node.muted ? "Unmute" : "Mute", systemImage: node.muted ? "mic.slash.fill" : "mic.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.glass)
                Button(role: .destructive) { node.leaveOrClose() } label: {
                    Text(node.hosted != nil ? "Close room" : "Leave")
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
            }
        }
        .frame(maxWidth: 340)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.green.opacity(0.18).ignoresSafeArea())
        .toolbarTitleDisplayMode(.inline)
    }

    private var dotState: StatusDot.State {
        if node.disconnected { return .disconnected }
        if node.muted { return .muted }
        return node.inCall ? .live : .idle
    }

    private var caption: String {
        if node.disconnected { return "Reconnecting…" }
        if node.muted { return "Muted" }
        return node.inCall ? "Live" : "Connecting…"
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: .rect(cornerRadius: 24))
    }
}

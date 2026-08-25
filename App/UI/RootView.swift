import NearbyCore
import SwiftUI

struct RootView: View {
    @Environment(NearbyNode.self) private var node
    @State private var showHelp = false

    private var inRoom: Bool { node.hosted != nil || node.joined != nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                ZStack {
                    if inRoom {
                        RoomView().transition(.opacity)
                    } else {
                        RoomListView().transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.4), value: inRoom)
            }
            .background {
                // Colour lives around the dot, not across the whole screen.
                RadialGradient(
                    colors: [tint.opacity(0.28), tint.opacity(0.0)],
                    center: .init(x: 0.5, y: 0.22), startRadius: 0, endRadius: 320
                )
                .ignoresSafeArea()
            }
            .animation(.easeInOut(duration: 0.4), value: dotState)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                Button { showHelp = true } label: { Image(systemName: "questionmark.circle") }
                NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
            }
            .sheet(isPresented: $showHelp) { HelpSheet() }
            .alert(
                node.keyWarning.map { "\($0.hello.name) has a new key" } ?? "",
                // Dismissal is driven by the buttons; the setter must not clear the warning twice.
                isPresented: Binding(get: { node.keyWarning != nil }, set: { _ in }),
                presenting: node.keyWarning
            ) { _ in
                Button("Trust") { node.trustKeyChange() }
                Button("Ignore", role: .cancel) { node.dismissKeyWarning() }
            } message: { _ in
                Text("This can mean a new phone, or someone else using this name. Trust the new key only if you expect it.")
            }
        }
    }

    /// The one fixed region both screens share, so switching screens never moves the dot.
    private var header: some View {
        VStack(spacing: 0) {
            StatusDot(state: dotState, searching: dotState == .idle || dotState == .live)
            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .contentTransition(.numericText())
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
                    .contentTransition(.opacity)
            }
            .padding(.top, 4)
            .padding(.horizontal, 24)
            .animation(.easeInOut(duration: 0.35), value: title)
        }
        .frame(maxWidth: 320)
        .padding(.top, 56)
    }

    private var dotState: StatusDot.State {
        if inRoom {
            if node.disconnected { return .disconnected }
            if node.muted { return .muted }
            return node.inCall ? .live : .idle
        }
        return node.peers.isEmpty ? .idle : .live
    }

    private var tint: Color {
        guard inRoom else { return .clear }
        switch dotState {
        case .live: return .green
        case .muted: return .orange
        case .disconnected: return .red
        case .idle: return .gray
        }
    }

    private var others: [Member] {
        (node.hosted?.members ?? node.joined?.members ?? []).filter { $0.id != node.nodeID }
    }

    private var roomName: String { node.hosted?.name ?? node.joined?.name ?? "the room" }

    private var title: String {
        if inRoom {
            if node.disconnected { return "Connection lost" }
            if node.muted { return "You're muted" }
            guard node.inCall else { return "Setting up audio…" }
            switch others.count {
            case 0: return "Waiting for people"
            case 1: return "Talking with \(others[0].name)"
            default: return "Talking with \(others.count) people"
            }
        }
        return node.peers.isEmpty ? "Looking for people nearby" : "\(node.peers.count) \(node.peers.count == 1 ? "person" : "people") nearby"
    }

    private var subtitle: String {
        if inRoom {
            if node.disconnected { return "Trying to reconnect to \(roomName)." }
            if node.muted { return "Nobody can hear you until you unmute." }
            guard node.inCall else { return "Just a moment." }
            return others.isEmpty
                ? "\(roomName) is open. People nearby can join you."
                : "Everyone in \(roomName) can hear you."
        }
        return node.peers.isEmpty
            ? "As people come within range, you'll see them appear here."
            : "Start a room and they can join you."
    }
}

struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Text("Nearby lets you talk to people around you over Wi-Fi and Bluetooth, with no internet or account. Start a room, or join one someone nearby has started.")
                .padding()
                .frame(maxHeight: .infinity, alignment: .top)
                .navigationTitle("How it works")
                .toolbar { Button("Done") { dismiss() } }
        }
        .presentationDetents([.medium])
    }
}

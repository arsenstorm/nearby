import SwiftUI

/// The one status indicator: grey idle, green speaking pulse, orange muted, red disconnected.
struct StatusDot: View {
    enum State { case idle, live, muted, disconnected }
    let state: State
    let caption: String
    /// 0...1; drives the pulse when live.
    var level: () -> Float = { 0 }

    var body: some View {
        VStack(spacing: 8) {
            TimelineView(.animation(paused: state != .live)) { _ in
                let scale = state == .live ? 1 + CGFloat(min(level() * 4, 1)) * 0.35 : 1
                ZStack {
                    Circle().fill(color.opacity(0.25)).scaleEffect(scale)
                    Circle()
                        .fill(.clear)
                        .glassEffect(.regular.tint(color), in: .circle)
                        .padding(8)
                    if state == .muted {
                        Image(systemName: "mic.slash.fill").foregroundStyle(.white).font(.title2)
                    }
                }
                .frame(width: 96, height: 96)
                .animation(.easeOut(duration: 0.1), value: scale)
            }
            Text(caption).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch state {
        case .idle: .gray
        case .live: .green
        case .muted: .orange
        case .disconnected: .red
        }
    }
}

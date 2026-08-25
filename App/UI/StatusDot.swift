import SwiftUI

/// The one status indicator: grey idle, green speaking pulse, orange muted, red disconnected.
/// `searching` adds outward ripples so idle reads as "listening", not "off".
struct StatusDot: View {
    enum State { case idle, live, muted, disconnected }
    let state: State
    var searching = false
    /// 0...1; drives the pulse when live.
    var level: () -> Float = { 0 }

    private let size: CGFloat = 72
    private let period: TimeInterval = 2.4

    var body: some View {
        TimelineView(.animation(paused: state != .live && !searching)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let speech = state == .live ? CGFloat(min(level() * 4, 1)) : 0
            ZStack {
                if searching {
                    ForEach(0..<3, id: \.self) { i in
                        let phase = ((t / period) + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                        Circle()
                            .stroke(color.opacity(0.35 * (1 - phase)), lineWidth: 1.5)
                            .scaleEffect(1 + phase * 1.4)
                    }
                }
                Circle()
                    .fill(color.opacity(0.18))
                    .scaleEffect(1.25 + speech * 0.45)
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [color.opacity(0.95), color],
                            center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.7
                        )
                    )
                    .shadow(color: color.opacity(0.35), radius: 12, y: 4)
                if state == .muted {
                    Image(systemName: "mic.slash.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                } else if state == .disconnected {
                    Image(systemName: "wifi.slash")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .padding(size * 0.7)
            .animation(.easeOut(duration: 0.12), value: speech)
        }
        .accessibilityHidden(true)
    }

    private var color: Color {
        switch state {
        case .idle: Color(.systemGray2)
        case .live: .green
        case .muted: .orange
        case .disconnected: .red
        }
    }
}

import NearbyCore
import SwiftUI

struct RoomView: View {
    @Environment(NearbyNode.self) private var node

    var body: some View {
        let members = node.hosted?.members ?? node.joined?.members ?? []

        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let pending = node.hosted?.pending, !pending.isEmpty {
                    section("Wants to join") {
                        ForEach(pending, id: \.id) { member in
                            row {
                                Text(member.name)
                                Spacer()
                                Button("Accept") { node.accept(member.id) }.buttonStyle(.glassProminent)
                                Button("Decline") { node.reject(member.id) }.buttonStyle(.glass)
                            }
                            if member.id != pending.last?.id { Divider() }
                        }
                    }
                }

                if members.count > 1 {
                    section("In the room") {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(members, id: \.id) { member in
                                HStack(spacing: 10) {
                                    let quality = member.id == node.nodeID ? 1
                                        : node.peers.contains { $0.id == member.id } ? linkQuality(node.pathInfo[member.id]) : 0
                                    Text(member.id == node.nodeID ? "You" : member.name)
                                        .lineLimit(1)
                                        .layoutPriority(1)
                                    Leader()
                                        .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0.1, 5]))
                                        .foregroundStyle(.quaternary)
                                        .frame(height: 1.5)
                                    Image(systemName: "cellularbars", variableValue: quality)
                                        .symbolRenderingMode(.hierarchical)
                                        .foregroundStyle(qualityColor(quality))
                                        .font(.subheadline)
                                        .overlay(alignment: .bottomTrailing) {
                                            if quality == 0 {
                                                Image(systemName: "xmark.circle.fill")
                                                    .font(.system(size: 9, weight: .bold))
                                                    .foregroundStyle(.white, .red)
                                                    .offset(x: 4, y: 3)
                                                    .transition(.scale.combined(with: .opacity))
                                            }
                                        }
                                        .animation(.easeInOut(duration: 0.3), value: quality)
                                }
                                .padding(.vertical, 9)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 320, alignment: .leading)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .padding(.top, 36)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            bottomBar
        }
    }

    /// Standard call controls: mute and hang up.
    private var bottomBar: some View {
        HStack(spacing: 24) {
            Button { node.muted.toggle() } label: {
                Image(systemName: node.muted ? "mic.slash.fill" : "mic.fill")
                    .font(.title2.weight(.semibold))
                    .frame(width: 64, height: 64)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(node.muted ? .orange : nil)
            .accessibilityLabel(node.muted ? "Unmute" : "Mute")

            Button { node.leaveRoom() } label: {
                Image(systemName: "phone.down.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(.red)
            .accessibilityLabel("Leave room")
        }
        .padding(.vertical, 8)
        .animation(.easeInOut(duration: 0.2), value: node.muted)
    }

    /// 0 unreachable; otherwise 1 minus penalties for extra hops, loss and latency.
    private func linkQuality(_ path: PathInfo?) -> Double {
        guard let path else { return 0 }
        var q = 1.0
        q -= Double(max(path.hops - 1, 0)) * 0.25
        q -= min(path.lossFraction * 3, 0.5)
        q -= max(path.latencyMs - 100, 0) / 400
        return max(q, 0.25)
    }

    private func qualityColor(_ q: Double) -> Color {
        switch q {
        case 0: Color(.systemGray3)
        case ..<0.5: .red
        case ..<0.8: .orange
        default: .green
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(content: content)
            .padding(.vertical, 11)
    }
}


/// Horizontal line through the middle of its frame, for dotted leaders.
private struct Leader: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

import ActivityKit
import SwiftUI
import WidgetKit

private extension CallActivityAttributes.ContentState {
    var color: Color {
        if disconnected { return .red }
        return muted ? .orange : .green
    }
}

private struct StatusDot: View {
    let state: CallActivityAttributes.ContentState
    var size: CGFloat = 14

    var body: some View {
        ZStack {
            Circle().fill(state.color.opacity(0.25))
            Image(systemName: "circle.fill")
                .resizable()
                .foregroundStyle(state.color)
                .padding(size * 0.22)
                .symbolEffect(.pulse, options: .repeating, isActive: !state.disconnected)
        }
        .frame(width: size, height: size)
    }
}

private struct Timer: View {
    let state: CallActivityAttributes.ContentState

    var body: some View {
        Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false, showsHours: false)
            .monospacedDigit()
            .multilineTextAlignment(.leading)
            .frame(width: 44, alignment: .leading)
    }
}

private struct Controls: View {
    let state: CallActivityAttributes.ContentState
    var size: CGFloat = 44

    var body: some View {
        HStack(spacing: 12) {
            Button(intent: MuteCallIntent()) {
                Image(systemName: state.muted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(state.muted ? .orange : .primary)
                    .frame(width: size, height: size)
                    .background(.primary.opacity(0.1), in: .circle)
                    .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain)
            Button(intent: LeaveCallIntent()) {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(.red, in: .circle)
            }
            .buttonStyle(.plain)
        }
    }
}

struct CallActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CallActivityAttributes.self) { context in
            HStack(spacing: 14) {
                StatusDot(state: context.state, size: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.title)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(context.state.subtitle).lineLimit(1)
                        Timer(state: context.state)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Controls(state: context.state)
            }
            .padding(16)
            .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 10) {
                        StatusDot(state: context.state, size: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.state.title).font(.headline).lineLimit(1)
                            Text(context.state.subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Timer(state: context.state)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Controls(state: context.state, size: 40)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 6)
                }
            } compactLeading: {
                StatusDot(state: context.state, size: 14).padding(.leading, 2)
            } compactTrailing: {
                Timer(state: context.state)
                    .font(.footnote)
                    .foregroundStyle(context.state.color)
                    .frame(maxWidth: 48)
                    .padding(.trailing, 2)
            } minimal: {
                StatusDot(state: context.state, size: 14)
            }
        }
    }
}

import ActivityKit
import SwiftUI
import WidgetKit

private func timerText(_ state: CallActivityAttributes.ContentState) -> some View {
    Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
        .monospacedDigit()
}

private func micIcon(_ state: CallActivityAttributes.ContentState) -> some View {
    Image(systemName: state.muted ? "mic.slash.fill" : "mic.fill")
}

private struct CallButtons: View {
    let state: CallActivityAttributes.ContentState

    var body: some View {
        HStack {
            Button(intent: MuteCallIntent()) {
                Label(state.muted ? "Unmute" : "Mute",
                      systemImage: state.muted ? "mic.slash.fill" : "mic.fill")
            }
            Button(intent: LeaveCallIntent()) {
                Label("Leave", systemImage: "phone.down.fill")
            }
            .tint(.red)
        }
        .buttonStyle(.bordered)
    }
}

struct CallActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CallActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 6) {
                Text(context.state.roomName)
                    .font(.headline)
                Text("\(context.state.memberCount) in call")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                timerText(context.state)
                CallButtons(state: context.state)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading) {
                        Text(context.state.roomName)
                            .font(.headline)
                        Text("\(context.state.memberCount) in call")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    timerText(context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    CallButtons(state: context.state)
                }
            } compactLeading: {
                micIcon(context.state)
            } compactTrailing: {
                timerText(context.state)
            } minimal: {
                micIcon(context.state)
            }
        }
    }
}

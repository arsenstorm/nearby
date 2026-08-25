import ActivityKit
import SwiftUI
import WidgetKit

struct CallActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CallActivityAttributes.self) { context in
            Text(context.state.roomName)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) { Text(context.state.roomName) }
            } compactLeading: {
                Image(systemName: "mic")
            } compactTrailing: {
                Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
            } minimal: {
                Image(systemName: "mic")
            }
        }
    }
}

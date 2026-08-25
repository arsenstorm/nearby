import ActivityKit
import Foundation

struct CallActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Same copy as the in-app header, e.g. "Talking with Arsen".
        var title: String
        /// e.g. "Arsen's room · 3 in the room"
        var subtitle: String
        var muted: Bool
        var disconnected: Bool
        var startedAt: Date
    }

    var roomID: UInt64
}

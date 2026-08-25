import ActivityKit
import Foundation

struct CallActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var roomName: String
        var memberCount: Int
        var muted: Bool
        var startedAt: Date
    }

    var roomID: UInt64
}

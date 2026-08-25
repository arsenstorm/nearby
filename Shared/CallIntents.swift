import AppIntents

struct MuteCallIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mute"
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        #if !NEARBY_EXTENSION
        await MainActor.run { NearbyNode.current?.toggleMute() }
        #endif
        return .result()
    }
}

struct LeaveCallIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Leave"
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        #if !NEARBY_EXTENSION
        await MainActor.run { NearbyNode.current?.leaveOrClose() }
        #endif
        return .result()
    }
}

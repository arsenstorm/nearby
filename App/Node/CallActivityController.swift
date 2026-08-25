import ActivityKit
import Foundation
import Observation
import os

/// Mirrors call state into a Live Activity. Reads the node, never writes it.
@MainActor
final class CallActivityController {
    private let node: NearbyNode
    private let logger = Logger(subsystem: "com.arsenstorm.nearby", category: "activity")
    private var activity: Activity<CallActivityAttributes>?
    private var lastState: CallActivityAttributes.ContentState?
    private var callStartedAt: Date?
    private var observing = false

    init(node: NearbyNode) {
        self.node = node
    }

    func start() {
        guard !observing else { return }
        observing = true
        Task { @MainActor in
            // A crash leaves the previous process's activity on screen; it can no longer be updated.
            for stale in Activity<CallActivityAttributes>.activities {
                await stale.end(nil, dismissalPolicy: .immediate)
            }
            observe()
            sync()
        }
    }

    private func observe() {
        withObservationTracking {
            _ = node.inCall
            _ = node.muted
            _ = node.hosted?.name
            _ = node.hosted?.id
            _ = node.hosted?.members.count
            _ = node.joined?.name
            _ = node.joined?.id
            _ = node.joined?.members.count
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.sync()
                self.observe()
            }
        }
    }

    private func sync() {
        guard node.inCall else {
            callStartedAt = nil
            lastState = nil
            guard let activity else { return }
            self.activity = nil
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
            return
        }
        let startedAt = callStartedAt ?? Date()
        callStartedAt = startedAt
        let state = CallActivityAttributes.ContentState(
            roomName: node.hosted?.name ?? node.joined?.name ?? "Call",
            memberCount: (node.hosted?.members ?? node.joined?.members ?? []).count,
            muted: node.muted,
            startedAt: startedAt
        )
        guard state != lastState else { return }
        if let activity {
            lastState = state
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity<CallActivityAttributes>.request(
                attributes: CallActivityAttributes(roomID: node.hosted?.id ?? node.joined?.id ?? 0),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            lastState = state
        } catch {
            logger.error("live activity request failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

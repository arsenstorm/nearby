import SwiftUI

@main
struct NearbyApp: App {
    @State private var node = NearbyNode()
    @State private var activity: CallActivityController?
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(node)
                .task {
                    node.start()
                    guard activity == nil else { return }
                    let controller = CallActivityController(node: node)
                    activity = controller
                    controller.start()
                }
                .onChange(of: scenePhase) { old, new in
                    if old == .background, new == .active { node.resumeFromBackground() }
                }
        }
    }
}

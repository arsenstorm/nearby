import SwiftUI

@main
struct NearbyApp: App {
    @State private var node = NearbyNode()
    @State private var activity: CallActivityController?

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
        }
    }
}

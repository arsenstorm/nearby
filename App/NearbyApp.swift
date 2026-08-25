import SwiftUI

@main
struct NearbyApp: App {
    @State private var node = NearbyNode()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(node)
                .task { node.start() }
        }
    }
}

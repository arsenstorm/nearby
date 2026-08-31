import NearbyCore
import SwiftUI

@main
struct NearbyApp: App {
    @State private var node = NearbyNode()
    @State private var activity: CallActivityController?
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasBackgrounded = false

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
                .onOpenURL { url in
                    if let card = PeerCard(url: url) { node.addPeer(card) }
                }
                .onChange(of: scenePhase) { _, phase in
                    // Coming back passes through .inactive, so remember the background visit.
                    switch phase {
                    case .background: wasBackgrounded = true
                    case .active where wasBackgrounded:
                        wasBackgrounded = false
                        node.resumeFromBackground()
                    default: break
                    }
                }
        }
    }
}

import SwiftUI

struct SettingsView: View {
    @Environment(NearbyNode.self) private var node

    var body: some View {
        @Bindable var node = node
        Form {
            Section("Profile") {
                TextField("Name", text: $node.displayName)
            }
            Section {
                NavigationLink("Debug") { DebugView() }
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }
}

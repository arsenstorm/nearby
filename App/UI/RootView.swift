import SwiftUI

struct RootView: View {
    @Environment(NearbyNode.self) private var node
    @State private var showHelp = false

    var body: some View {
        NavigationStack {
            Group {
                if node.hosted != nil || node.joined != nil {
                    RoomView()
                } else {
                    RoomListView()
                }
            }
            .toolbar {
                Button { showHelp = true } label: { Image(systemName: "questionmark.circle") }
                NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
            }
            .sheet(isPresented: $showHelp) {
                NavigationStack {
                    Text("Nearby lets you talk to people around you over Wi-Fi and Bluetooth, with no internet or account. Start a room, or join one someone nearby has started.")
                        .padding()
                        .frame(maxHeight: .infinity, alignment: .top)
                        .navigationTitle("How it works")
                        .toolbar { Button("Done") { showHelp = false } }
                }
                .presentationDetents([.medium])
            }
            .alert(
                node.keyWarning.map { "\($0.hello.name) has a new key" } ?? "",
                // Dismissal is driven by the buttons; the setter must not clear the warning twice.
                isPresented: Binding(get: { node.keyWarning != nil }, set: { _ in }),
                presenting: node.keyWarning
            ) { _ in
                Button("Trust") { node.trustKeyChange() }
                Button("Ignore", role: .cancel) { node.dismissKeyWarning() }
            } message: { _ in
                Text("This can mean a new phone, or someone else using this name. Trust the new key only if you expect it.")
            }
        }
    }
}

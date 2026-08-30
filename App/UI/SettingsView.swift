import SwiftUI

struct SettingsView: View {
    @Environment(NearbyNode.self) private var node
    @State private var showHelp = false
    @State private var showScanner = false
    @State private var confirmRegenerate = false

    var body: some View {
        @Bindable var node = node
        Form {
            Section {
                VStack(spacing: 6) {
                    appIcon
                        .frame(width: 84, height: 84)
                        .clipShape(.rect(cornerRadius: 19))
                        .padding(.bottom, 8)
                    Text("Nearby")
                        .font(.title2.weight(.semibold))
                    Text("Version \(Self.version) (\(Self.build))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }

            Section("Your name") {
                TextField("Name", text: $node.displayName)
            }

            Section("Friends") {
                NavigationLink("Friends") { FriendsView() }
                NavigationLink("Your card") { PeerCardView() }
                Button("Scan a card") { showScanner = true }
            }

            Section {
                Button("Regenerate identity", role: .destructive) { confirmRegenerate = true }
            } header: {
                Text("Identity")
            } footer: {
                Text("Your card stops working everywhere. Friends will need to scan the new one.")
            }

            Section("Advanced") {
                NavigationLink("Debug") { DebugView() }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { showHelp = true } label: { Image(systemName: "questionmark.circle") }
        }
        .sheet(isPresented: $showHelp) { HelpSheet() }
        .sheet(isPresented: $showScanner) { ScanCardView() }
        .confirmationDialog("Regenerate identity?", isPresented: $confirmRegenerate, titleVisibility: .visible) {
            Button("Regenerate", role: .destructive) { node.regenerateIdentity() }
        } message: {
            Text("Friends who have your card will need to scan the new one, and you'll leave any room you're in.")
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = Self.iconImage {
            Image(uiImage: icon).resizable()
        } else {
            ZStack {
                Color.accentColor
                Image(systemName: "person.2.wave.2.fill")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
    }

    private static var iconImage: UIImage? {
        let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let name = (primary?["CFBundleIconFiles"] as? [String])?.last
        return name.flatMap(UIImage.init(named:))
    }

    private static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    private static let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
}

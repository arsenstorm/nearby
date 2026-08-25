import SwiftUI

struct SettingsView: View {
    @Environment(NearbyNode.self) private var node
    @State private var showHelp = false

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

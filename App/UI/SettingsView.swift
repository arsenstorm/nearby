import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Environment(NearbyNode.self) private var node
    @State private var inputs: [AVAudioSessionPortDescription] = []
    @State private var inputUID = AudioEngine.preferredInputUID ?? ""

    var body: some View {
        @Bindable var node = node
        Form {
            Section("Profile") {
                TextField("Name", text: $node.displayName)
            }

            if inputs.count > 1 {
                Section("Microphone") {
                    Picker("Input", selection: $inputUID) {
                        Text("Automatic").tag("")
                        ForEach(inputs, id: \.uid) { Text($0.portName).tag($0.uid) }
                    }
                    .onChange(of: inputUID) { _, uid in AudioEngine.preferredInputUID = uid.isEmpty ? nil : uid }
                }
            }

            Section {
                NavigationLink("Debug") { DebugView() }
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .onAppear(perform: refreshInputs)
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            refreshInputs()
        }
    }

    private func refreshInputs() {
        inputs = AudioEngine.availableInputs()
        if !inputUID.isEmpty, !inputs.contains(where: { $0.uid == inputUID }) { inputUID = "" }
    }
}

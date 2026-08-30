import DeviceDiscoveryUI
import SwiftUI
import WiFiAware

/// One-time system pairing flow for `_nearby._udp`, plus the list of devices already paired for it.
struct WiFiAwarePairingView: View {
    @State private var paired: [WAPairedDevice] = []

    var body: some View {
        List {
            Section {
                #if targetEnvironment(simulator)
                Text("Wi-Fi Aware pairing needs two real phones.")
                    .foregroundStyle(.secondary)
                #else
                // Pairing is asymmetric: one phone publishes (top row), the other browses for it
                // (bottom row). Two publishers never see each other.
                if let publishable = WAPublishableService.allServices[WiFiAwareTransport.serviceType],
                   let subscribable = WASubscribableService.allServices[WiFiAwareTransport.serviceType] {
                    DevicePairingView(.wifiAware(.connecting(to: publishable, from: .allPairedDevices))) {
                        Label("Be discoverable", systemImage: "wifi")
                    } fallback: {
                        Text("This phone does not support Wi-Fi Aware.")
                            .foregroundStyle(.secondary)
                    }
                    DevicePicker(.wifiAware(.connecting(to: .selected([]), from: subscribable))) { _ in
                        // The system stores the pairing; the transport's browser picks it up.
                    } label: {
                        Label("Find a phone", systemImage: "magnifyingglass")
                    } fallback: {
                        EmptyView()
                    }
                } else {
                    Text("\(WiFiAwareTransport.serviceType) is not declared in Info.plist.")
                        .foregroundStyle(.secondary)
                }
                #endif
            } footer: {
                Text("Tap “Be discoverable” on one phone and “Find a phone” on the other. Pair once; after that the two phones find each other with no network.")
            }

            Section("Paired devices") {
                if paired.isEmpty {
                    Text("None yet").foregroundStyle(.secondary)
                }
                ForEach(paired) { device in
                    Text(name(of: device))
                }
            }
        }
        .navigationTitle("Wi-Fi Aware pairing")
        .task {
            // Live sequence: re-yields the whole set whenever a device is paired or unpaired.
            // It throws on hardware without Wi-Fi Aware, which just means "no paired devices".
            do {
                for try await devices in WAPairedDevice.allDevices {
                    paired = devices.values.sorted { $0.id < $1.id }
                }
            } catch {}
        }
    }

    private func name(of device: WAPairedDevice) -> String {
        device.pairingInfo?.pairingName ?? device.name ?? "Device \(device.id)"
    }
}

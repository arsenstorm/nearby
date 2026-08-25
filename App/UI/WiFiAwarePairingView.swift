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
                if let service = WAPublishableService.allServices[WiFiAwareTransport.serviceType] {
                    DevicePairingView(.wifiAware(.connecting(to: service, from: .allPairedDevices))) {
                        Label("Pair a phone", systemImage: "wifi")
                    } fallback: {
                        Text("This phone does not support Wi-Fi Aware.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("\(WiFiAwareTransport.serviceType) is not declared in Info.plist.")
                        .foregroundStyle(.secondary)
                }
                #endif
            } footer: {
                Text("Pair once; after that the two phones find each other with no network.")
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

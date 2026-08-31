import StoreKit
import SwiftUI

struct PaywallView: View {
    let prompt: PaywallPrompt
    @Environment(NearbyNode.self) private var node
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let name = node.peerName(prompt.peer)

        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    Text("Reach \(name) from anywhere")
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text("Calls nearby and direct calls over the internet are always free. \(name) can't be reached directly right now, so this call would go through a relay, a third-party service Nearby pays for. Nearby Plus covers it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    ProductView(id: RelayEntitlement.productID)
                        .productViewStyle(.large)
                        .onInAppPurchaseCompletion { _, result in
                            if case .success(.success) = result {
                                node.purchased(for: prompt.peer)
                                dismiss()
                            }
                        }
                    Button("Not now") { dismiss() }
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

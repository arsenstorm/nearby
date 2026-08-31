import NearbyCore
import SwiftUI
import VisionKit

struct ScanCardView: View {
    @Environment(NearbyNode.self) private var node
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var badCode = false

    private var trimmedLink: String { link.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var cameraReady: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            Group {
                if cameraReady {
                    CardScanner(onCard: add).ignoresSafeArea(edges: .bottom)
                } else {
                    pasteFallback
                }
            }
            .safeAreaInset(edge: .bottom) { manualEntry }
            .navigationTitle("Scan a card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel") { dismiss() } }
        }
    }

    private var pasteFallback: some View {
        ContentUnavailableView {
            Label("Camera unavailable", systemImage: "camera")
        } description: {
            Text("Paste your friend's link instead.")
        }
    }

    private var manualEntry: some View {
        VStack(spacing: 8) {
            if badCode {
                Text("That code doesn't look right.")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    // The camera is behind this, so the message carries its own ground.
                    .background(.thinMaterial, in: Capsule())
            }
            HStack(spacing: 10) {
                TextField("Link or code", text: $link)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.primary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(addPastedLink)
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                    .glassEffect(.regular, in: .capsule)
                Button(action: addPastedLink) {
                    Image(systemName: "plus")
                        .font(.headline)
                        .frame(width: 48, height: 48)
                        .glassEffect(.regular.tint(.accentColor).interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .disabled(trimmedLink.isEmpty)
                .accessibilityLabel("Add")
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .onChange(of: link) { badCode = false }
    }

    private func addPastedLink() {
        let trimmed = trimmedLink
        guard !trimmed.isEmpty else { return }
        // A code typed on its own carries no scheme, so try it as the host of one of our links too.
        let card = URL(string: trimmed).flatMap(PeerCard.init(url:))
            ?? (trimmed.contains("://") ? nil : URL(string: "\(PeerCard.scheme)://\(trimmed)").flatMap(PeerCard.init(url:)))
        guard let card else {
            badCode = true
            return
        }
        add(card)
    }

    private func add(_ card: PeerCard) {
        guard node.addPeer(card) else { return }
        dismiss()
    }
}

private struct CardScanner: UIViewControllerRepresentable {
    let onCard: (PeerCard) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        guard !scanner.isScanning else { return }
        try? scanner.startScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCard: onCard) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCard: (PeerCard) -> Void

        init(onCard: @escaping (PeerCard) -> Void) { self.onCard = onCard }

        func dataScanner(
            _ scanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for case .barcode(let barcode) in addedItems {
                guard let text = barcode.payloadStringValue, let url = URL(string: text),
                      let card = PeerCard(url: url)
                else { continue }
                onCard(card)
                return
            }
        }
    }
}

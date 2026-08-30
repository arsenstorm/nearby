import NearbyCore
import SwiftUI
import VisionKit

struct ScanCardView: View {
    @Environment(NearbyNode.self) private var node
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""

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
        } actions: {
            TextField("nearby://…", text: $link)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(width: 280)
            Button("Add", action: addPastedLink)
                .buttonStyle(.borderedProminent)
        }
    }

    private func addPastedLink() {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let card = PeerCard(url: url) else { return }
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

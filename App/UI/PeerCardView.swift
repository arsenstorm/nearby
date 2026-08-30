import CoreImage.CIFilterBuiltins
import NearbyCore
import SwiftUI

struct PeerCardView: View {
    @Environment(NearbyNode.self) private var node

    private var card: PeerCard { PeerCard(identity: node.identity, name: node.displayName) }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 16) {
                    code
                    Text(node.nodeID.description)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                    ShareLink("Share link", item: card.url)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            } footer: {
                Text("Anyone who scans this can reach you from anywhere — once you scan theirs too.")
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
        .navigationTitle("Your card")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var code: some View {
        if let image = Self.qrImage(for: card.url.absoluteString) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: 240, height: 240)
                .padding(16)
                // Scanners need dark-on-light, so the code carries its own white ground in dark mode.
                .background(.white, in: .rect(cornerRadius: 20))
        }
    }

    private static func qrImage(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

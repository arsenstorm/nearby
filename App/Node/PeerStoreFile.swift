import Foundation
import NearbyCore
import os

enum PeerStoreFile {
    private static let logger = Logger(subsystem: "com.shkrumelyak.nearby", category: "peers")

    private static var url: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return base.appending(path: "nearby", directoryHint: .isDirectory).appending(path: "peers.json")
    }

    static func load() -> PeerStore {
        guard let url,
              let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(PeerStore.self, from: data)
        else { return PeerStore() }
        return store
    }

    static func save(_ store: PeerStore) {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(store).write(to: url, options: .atomic)
        } catch {
            logger.error("peer store save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

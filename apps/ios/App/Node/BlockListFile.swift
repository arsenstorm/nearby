import Foundation
import NearbyCore
import os

enum BlockListFile {
    private static let logger = Logger(subsystem: "com.arsenstorm.nearby", category: "blocklist")

    private static var url: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return base.appending(path: "nearby", directoryHint: .isDirectory).appending(path: "blocked.json")
    }

    static func load() -> Set<NodeID> {
        guard let url,
              let data = try? Data(contentsOf: url),
              let ids = try? JSONDecoder().decode([NodeID].self, from: data)
        else { return [] }
        return Set(ids)
    }

    static func save(_ ids: Set<NodeID>) {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(Array(ids)).write(to: url, options: .atomic)
        } catch {
            logger.error("block list save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

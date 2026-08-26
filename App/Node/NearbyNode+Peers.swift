import Foundation
import NearbyCore

/// Peer table, pairwise sessions, path info, and the periodic prune.
extension NearbyNode {
    func makeSession(for record: PeerRecord) {
        do {
            sessions[record.id] = try PairwiseSession(
                identity: identity,
                remoteID: record.id,
                remoteAgreementPublicKey: record.agreementPublicKey
            )
        } catch {
            logger.error("session for \(record.id.description, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func upsertPeer(id: NodeID, name: String, lastSeen: Date) {
        let links = displayLinks(for: id)
        if let index = peers.firstIndex(where: { $0.id == id }) {
            peers[index].name = name
            peers[index].lastSeen = lastSeen
            if peers[index].links != links {
                peers[index].links = links
                logger.notice("peer \(name, privacy: .public) links \(links.map(\.description).joined(separator: " "), privacy: .public)")
            }
        } else {
            logger.notice("peer \(name, privacy: .public) links \(links.map(\.description).joined(separator: " "), privacy: .public)")
            peers.append(PeerSummary(id: id, name: name, lastSeen: lastSeen, links: links))
            sortPeers()
        }
    }

    private func sortPeers() {
        peers.sort { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }

    /// Stable order for the UI; `mesh.links(to:)` orders by live cost and would reshuffle every second.
    private func displayLinks(for id: NodeID) -> [LinkID] {
        mesh.links(to: id).sorted { $0.description < $1.description }
    }

    func rebuildPeerLinks() {
        for index in peers.indices { peers[index].links = displayLinks(for: peers[index].id) }
    }

    func refreshPaths(now: Date = Date()) {
        guard now.timeIntervalSince(lastPathRefresh) >= 0.25 else { return }
        recomputePaths(now: now)
    }

    private func recomputePaths(now: Date) {
        lastPathRefresh = now
        var info: [NodeID: PathInfo] = [:]
        for id in mesh.reachable() {
            let route = mesh.route(to: id)
            let nextLink = mesh.nextLink(to: id)
            let metrics = nextLink.flatMap { mesh.metrics(for: $0, now: now) }
            info[id] = PathInfo(
                hops: route?.hops ?? 1,
                costMs: route?.cost ?? metrics?.cost ?? 0,
                nextLink: nextLink,
                latencyMs: metrics?.latencyMs ?? 0,
                lossFraction: metrics?.lossFraction ?? 0,
                jitterMs: metrics?.jitterMs ?? 0
            )
        }
        for (id, path) in info where path.hops != pathInfo[id]?.hops || path.nextLink != pathInfo[id]?.nextLink {
            logger.notice("path to \(id.description, privacy: .public): \(path.hops) hops via \(path.nextLink?.description ?? "-", privacy: .public) cost \(Int(path.costMs)) ms")
        }
        pathInfo = info
    }

    func prune() {
        let now = Date()
        _ = mesh.expire(now: now)
        recomputePaths(now: now)
        peers.removeAll { now.timeIntervalSince($0.lastSeen) > Self.peerTimeout }
        evaluateHost()
        if rejoinRoom != nil, now > rejoinDeadline { rejoinRoom = nil }
        let currentRoom = (hosted?.id ?? joined?.id).map(String.init)
        if UserDefaults.standard.string(forKey: Self.rejoinKey) != currentRoom {
            UserDefaults.standard.set(currentRoom, forKey: Self.rejoinKey)
        }
        refreshRooms(now: now)
        guard inCall, let audio else { return }
        voiceStats = Dictionary(
            uniqueKeysWithValues: streamPeers.compactMap { id in audio.stats(for: id).map { (id, $0) } }
        )
        ioLatencyMs = audio.ioLatencyMs
    }

    func trustKeyChange() {
        guard let warning = keyWarning else { return }
        if let record = try? peerStore.trust(warning.hello, now: Date()) {
            makeSession(for: record)
            PeerStoreFile.save(peerStore)
        }
        keyWarning = nil
    }

    func dismissKeyWarning() {
        keyWarning = nil
    }
}

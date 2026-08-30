import Foundation
import NearbyCore

/// TURN allocations: when one is worth paying for, what happens once it is up, and how PRD R9 raises a
/// replacement before its ten-minute credentials lapse. Runs on the transport queue.
extension InternetTransport {
    // Every relay request spends a 10-minute grant of the node's allowance, so retries are paced.
    static var relayInterval: TimeInterval { 60 }
    /// A renewal spends another grant, so it is taken as late as the handover allows rather than at ttl/2.
    static var renewLead: TimeInterval { 90 }

    /// PRD R7/R9: only after the direct window fails do we pay for a TURN allocation.
    func startRelay(_ peer: NodeID, candidates: [Candidate]) {
        guard started, relays[peer] == nil, pendingRelay[peer] == nil, !hasLink(peer) else { return }
        guard Date().timeIntervalSince(lastRelayAttempt[peer] ?? .distantPast) >= Self.relayInterval else { return }
        lastRelayAttempt[peer] = Date()
        Task { [weak self, entitlement, hooks] in
            // Relay-only testing asks with no proof; only an ungated test Worker answers that.
            guard let jws = Self.relayOnly ? "" : await entitlement() else {
                return hooks.relayUnavailable(peer, "not entitled")
            }
            self?.queue.async { [weak self] in self?.requestRelay(peer, jws: jws, candidates: candidates) }
        }
    }

    func beginRelay(_ peer: NodeID, candidates: [Candidate], credentials: TURNCredentials, renewal: Bool) {
        // A first request must have no allocation yet; a renewal must have the one it replaces.
        guard started, (relays[peer] != nil) == renewal else { return }
        guard let client = try? TURNClient(credentials: credentials, queue: queue) else {
            return logger.error("no socket for relay to \(peer.description, privacy: .public)")
        }
        client.onRelayed = { [weak self] relayed in
            self?.relayReady(peer, relayed: relayed, candidates: candidates, renewal: renewal)
        }
        client.onData = { [weak self, weak client] payload, host, port in
            self?.deliver(payload, host: host, port: port, via: client)
        }
        client.onFailure = { [weak self, weak client] _ in
            guard let client else { return }
            self?.dropRelay(peer, only: client)
        }
        if renewal { retiring[peer] = relays[peer] }
        relays[peer] = client
        client.allocate()
        logger.notice("relay allocating for \(peer.description, privacy: .public)")
    }

    private func relayReady(_ peer: NodeID, relayed: (host: String, port: UInt16),
                            candidates: [Candidate], renewal: Bool) {
        guard let client = relays[peer] else { return }
        // The relay drops anything from an address it has no permission for (RFC 8656 §9).
        // The relay can only reach the peer's public addresses, and Cloudflare refuses private ones outright.
        for host in Set(candidates.map(\.host)) where Self.isPublic(host) { client.permit(host: host) }
        // The offer carries only the new allocation. The peer needs the replaced address solely to keep
        // a link it already has, and an inbound datagram is matched against existing links before it is
        // ever looked up in the candidate list.
        if let task = rooms[peer] { finishOffer(task, peer: peer, candidates: offerCandidates(peer)) }
        scheduleRenewal(peer, client: client)
        // A renewal must not punch: the call keeps flowing through the replaced allocation until the
        // peer's punch through this one proves it.
        guard !renewal else { return }
        startPunch(peer, candidates: candidates)
    }

    /// RFC 8656 §7.2 refuses a Refresh whose username differs from the allocation's, so fresh credentials
    /// mean a second allocation rather than a password swap; it is raised before the first one lapses.
    private func scheduleRenewal(_ peer: NodeID, client: TURNClient) {
        let lead = client.credentials.ttl - Self.renewLead
        guard lead > 0 else { return }
        queue.asyncAfter(deadline: .now() + lead) { [weak self, weak client] in
            // A stale timer names an allocation that is no longer the peer's current one.
            guard let self, let client, relays[peer] === client else { return }
            renewRelay(peer)
        }
    }

    /// Deliberate rather than a retry, so it skips the pacing guard `startRelay` applies.
    private func renewRelay(_ peer: NodeID) {
        guard pendingRelay[peer] == nil, retiring[peer] == nil,
              let candidates = relayedPeerCandidates(peer)
        else { return }
        logger.notice("relay renewing for \(peer.description, privacy: .public)")
        Task { [weak self, entitlement, logger] in
            let asked = Date()
            guard let jws = Self.relayOnly ? "" : await entitlement() else { return }
            logger.notice("entitlement took \(Int(Date().timeIntervalSince(asked) * 1000)) ms")
            self?.queue.async { [weak self] in
                self?.requestRelay(peer, jws: jws, candidates: candidates, renewal: true)
            }
        }
    }

    /// A retiring allocation failing is expected once the peer has moved off it; only the current one
    /// takes the peer's relayed link with it. Naming no client drops both.
    func dropRelay(_ peer: NodeID, only client: TURNClient? = nil) {
        if client == nil || retiring[peer] === client { retiring.removeValue(forKey: peer)?.close() }
        if client == nil || relays[peer] === client { relays.removeValue(forKey: peer)?.close() }
    }

    static func isPublic(_ host: String) -> Bool {
        if host.contains(":") { return !(host.hasPrefix("fe80") || host.hasPrefix("fd") || host.hasPrefix("fc") || host == "::1") }
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        let (a, b) = (parts[0], parts[1])
        // RFC 1918, CGNAT 100.64/10, link-local, loopback and the 464XLAT prefix are all unreachable from a relay.
        if a == 10 || a == 127 || (a == 169 && b == 254) || (a == 192 && b == 168) || (a == 192 && b == 0) { return false }
        if (a == 172 && (16...31).contains(b)) || (a == 100 && (64...127).contains(b)) { return false }
        return true
    }
}

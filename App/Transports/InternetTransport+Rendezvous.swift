import Foundation
import NearbyCore

/// The pair-room half of InternetTransport: challenge/auth, the candidate offer, and the relay
/// request the Worker answers with TURN credentials. Runs on the transport queue.
extension InternetTransport {
    func handleFrame(_ text: String, peer: NodeID, task: URLSessionWebSocketTask) {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = json["t"] as? String
        else { return }
        switch type {
        case "challenge":
            guard let nonce = (json["nonce"] as? String).flatMap(Self.unhex) else { return }
            nonces[peer] = nonce
            sendAuth(task, peer: peer, nonce: nonce)
        case "ok":
            logger.notice("auth ok \(peer.description, privacy: .public)")
            sendOffer(task, peer: peer)
            if let pending = pendingRelay[peer] { sendRelayFrame(peer, jws: pending.jws) }
        case "offer":
            receiveOffer(json, peer: peer)
        case "relay":
            receiveRelay(json, peer: peer)
        default:
            break
        }
    }

    func sendAuth(_ task: URLSessionWebSocketTask, peer: NodeID, nonce: Data) {
        let room = PairRoom.name(identity.nodeID, peer)
        guard let signature = try? PairRoom.authSignature(identity: identity, nonce: nonce, room: room) else { return }
        send([
            "t": "auth",
            "nodeID": identity.nodeID.description,
            "peerID": peer.description,
            "signingKey": identity.signingPublicKey.base64EncodedString(),
            "sig": signature.base64EncodedString(),
        ], on: task)
    }

    func sendOffer(_ task: URLSessionWebSocketTask, peer: NodeID) {
        guard let probe, !offered.contains(peer) else { return }
        offered.insert(peer)
        Task { [weak self, logger] in
            let gathered = (try? await probe.gatherCandidates()) ?? []
            if gathered.isEmpty { logger.error("gather failed for \(peer.description, privacy: .public)") }
            let candidates = gathered.isEmpty ? probe.hostAddresses() : gathered
            guard let self else { return }
            queue.async { [weak self] in self?.finishOffer(task, peer: peer, candidates: candidates) }
        }
    }

    func finishOffer(_ task: URLSessionWebSocketTask, peer: NodeID, candidates: [Candidate]) {
        guard rooms[peer] === task else { return }
        guard !candidates.isEmpty else {
            logger.error("no candidates for \(peer.description, privacy: .public)")
            closeRoom(peer)
            return retryLater(peer)
        }
        let timestampMs = UInt64(Date().timeIntervalSince1970 * 1000)
        // The name is irrelevant here; the beacon Hello over the punched link supplies the real one.
        guard let hello = try? Hello(identity: identity, name: "", timestampMs: timestampMs),
              let encoded = try? hello.encode()
        else { return }
        mine[peer] = candidates.filter { $0.kind != .relay }
        send(["t": "offer", "hello": encoded.base64EncodedString(), "candidates": candidates.map(\.text)], on: task)
        logger.notice("offer sent to \(peer.description, privacy: .public), \(candidates.count) candidates")
    }

    func receiveOffer(_ json: [String: Any], peer: NodeID) {
        guard let encoded = (json["hello"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let hello = try? Hello.decode(encoded), hello.verify(), hello.nodeID == peer
        else { return logger.error("bad offer from \(peer.description, privacy: .public)") }
        let candidates = ((json["candidates"] as? [String]) ?? []).compactMap(Candidate.init(text:))
        guard !candidates.isEmpty else { return }
        logger.notice("offer from \(peer.description, privacy: .public): \(candidates.map(\.text).joined(separator: " "), privacy: .public)")
        startPunch(peer, candidates: candidates)
    }

    // MARK: - Relay request

    /// PRD R2–R5: the Worker mints credentials only for a JWS that proves a subscription or a beta build.
    func requestRelay(_ peer: NodeID, jws: String, candidates: [Candidate]) {
        guard started, relays[peer] == nil, pendingRelay[peer] == nil else { return }
        pendingRelay[peer] = (jws, candidates, nil)
        // Before "ok" the room reads any frame as the auth message, so a fresh socket waits for it.
        guard rooms[peer] != nil, offered.contains(peer) else { return dial(peer) }
        sendRelayFrame(peer, jws: jws)
    }

    /// The proof is bound to this room's nonce, so it is built per socket: a reconnect re-signs.
    private func sendRelayFrame(_ peer: NodeID, jws: String) {
        guard let nonce = nonces[peer] else { return }
        Task { [weak self, hooks] in
            let proof = await hooks.attest(jws, nonce)
            self?.queue.async { [weak self] in self?.sendRelayRequest(peer, jws: jws, proof: proof) }
        }
    }

    /// Without a proof (Simulator, unsupported device) the Worker refuses with "attestation
    /// required"; the frame is still sent so the rest of the path stays exercised.
    private func sendRelayRequest(_ peer: NodeID, jws: String, proof: RelayProof?) {
        guard let task = rooms[peer], pendingRelay[peer] != nil else { return }
        pendingRelay[peer]?.proof = proof
        var frame: [String: Any] = ["t": "relay", "entitlement": jws]
        if let proof {
            frame["keyId"] = proof.keyID
            frame["assertion"] = proof.assertion.base64EncodedString()
            if let attestation = proof.attestation { frame["attestation"] = attestation.base64EncodedString() }
        }
        send(frame, on: task)
    }

    func receiveRelay(_ json: [String: Any], peer: NodeID) {
        guard let pending = pendingRelay.removeValue(forKey: peer) else { return }
        guard json["ok"] as? Bool == true, let credentials = Self.credentials(json["turn"]) else {
            let reason = json["reason"] as? String ?? "malformed"
            logger.error("relay refused for \(peer.description, privacy: .public): \(reason, privacy: .public)")
            // The Worker will never accept this key again; drop it rather than retry into a loop.
            if reason == "attestation required", pending.proof != nil { hooks.attestationRejected() }
            return
        }
        if let proof = pending.proof, proof.attestation != nil { hooks.attestationAccepted(proof.keyID) }
        beginRelay(peer, candidates: pending.candidates, credentials: credentials)
    }

    private static func credentials(_ turn: Any?) -> TURNCredentials? {
        guard let turn = turn as? [String: Any],
              let host = turn["host"] as? String,
              let port = (turn["port"] as? Int).flatMap(UInt16.init(exactly:)),
              let username = turn["username"] as? String,
              let credential = turn["credential"] as? String,
              let ttl = turn["ttl"] as? Int
        else { return nil }
        return TURNCredentials(server: (host, port), username: username,
                               password: credential, ttl: TimeInterval(ttl))
    }
}

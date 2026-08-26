import Foundation
import NearbyCore

/// The call: audio engine lifetime, per-member streams, and voice packets.
extension NearbyNode {
    /// In a call with other members, none of them reachable.
    var disconnected: Bool {
        let others = currentMembers.filter { $0.id != nodeID }
        return inCall && !others.isEmpty && !others.contains { member in peers.contains { $0.id == member.id } }
    }

    var currentMembers: [Member] { hosted?.members ?? joined?.members ?? [] }

    /// Headline for the current call, shared by the main screen and the Live Activity.
    var callTitle: String {
        if disconnected { return "Connection lost" }
        if muted { return "You're muted" }
        if !inCall { return "Setting up audio…" }
        let others = currentMembers.filter { $0.id != nodeID }
        switch others.count {
        case 0: return "Waiting for people"
        case 1: return "Talking with \(others[0].name)"
        default: return "Talking with \(others.count) people"
        }
    }

    func toggleMute() { muted.toggle() }

    func syncRoomKey() {
        roomKey = (hosted?.roomKey ?? joined?.roomKey).flatMap { try? RoomKey(data: $0) }
    }

    func startCall() {
        if audio == nil {
            // An AsyncStream keeps frames in capture order; a Task per frame would let the main actor
            // stamp sequence numbers out of order, and the receiver would drop the reordered frames.
            let (frames, continuation) = AsyncStream.makeStream(of: Data.self)
            audio = AudioEngine { frame in continuation.yield(frame) }
            outgoingVoice = Task { @MainActor [weak self] in
                for await frame in frames { self?.sendVoice(frame) }
            }
        }
        guard let audio else { return }
        audio.jitterTargetDepth = jitterTargetDepth
        do {
            try audio.start()
        } catch {
            // Kept alive on failure so a route change can retry through the engine's own observers.
            logger.error("audio start failed: \(error.localizedDescription, privacy: .public)")
        }
        inCall = true
        ioLatencyMs = audio.ioLatencyMs
        syncStreams()
    }

    func stopCall() {
        outgoingVoice?.cancel()
        outgoingVoice = nil
        // Engine teardown takes a noticeable moment; the UI must not wait for it.
        if let audio {
            Task.detached(priority: .userInitiated) { audio.stop() }
        }
        audio = nil
        inCall = false
        voiceStats = [:]
        streamPeers = []
        roomKey = nil
    }

    func syncStreams() {
        let wanted = Set(currentMembers.map(\.id)).subtracting([nodeID])
        for id in wanted.subtracting(streamPeers) { audio?.addStream(id) }
        for id in streamPeers.subtracting(wanted) { audio?.removeStream(id) }
        streamPeers = wanted
    }

    private func nextVoiceSequence(for member: NodeID) -> UInt32 {
        let next = (voiceSequences[member] ?? UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970 * 50))) &+ 1
        voiceSequences[member] = next
        return next
    }

    /// A second path when the primary is lossy enough to justify the duplicate airtime.
    private func multipathLink(alongside link: LinkID, to member: NodeID, now: Date) -> LinkID? {
        guard let loss = mesh.metrics(for: link, now: now)?.lossFraction,
              loss > multipathLossThreshold
        else { return nil }
        guard let alternate = mesh.alternateLink(to: member), alternate != link else { return nil }
        return alternate
    }

    /// One sealed copy per member: a relay must not dedup-drop the copy addressed to a different member, so each copy carries its own sequence.
    private func sendVoice(_ frame: Data) {
        guard inCall, !muted, let roomKey else { return }
        let now = Date()
        for member in currentMembers where member.id != nodeID {
            guard let link = mesh.nextLink(to: member.id) else { continue }
            let header = PacketHeader(
                type: .voice, source: nodeID, destination: member.id,
                stream: 1, sequence: nextVoiceSequence(for: member.id)
            )
            guard let sealed = try? roomKey.seal(frame, header: header) else { continue }
            let data = Packet(header: header, payload: sealed).encode()
            transmit(data, over: link)
            if let alternate = multipathLink(alongside: link, to: member.id, now: now) {
                transmit(data, over: alternate)
            }
        }
    }

    func receiveVoice(_ packet: Packet) {
        let header = packet.header
        guard inCall, let roomKey, currentMembers.contains(where: { $0.id == header.source })
        else { return }
        // Silent drop covers the rotation window where the sender still holds the previous room key.
        guard let frame = try? roomKey.open(packet.payload, header: header) else { return }
        audio?.push(header.source, sequence: header.sequence, frame: frame)
    }
}

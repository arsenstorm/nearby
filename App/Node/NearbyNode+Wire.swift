import Foundation
import NearbyCore

/// Packets on the wire: encoding, sending, flooding, forwarding, probes, and link-state gossip.
extension NearbyNode {
    // MARK: - Sending

    private func nextSequence() -> UInt32 {
        sequence &+= 1
        return sequence
    }

    private var sendableLinks: [LinkID] {
        mesh.allLinks.filter { transportStates[$0.transport].map { $0.enabled && $0.active } ?? false }
    }

    func transmit(_ data: Data, over link: LinkID) {
        guard let transport = transports[link.transport] else { return }
        packetCounters.sent += 1
        Task { try? await transport.send(data, over: link) }
    }

    func broadcastControl(_ message: ControlMessage) {
        let header = PacketHeader(
            type: .control, source: nodeID, destination: .broadcast,
            stream: 0, sequence: nextSequence()
        )
        guard let payload = try? message.encode() else { return }
        let data = Packet(header: header, payload: payload).encode()
        for link in sendableLinks { transmit(data, over: link) }
    }

    func sendControl(_ message: ControlMessage, to destination: NodeID) {
        let header = PacketHeader(
            type: .control, source: nodeID, destination: destination,
            stream: 0, sequence: nextSequence()
        )
        guard let session = sessions[destination] else {
            logger.error("no session for \(destination.description, privacy: .public), dropping control")
            return
        }
        guard let plaintext = try? message.encode(),
              let sealed = try? session.seal(plaintext, header: header)
        else {
            logger.error("failed to seal control for \(destination.description, privacy: .public)")
            return
        }
        guard let link = mesh.nextLink(to: destination) else {
            logger.error("no route to \(destination.description, privacy: .public), dropping control")
            return
        }
        let data = Packet(header: header, payload: sealed).encode()
        transmit(data, over: link)
        if let alternate = mesh.alternateLink(to: destination), alternate != link {
            transmit(data, over: alternate)
        }
    }

    private func helloPacket() -> Data? {
        let header = PacketHeader(
            type: .hello, source: nodeID, destination: .broadcast,
            stream: 0, sequence: nextSequence()
        )
        let timestampMs = UInt64(Date().timeIntervalSince1970 * 1000)
        guard let hello = try? Hello(identity: identity, name: displayName, timestampMs: timestampMs),
              let payload = try? hello.encode()
        else {
            logger.error("failed to build hello")
            return nil
        }
        return Packet(header: header, payload: payload).encode()
    }

    func broadcastHello() {
        let links = sendableLinks
        guard !links.isEmpty, let data = helloPacket() else { return }
        for link in links { transmit(data, over: link) }
    }

    private func probePayload(kind: UInt8, sequence: UInt32) -> Data {
        Data([kind]) + withUnsafeBytes(of: sequence.bigEndian) { Data($0) }
    }

    private func sendProbe(kind: UInt8, sequence: UInt32, on link: LinkID, to destination: NodeID) {
        let header = PacketHeader(
            type: .probe, source: nodeID, destination: destination,
            stream: 0, sequence: nextSequence(), ttl: 1
        )
        let packet = Packet(header: header, payload: probePayload(kind: kind, sequence: sequence))
        transmit(packet.encode(), over: link)
    }

    func sendProbes() {
        let now = Date()
        for link in mesh.allLinks {
            probeSequence &+= 1
            mesh.probeSent(on: link, sequence: probeSequence, at: now)
            sendProbe(kind: 0, sequence: probeSequence, on: link, to: mesh.node(for: link) ?? .broadcast)
        }
        mesh.expireProbes(now: now)
    }

    func broadcastLinkState() {
        let now = Date()
        lastAdvertisement = now
        let lsa = mesh.localAdvertisement(now: now)
        guard let payload = try? lsa.encode() else { return }
        let header = PacketHeader(
            type: .linkState, source: nodeID, destination: .broadcast,
            stream: 0, sequence: nextSequence()
        )
        let data = Packet(header: header, payload: payload).encode()
        for link in sendableLinks { transmit(data, over: link) }
        refreshPaths(now: now)
    }

    /// Event-driven advertisements are capped so a flapping link cannot flood the mesh.
    func advertiseLinkState() {
        guard Date().timeIntervalSince(lastAdvertisement) >= 0.25 else { return }
        broadcastLinkState()
    }

    // MARK: - Receiving

    func handle(_ event: TransportEvent) {
        switch event {
        case .linkUp(let link):
            mesh.linkUp(link, bandwidthKbps: link.transport == .ble ? 100 : 10_000, now: Date())
            transportStates[link.transport]?.linkCount += 1
            if let data = helloPacket() { transmit(data, over: link) }
            advertiseLinkState()
        case .linkDown(let link):
            mesh.linkDown(link, now: Date())
            if let count = transportStates[link.transport]?.linkCount {
                transportStates[link.transport]?.linkCount = max(0, count - 1)
            }
            rebuildPeerLinks()
            refreshPaths()
            advertiseLinkState()
        case .received(let data, let link):
            receive(data, from: link)
        }
    }

    private func receive(_ data: Data, from link: LinkID) {
        guard let packet = Packet(decoding: data) else { return }
        let header = packet.header
        guard header.source != nodeID else { return }
        packetCounters.received += 1
        guard dedup.check(source: header.source, destination: header.destination, stream: header.stream, sequence: header.sequence)
        else {
            packetCounters.droppedDedup += 1
            return
        }
        let now = Date()

        switch header.type {
        case .hello:
            receiveHello(packet.payload, from: link, direct: header.ttl == PacketHeader.initialTTL)
            if header.ttl > 1 { flood(packet, from: link) }
        case .probe:
            receiveProbe(packet, from: link, now: now)
        case .linkState:
            guard let lsa = try? LinkStateAdvertisement.decode(packet.payload),
                  mesh.apply(lsa, now: now)
            else { return }
            if header.ttl > 1 { flood(packet, from: link) }
            refreshPaths(now: now)
        case .control where header.destination == .broadcast:
            receiveControl(packet)
            if header.ttl > 1 { flood(packet, from: link) }
        case .control, .voice:
            receiveUnicast(packet)
        case .ack:
            break
        }
    }

    private func receiveUnicast(_ packet: Packet) {
        let header = packet.header
        if header.destination != nodeID {
            if header.ttl > 1 { forward(packet) } else { packetCounters.droppedTTL += 1 }
        } else if header.type == .control {
            receiveControl(packet)
        } else {
            receiveVoice(packet)
        }
    }

    private func flood(_ packet: Packet, from link: LinkID) {
        var header = packet.header
        header.ttl -= 1
        let data = Packet(header: header, payload: packet.payload).encode()
        for out in sendableLinks where out != link {
            transmit(data, over: out)
            packetCounters.relayed += 1
        }
    }

    private func forward(_ packet: Packet) {
        guard let link = mesh.nextLink(to: packet.header.destination) else { return }
        var header = packet.header
        header.ttl -= 1
        transmit(Packet(header: header, payload: packet.payload).encode(), over: link)
        packetCounters.relayed += 1
    }

    private func receiveProbe(_ packet: Packet, from link: LinkID, now: Date) {
        let payload = [UInt8](packet.payload)
        guard payload.count >= 5 else { return }
        let sequence = payload[1...4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        if payload[0] == 0 {
            sendProbe(kind: 1, sequence: sequence, on: link, to: packet.header.source)
        } else {
            _ = mesh.probeReply(on: link, sequence: sequence, at: now)
        }
    }

    private func receiveHello(_ payload: Data, from link: LinkID, direct: Bool) {
        guard let hello = try? Hello.decode(payload) else { return }
        let now = Date()
        let before = peerStore.record(for: hello.nodeID)
        let record: PeerRecord
        do {
            record = try peerStore.observe(hello, now: now)
        } catch PeerStoreError.keyChanged(let existing) {
            if keyWarning == nil { keyWarning = PeerKeyWarning(hello: hello, existing: existing) }
            return
        } catch {
            logger.error("hello from \(hello.nodeID.description, privacy: .public) failed verification")
            return
        }
        if direct {
            let unbound = mesh.node(for: link) == nil
            mesh.bind(link, to: hello.nodeID)
            if unbound { advertiseLinkState() }
        }
        if sessions[hello.nodeID] == nil { makeSession(for: record) }
        upsertPeer(id: record.id, name: record.name, lastSeen: now)
        if before != record { PeerStoreFile.save(peerStore) }
    }

    private func receiveControl(_ packet: Packet) {
        let header = packet.header
        let plaintext: Data
        if header.destination == .broadcast {
            plaintext = packet.payload
        } else {
            guard let session = sessions[header.source],
                  let opened = try? session.open(packet.payload, header: header)
            else {
                logger.error("cannot open control from \(header.source.description, privacy: .public)")
                return
            }
            plaintext = opened
        }
        guard let message = try? ControlMessage.decode(plaintext) else { return }
        handle(message, from: header.source)
    }
}

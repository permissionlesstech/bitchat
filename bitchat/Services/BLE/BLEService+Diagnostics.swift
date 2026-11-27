import BitFoundation
import BitLogger
import Foundation

// MARK: - Mesh Diagnostics (/ping, /trace, topology map)

extension BLEService {
    /// Sends a directed unencrypted ping probe (8-byte nonce + origin TTL).
    /// The completion fires exactly once on the main actor: with RTT/hops
    /// when the matching pong returns, or nil after the timeout window.
    func sendMeshPing(to peerID: PeerID, completion: @escaping @MainActor (MeshPingResult?) -> Void) {
        guard let generation = capturePanicLifecycleGeneration() else {
            return
        }
        messageQueue.async { [weak self] in
            guard let self,
                  self.isCurrentPanicLifecycleGeneration(generation),
                  let recipientData = peerID.toShort().routingData,
                  let payload = MeshPingPayload(
                    nonce: Data((0..<MeshPingPayload.nonceLength).map { _ in UInt8.random(in: .min ... .max) }),
                    originTTL: self.messageTTL
                  ) else {
                self?.notifyUI { [weak self] in
                    guard let self,
                          self.isCurrentPanicLifecycleGeneration(generation) else {
                        return
                    }
                    completion(nil)
                }
                return
            }
            let nonce = payload.nonce
            let packet = BitchatPacket(
                type: MessageType.ping.rawValue,
                senderID: self.myPeerIDData,
                recipientID: recipientData,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: payload.encode(),
                signature: nil,
                ttl: self.messageTTL
            )
            let timeout = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let expired = onEngine {
                    self.meshPings.expire(nonce: nonce)
                }
                guard let expired else { return }
                self.notifyUI { [weak self] in
                    guard let self,
                          self.isCurrentPanicLifecycleGeneration(
                              expired.lifecycleGeneration
                          ) else {
                        return
                    }
                    expired.completion(nil)
                }
            }
            onEngine {
                self.meshPings.register(
                    BLEMeshPingProbe(
                        peerID: PeerID(hexData: recipientData),
                        sentAt: Date(),
                        lifecycleGeneration: generation,
                        completion: completion,
                        timeout: timeout
                    ),
                    nonce: nonce
                )
            }
            self.engineScheduler.schedule(
                after: TransportConfig.meshPingTimeoutSeconds,
                execute: timeout
            )
            self.broadcastPacket(packet)
        }
    }

    /// Answers a ping addressed to us with a pong echoing its nonce; pings
    /// addressed elsewhere are left to the generic directed-relay path.
    ///
    /// `linkPeerID` is the directly connected peer that delivered the packet
    /// (the ingress link), NOT the packet's claimed sender: pings are
    /// unsigned, so `packet.senderID` is attacker-controlled, and keying the
    /// response budget on it would let one connected peer rotate forged
    /// sender IDs to emit unbounded pongs. The budget is per physical link;
    /// the pong still goes to the claimed sender (that's the protocol).
    func handleMeshPing(_ packet: BitchatPacket, fromLink linkPeerID: PeerID) {
        guard packet.recipientID == myPeerIDData else { return }
        guard let ping = MeshPingPayload.decode(packet.payload) else {
            SecureLogger.debug("⚠️ Malformed ping via \(linkPeerID.id.prefix(8))…", category: .session)
            return
        }
        let allowed = onEngine {
            meshPings.shouldRespond(toLink: linkPeerID, now: Date())
        }
        guard allowed else {
            if logRateLimiter.shouldLog(key: "ping-limit:\(linkPeerID.id)") {
                SecureLogger.warning("🚫 Rate-limiting pings via link \(linkPeerID.id.prefix(8))…", category: .security)
            }
            return
        }
        guard let pong = MeshPingPayload(nonce: ping.nonce, originTTL: messageTTL) else { return }
        let reply = BitchatPacket(
            type: MessageType.pong.rawValue,
            senderID: myPeerIDData,
            recipientID: packet.senderID,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: pong.encode(),
            signature: nil,
            ttl: messageTTL
        )
        broadcastPacket(reply)
    }

    /// Resolves a pong against its outstanding probe. The unguessable echoed
    /// nonce plus the sender check bind the reply to the probed peer; hops
    /// come from the pong's TTL decrements on the return path.
    func handleMeshPong(_ packet: BitchatPacket, from peerID: PeerID) {
        guard packet.recipientID == myPeerIDData else { return }
        guard let pong = MeshPingPayload.decode(packet.payload) else { return }
        let pending = onEngine {
            meshPings.resolve(nonce: pong.nonce, from: peerID)
        }
        guard let pending else { return }
        pending.timeout.cancel()
        let rttMs = Int((Date().timeIntervalSince(pending.sentAt) * 1000).rounded())
        let result = MeshPingResult(
            rttMs: max(0, rttMs),
            hops: MeshPingPayload.hopCount(originTTL: pong.originTTL, receivedTTL: packet.ttl)
        )
        notifyUI { [weak self] in
            guard let self,
                  self.isCurrentPanicLifecycleGeneration(
                      pending.lifecycleGeneration
                  ) else {
                return
            }
            pending.completion(result)
        }
    }

    /// Estimated intermediate hops toward `peerID`, BFS over gossiped
    /// bidirectionally-confirmed neighbor claims ([] = direct, nil = none).
    func computeMeshPath(to peerID: PeerID) -> [PeerID]? {
        refreshLocalTopology()
        if let route = computeRoute(to: peerID) {
            return route.compactMap { PeerID(routingData: $0) }
        }
        // Confirmed claims can lag a brand-new link (the peer's next announce
        // hasn't arrived yet); a live direct connection is still a known path.
        return isPeerConnected(peerID) ? [] : nil
    }

    /// Mesh graph for the topology map. Edges are advisory: announces cap
    /// neighbor lists at 10, so an edge claimed by either endpoint counts.
    func currentMeshTopology() -> MeshTopologySnapshot? {
        refreshLocalTopology()
        let claims = meshTopology.adjacencySnapshot()
        var nodes = Set<PeerID>()
        var edges = Set<MeshTopologyEdge>()
        for (source, neighbors) in claims {
            guard let sourcePeer = PeerID(routingData: source) else { continue }
            nodes.insert(sourcePeer)
            for neighborData in neighbors {
                guard let neighborPeer = PeerID(routingData: neighborData),
                      neighborPeer != sourcePeer else { continue }
                nodes.insert(neighborPeer)
                edges.insert(MeshTopologyEdge(sourcePeer, neighborPeer))
            }
        }
        nodes.insert(myPeerID)
        return MeshTopologySnapshot(
            localPeerID: myPeerID,
            nodes: nodes.sorted(),
            edges: edges.sorted { ($0.a, $0.b) < ($1.a, $1.b) }
        )
    }

    func forwardAlongRouteIfNeeded(_ packet: BitchatPacket) -> Bool {
        let myRoutingData = routingData(for: myPeerID) ?? (myPeerIDData.isEmpty ? nil : myPeerIDData)
        let plan = BLERouteForwardingPolicy.plan(
            for: packet,
            localPeerID: myPeerID,
            localRoutingData: myRoutingData,
            routingPeer: routingPeer(from:),
            isPeerConnected: isPeerConnected(_:)
        )

        if let forwardPacket = plan.forwardPacket, let nextHop = plan.nextHop {
            sendPacketDirected(forwardPacket, to: nextHop)
        }

        return plan.shouldSuppressFloodRelay
    }
}

#if DEBUG
import BitFoundation
import CoreBluetooth
import Foundation

// Test-only helper to inject packets into the receive pipeline
extension BLEService {
    /// Queues an event through the same MainActor hop as production receive
    /// handlers so panic-boundary tests can deterministically invalidate it.
    func _test_emitTransportEvent(_ event: TransportEvent) {
        emitTransportEvent(event)
    }

    var _test_isPanicIngressOpen: Bool {
        capturePanicLifecycleGeneration() != nil
    }

    /// Queries the receipt store of the service's OWN incoming-file store —
    /// the instance production lookups run against — so panic tests exercise
    /// the real wiring instead of a same-instance shortcut.
    func _test_privateMediaReceiptState(
        messageID: String
    ) -> BLEPrivateMediaReceiptState {
        incomingFileStore.privateMediaReceiptState(messageID: messageID)
    }

    /// Models a CoreBluetooth delegate callback without requiring a physical
    /// peripheral. The callback itself runs on `bleQueue`, exactly where the
    /// panic radio-stop barrier must linearize it.
    func _test_handlePacketFromBLEQueue(
        _ packet: BitchatPacket,
        fromPeerID: PeerID
    ) {
        bleQueue.async { [weak self] in
            self?.handleReceivedPacket(packet, from: fromPeerID)
        }
    }

    /// Simulated-link ingress: the full production attribution path —
    /// binding lookup, spoof rejection, raw-announce binding, ingress
    /// recording — for a frame arriving on a synthetic link. The
    /// SimulatedMesh harness feeds every node through this, so multi-node
    /// tests exercise the same engine code as CoreBluetooth ingress.
    func _test_ingestFrame(_ packet: BitchatPacket, link: BLEIngressLinkID) {
        emitLinkEvent(.frameDecoded(packet, link: link, linkDescription: "Simulated \(link)"))
    }

    /// Sends an unthrottled announce, exactly like the maintenance forced
    /// path. SimulatedMesh uses this as the deterministic discovery step.
    func _test_forceAnnounce() {
        onEngine { sendAnnounceNow(forceSend: true) }
    }

    /// Clears the announce throttle's wall-clock debt — the simulator's
    /// stand-in for "enough real time has passed", since scheduler time
    /// cannot move the throttle's Date-based window. Deliberately NOT
    /// part of `_test_forceAnnounce`: the panic-rotation mesh test relies
    /// on the production panic path performing its own reset, and a
    /// blanket reset here would mask that regression.
    func _test_resetAnnounceThrottle() {
        announceThrottle.reset()
    }

    /// Blocks until every engine slot enqueued so far has run — the
    /// deterministic settling fence for simulated-mesh pumping.
    func _test_fenceEngine() {
        onEngine {}
    }

    func _test_emitTransportEvent(
        _ event: TransportEvent,
        completion: @escaping () -> Void,
        finalization: @escaping (TransportEventDeliveryOutcome) -> Void
    ) {
        emitTransportEvent(
            event,
            completion: completion,
            finalization: finalization
        )
    }

    func _test_handlePacket(_ packet: BitchatPacket, fromPeerID: PeerID, preseedPeer: Bool = true, signingPublicKey: Data? = nil) {
        if preseedPeer {
            // Ensure the synthetic peer is known and marked verified for public-message tests
            let normalizedID = PeerID(hexData: packet.senderID)
            peerRegistry.mutate { registry in
                if var existing = registry.info(for: normalizedID) {
                    existing.isConnected = true
                    existing.isVerifiedNickname = true
                    if let signingPublicKey { existing.signingPublicKey = signingPublicKey }
                    existing.lastSeen = Date()
                    registry.upsert(existing)
                } else {
                    registry.upsert(BLEPeerInfo(
                        peerID: normalizedID,
                        nickname: "TestPeer_\(fromPeerID.id.prefix(4))",
                        isConnected: true,
                        noisePublicKey: packet.senderID,
                        signingPublicKey: signingPublicKey,
                        isVerifiedNickname: true,
                        lastSeen: Date()
                    ))
                }
            }
        }
        handleReceivedPacket(packet, from: fromPeerID)
    }

    /// Waits until fragment ingress already submitted by a test has finished
    /// reassembly/reinjection and any resulting transport event has crossed
    /// the MainActor delivery hop. This is a deterministic pipeline fence,
    /// avoiding wall-clock sleeps that become flaky under a parallel suite.
    func _test_drainFragmentPipeline() async {
        await withCheckedContinuation { continuation in
            messageQueue.async {
                // Reassembled packets are reinjected synchronously on
                // `messageQueue`; their UI delivery task is therefore already
                // enqueued before this later MainActor marker.
                Task { @MainActor in
                    continuation.resume()
                }
            }
        }
    }

    /// Waits until work already submitted to `messageQueue`, `bleQueue`, and any
    /// resulting `MainActor` transport-event hops has completed. Lets negative
    /// assertions verify absence deterministically instead of sleeping for a
    /// fixed wall-clock window.
    func _test_drainAllPipelines() async {
        let messageQueue = self.messageQueue
        let bleQueue = self.bleQueue
        await withCheckedContinuation { continuation in
            messageQueue.async {
                bleQueue.async {
                    messageQueue.async {
                        Task { @MainActor in
                            continuation.resume()
                        }
                    }
                }
            }
        }
    }

    func _test_hasGossipPrekeyBundle(for peerID: PeerID) -> Bool {
        gossipSyncManager?._hasPrekeyBundle(for: peerID) ?? false
    }

    func _test_acceptsIngress(packet: BitchatPacket, boundPeerID: PeerID?) -> Bool {
        let claimedSenderID = PeerID(hexData: packet.senderID)
        guard case .success = BLEIngressLinkRegistry.packetContext(
            for: packet,
            claimedSenderID: claimedSenderID,
            boundPeerID: boundPeerID,
            localPeerID: myPeerID,
            directAnnounceTTL: messageTTL
        ) else {
            return false
        }
        return true
    }

    func _test_recordIngressIfNew(packet: BitchatPacket, linkID: String) -> Bool {
        recordIngressIfNew(
            messageID: BLEIngressLinkRegistry.messageID(for: packet),
            link: .central(linkID),
            peerID: PeerID(hexData: packet.senderID)
        )
    }

    func _test_bindCentral(_ centralUUID: String, to peerID: PeerID) {
        onEngine { linkBindings.bindCentral(centralUUID, to: peerID) }
    }

    func _test_centralBinding(_ centralUUID: String) -> PeerID? {
        onEngine { linkBindings.peer(forCentralUUID: centralUUID) }
    }

    func _test_linkBinding(_ link: BLEIngressLinkID) -> PeerID? {
        onEngine { linkBindings.boundPeer(for: link) }
    }

    func _test_knownPeerIDs() -> [PeerID] {
        peerRegistry.peerIDs
    }

    func _test_markNoiseAuthenticatedCentral(_ centralUUID: String, to peerID: PeerID) {
        onEngine {
            guard linkBindings.peer(forCentralUUID: centralUUID) == peerID else { return }
            linkAuth.markAuthenticated(.central(centralUUID), owner: peerID)
        }
    }

    func _test_isNoiseAuthenticatedCentral(_ centralUUID: String, for peerID: PeerID) -> Bool {
        onEngine {
            linkAuth.isAuthenticated(.central(centralUUID), for: peerID)
        }
    }

    func _test_seedConnectedPeer(
        _ peerID: PeerID,
        nickname: String,
        capabilities: PeerCapabilities? = nil,
        noisePublicKey: Data? = nil
    ) {
        peerRegistry.mutate {
            $0.upsert(BLEPeerInfo(
                peerID: peerID,
                nickname: nickname,
                isConnected: true,
                noisePublicKey: noisePublicKey,
                signingPublicKey: nil,
                isVerifiedNickname: true,
                lastSeen: Date(),
                capabilities: capabilities ?? []
            ))
        }
    }

    /// Handshake plumbing for tests that need a real established Noise
    /// session (e.g. canDeliverSecurely) without Bluetooth in the loop.
    func _test_noiseInitiateHandshake(with peerID: PeerID) throws -> Data {
        try noiseService.initiateHandshake(with: peerID)
    }

    func _test_noiseProcessHandshakeMessage(from peerID: PeerID, message: Data) throws -> Data? {
        try noiseService.processHandshakeMessage(from: peerID, message: message)
    }

    func _test_enqueuePendingPrivateMessage(
        content: String,
        messageID: String,
        for peerID: PeerID
    ) {
        onEngine {
            pendingNoiseSessionQueues.appendPrivateMessage(
                content: content,
                messageID: messageID,
                for: peerID
            )
        }
    }

    func _test_enqueuePendingNoisePayload(
        _ payload: Data,
        transferId: String,
        for peerID: PeerID
    ) {
        guard privateMediaTransferAdmissions.begin(transferId) == .admitted else { return }
        onEngine {
            pendingNoiseSessionQueues.appendTypedPayload(
                payload,
                transferId: transferId,
                for: peerID
            )
        }
    }

    func _test_sendPendingNoisePayloadsAfterHandshake(for peerID: PeerID) {
        sendPendingNoisePayloadsAfterHandshake(for: peerID)
    }

    func _test_hasPendingPrivateMediaPolicyResolution(for peerID: PeerID) -> Bool {
        privateMediaSessions.hasPendingPolicyResolution(for: peerID.toShort())
    }

    func _test_forcePrivateMediaProofTimeout(for peerID: PeerID) {
        let normalizedPeerID = peerID.toShort()
        let target = privateMediaSessions.proofTimeoutTarget(for: normalizedPeerID)
        guard let target else { return }
        handlePrivateMediaProofTimeout(
            for: normalizedPeerID,
            fingerprint: target.fingerprint,
            sessionGeneration: target.generation,
            nonce: target.nonce
        )
    }

    func _test_privateMediaTransferState(
        transferId: String
    ) -> (admissionActive: Bool, pendingNoise: Bool, activeScheduler: Int, pendingScheduler: Int) {
        let scheduler = onEngine {
            (
                pendingNoiseSessionQueues.containsTypedPayload(transferId: transferId),
                outboundFragmentTransfers.activeCount,
                outboundFragmentTransfers.pendingCount
            )
        }
        return (
            privateMediaTransferAdmissions.isActive(transferId),
            scheduler.0,
            scheduler.1,
            scheduler.2
        )
    }

    func _test_privateMediaAdmissionEntryCount() -> Int {
        privateMediaTransferAdmissions.count
    }

    @discardableResult
    func _test_beginPrivateMediaAdmission(_ transferId: String, now: Date) -> Bool {
        privateMediaTransferAdmissions.begin(transferId, now: now) == .admitted
    }

    func _test_isPrivateMediaAdmissionActive(_ transferId: String, now: Date) -> Bool {
        privateMediaTransferAdmissions.isActive(transferId, now: now)
    }

    func _test_finishPrivateMediaAdmission(_ transferId: String) {
        privateMediaTransferAdmissions.finish(transferId)
    }

    func _test_drainPrivateMediaSendPipeline() async {
        // Capture only the (Sendable) queue, not self, so the @Sendable
        // dispatch closures carry no non-Sendable state.
        let queue = messageQueue
        await withCheckedContinuation { continuation in
            queue.async {
                queue.async {
                    continuation.resume()
                }
            }
        }
    }

    func _test_broadcastPrivateMediaPacket(
        _ packet: BitchatPacket,
        transferId: String
    ) {
        broadcastPacket(
            packet,
            transferId: transferId,
            requiresPrivateMediaAdmission: true
        )
    }

    func _test_drainNoiseMessagePipeline() async {
        await _test_drainPrivateMediaSendPipeline()
    }

    /// Replays the current generation's ready callback. Restore tests use
    /// this to prove same-generation reconciliation is idempotent.
    func _test_reconcileCurrentNoiseSession(for peerID: PeerID) {
        let normalizedPeerID = peerID.toShort()
        messageQueue.async { [weak self] in
            guard let self,
                  let generation = self.noiseService.sessionGeneration(
                    for: normalizedPeerID
                  ),
                  let fingerprint = self.noiseService.getPeerFingerprint(
                    normalizedPeerID
                  ) else {
                return
            }
            self.handleNoisePeerAuthenticated(
                peerID: normalizedPeerID,
                fingerprint: fingerprint,
                sessionGeneration: generation
            )
        }
    }

    /// Builds an authenticated-session packet from an exact typed plaintext.
    /// Compatibility tests use this to model Android's deployed 0x20 file
    /// payload and the short-lived 0x09 prerelease payload without exposing a
    /// production API that can emit the old value.
    func _test_makeEncryptedNoisePacket(_ typedPayload: Data, to peerID: PeerID) throws -> BitchatPacket {
        try makeEncryptedNoisePacket(typedPayload, to: peerID)
    }

    static func _test_shouldRediscoverBitChatService(
        invalidatedServiceUUIDs: [CBUUID],
        cachedServiceUUIDs: [CBUUID]?
    ) -> Bool {
        shouldRediscoverBitChatService(
            invalidatedServiceUUIDs: invalidatedServiceUUIDs,
            cachedServiceUUIDs: cachedServiceUUIDs
        )
    }
}
#endif

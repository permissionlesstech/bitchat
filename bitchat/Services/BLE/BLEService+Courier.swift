import BitFoundation
import BitLogger
import Foundation

// MARK: - Courier Store-and-Forward, Prekey Bundles & Gateway Carrier

extension BLEService {
    // MARK: Courier Store-and-Forward

    /// Seal `content` for the recipient and hand the envelope to the given
    /// couriers for physical delivery. When a verified one-time prekey bundle
    /// is cached for the recipient, sealing targets one of its prekeys
    /// (forward secret, envelope v2); otherwise it falls back to their static
    /// key (one-way Noise X, v1) exactly as before. Returns false when no
    /// courier is connected, the payload cannot be built, or sealing fails;
    /// link writes are queued asynchronously after the envelope is ready.
    private func sealCourierEnvelope(
        _ content: String,
        messageID: String,
        recipientNoiseKey: Data,
        copies: UInt8
    ) -> CourierEnvelope? {
        guard let typedPayload = BLENoisePayloadFactory.privateMessage(content: content, messageID: messageID) else {
            return nil
        }
        do {
            let now = Date()
            let sealed: Data
            let prekeyID: UInt32?
            if let prekey = assignRecipientPrekey(messageID: messageID, recipientNoiseKey: recipientNoiseKey) {
                sealed = try noiseService.sealPrekeyPayload(typedPayload, recipientPrekey: prekey)
                prekeyID = prekey.id
            } else {
                sealed = try noiseService.sealCourierPayload(typedPayload, recipientStaticKey: recipientNoiseKey)
                prekeyID = nil
            }
            return CourierEnvelope(
                recipientTag: CourierEnvelope.recipientTag(
                    noiseStaticKey: recipientNoiseKey,
                    epochDay: CourierEnvelope.epochDay(for: now)
                ),
                expiry: UInt64((now.timeIntervalSince1970 + CourierEnvelope.maxLifetimeSeconds) * 1000),
                ciphertext: sealed,
                copies: copies,
                prekeyID: prekeyID
            )
        } catch {
            SecureLogger.error("Failed to seal courier envelope: \(error)", category: .encryption)
            return nil
        }
    }

    func sendCourierMessage(_ content: String, messageID: String, recipientNoiseKey: Data, via couriers: [PeerID]) -> Bool {
        let connected = couriers.filter { isPeerConnected($0) }
        guard !connected.isEmpty,
              let envelope = sealCourierEnvelope(
                content,
                messageID: messageID,
                recipientNoiseKey: recipientNoiseKey,
                copies: TransportConfig.courierInitialCopies
              ),
              let payload = envelope.encode() else {
            return false
        }

        messageQueue.async { [weak self] in
            guard let self else { return }
            for courier in connected {
                SecureLogger.debug("📦 Depositing courier envelope with \(courier.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
                self.sendPacketDirected(self.makeCourierPacket(payload, to: courier), to: courier)
            }
        }
        return true
    }

    // MARK: Courier over the bridge

    /// Seals `content` into a courier envelope for relay parking (a bridge
    /// courier drop). Same sealing rules as `sendCourierMessage` — prekey
    /// (v2) when a verified bundle is cached, static Noise X (v1) otherwise —
    /// but carry-only: a relay copy never sprays.
    func sealBridgeCourierEnvelope(_ content: String, messageID: String, recipientNoiseKey: Data) -> CourierEnvelope? {
        sealCourierEnvelope(content, messageID: messageID, recipientNoiseKey: recipientNoiseKey, copies: 1)
    }

    /// Opens a courier envelope that arrived as a bridge drop (relay fetch,
    /// not a directed mesh packet). Returns false when the rotating tag does
    /// not match our static key — a drop for someone else, or a stale tag.
    /// The inner Noise X seal authenticates the sender; there is no packet
    /// signature to check on this path.
    @discardableResult
    func openBridgedCourierEnvelope(_ envelope: CourierEnvelope) -> Bool {
        guard !envelope.isExpired else { return false }
        let myKey = noiseService.getStaticPublicKeyData()
        guard CourierEnvelope.candidateTags(noiseStaticKey: myKey, around: Date()).contains(envelope.recipientTag) else {
            return false
        }
        return openCourierEnvelope(envelope)
    }

    /// Hands a bridge-fetched envelope directly to the matching local peer
    /// as a directed courier packet. Delivery-only by design: the recipient's
    /// tag matched, so this never lands in a stranger's carry quota.
    /// Returns true only if a current Noise-authenticated physical link
    /// accepted the packet; a stale peer-level session, reachability record,
    /// replay-rebound link, or process-local spool is not delivery.
    @discardableResult
    func deliverBridgedEnvelope(_ envelope: CourierEnvelope, to peerID: PeerID) -> Bool {
        guard let payload = envelope.encode() else { return false }
        let packet = makeCourierPacket(payload, to: peerID)
        return onEngine {
            // Engine slot: the auth-link check and the directed send see one
            // consistent view of the identity domain.
            guard hasCurrentNoiseAuthenticatedLink(to: peerID) else { return false }
            return sendPacketDirected(
                packet,
                to: peerID,
                requireDirectPeerLink: true,
                requireNoiseAuthenticatedPeerLink: true
            )
        }
    }

    /// Verified reachable peers with known Noise keys — the set a bridge
    /// gateway watches courier drops for.
    func verifiedPeersWithNoiseKeys() -> [(peerID: PeerID, noiseKey: Data)] {
        let now = Date()
        return onEngine {
            peerRegistry.snapshotByID.values.compactMap { info in
                guard info.isVerifiedNickname,
                      let key = info.noisePublicKey,
                      peerRegistry.isReachable(info.peerID, now: now) else { return nil }
                return (info.peerID, key)
            }
        }
    }

    /// The prekey to seal a courier message with, or nil to fall back to
    /// static sealing. The real signal is a verified, unexpired bundle with a
    /// spare prekey; the advertised `.prekeys` capability only acts as a veto
    /// for peers we currently see on the mesh (a cached bundle can outlive a
    /// peer's downgrade to a build that no longer holds the privates).
    /// Re-deposits of the same message reuse its assigned prekey, so one
    /// message consumes exactly one prekey ID regardless of courier count.
    private func assignRecipientPrekey(messageID: String, recipientNoiseKey: Data) -> PrekeyBundle.Prekey? {
        let shortID = PeerID(publicKey: recipientNoiseKey)
        let knownOnMesh = peerRegistry.info(for: shortID) != nil
        if knownOnMesh, !peerCapabilities(shortID).contains(.prekeys) {
            return nil
        }
        return prekeyBundleStore.assignPrekey(messageID: messageID, recipientNoiseKey: recipientNoiseKey)
    }

    private func makeCourierPacket(_ payload: Data, to peerID: PeerID) -> BitchatPacket {
        let packet = BitchatPacket(
            type: MessageType.courierEnvelope.rawValue,
            senderID: myPeerIDData,
            recipientID: Data(hexString: peerID.id),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: messageTTL
        )
        // Signed so a courier can authenticate the depositor before carrying
        // mail under their quota. Handover to the recipient doesn't need the
        // packet signature — the inner Noise X seal authenticates the sender.
        return noiseService.signPacket(packet) ?? packet
    }

    /// Handles both courier roles for an incoming envelope addressed to us:
    /// recipient (the rotating tag matches our static key → open and deliver)
    /// or courier (a trusted peer is depositing mail for someone else → store).
    func handleCourierEnvelope(_ packet: BitchatPacket, from peerID: PeerID) {
        // Directed packets only; envelopes addressed elsewhere ride the
        // generic relay path untouched.
        guard packet.recipientID == myPeerIDData else { return }
        guard let envelope = CourierEnvelope.decode(packet.payload), !envelope.isExpired else { return }

        let myKey = noiseService.getStaticPublicKeyData()
        if CourierEnvelope.candidateTags(noiseStaticKey: myKey, around: Date()).contains(envelope.recipientTag) {
            openCourierEnvelope(envelope)
        } else {
            acceptCourierDeposit(envelope, from: peerID, packet: packet)
        }
    }

    @discardableResult
    private func openCourierEnvelope(_ envelope: CourierEnvelope) -> Bool {
        do {
            let typedPayload: Data
            let senderStaticKey: Data
            if let prekeyID = envelope.prekeyID {
                // Envelope v2: sealed to one of our one-time prekeys. Opening
                // consumes the prekey (48h redelivery grace), which shrinks our
                // published bundle under a strictly newer generatedAt. Re-gossip
                // so peers replace their cached copy and stop assigning the
                // consumed ID before the grace lapses; force the broadcast when
                // the batch also topped back up (low-water), otherwise let the
                // rebroadcast throttle coalesce bursts.
                let opened = try noiseService.openPrekeyPayload(envelope.ciphertext, prekeyID: prekeyID)
                (typedPayload, senderStaticKey) = (opened.payload, opened.senderStaticKey)
                if opened.consumedPrekey {
                    let replenished = noiseService.replenishPrekeysIfNeeded()
                    sendPrekeyBundle(force: replenished)
                }
            } else {
                (typedPayload, senderStaticKey) = try noiseService.openCourierPayload(envelope.ciphertext)
            }
            guard let typeRaw = typedPayload.first,
                  let payloadType = NoisePayloadType(rawValue: typeRaw),
                  payloadType == .privateMessage else {
                SecureLogger.warning("⚠️ Courier envelope carried unsupported payload type", category: .session)
                return true // decrypted but deterministically unsupported
            }
            let payload = Data(typedPayload.dropFirst())
            guard let innerMessageID = PrivateMessagePacket.decode(from: payload)?.messageID else {
                SecureLogger.warning("⚠️ Courier envelope carried undecodable private message", category: .session)
                return true // decrypted but deterministically malformed
            }
            // Redundant copies of one message arrive as distinct envelopes
            // (fresh seal each: mesh couriers, bridge drops across relays),
            // so dedup here on the inner message ID — before delivery, ack,
            // and handshake work. A duplicate costs only the decrypt above
            // and at most one ack ever goes out per message ID.
            let firstOpen = onEngine {
                openedCourierMessageIDs.insert(innerMessageID)
            }
            guard firstOpen else {
                SecureLogger.debug("📦 Dropping duplicate courier envelope for message \(innerMessageID.prefix(8))…", category: .session)
                return true
            }
            // Couriered mail arrives while the sender is absent, so the UI's
            // block check can't resolve their fingerprint from a live session.
            // Gate here, where the full static key is in hand.
            guard !identityManager.isBlocked(fingerprint: senderStaticKey.sha256Fingerprint()) else {
                SecureLogger.debug("🚫 Dropping courier envelope from blocked sender", category: .security)
                return true
            }
            // A present sender resolves to their live mesh thread via the
            // derived short ID. An absent sender — the usual courier case —
            // uses the full noise-key ID so the message lands on the stable
            // favorite conversation instead of an unresolvable short-ID
            // thread labeled "Unknown".
            let shortID = PeerID(publicKey: senderStaticKey)
            let isKnownOnMesh = peerRegistry.info(for: shortID) != nil
            let senderPeerID = isKnownOnMesh ? shortID : PeerID(hexData: senderStaticKey)
            SecureLogger.debug("📦 Opened courier envelope from \(senderPeerID.id.prefix(8))…", category: .session)
            notifyUI { [weak self] in
                self?.deliverTransportEvent(.noisePayloadReceived(
                    peerID: senderPeerID,
                    type: payloadType,
                    payload: payload,
                    timestamp: Date()
                ))
            }
            return true
        } catch {
            // Tag collision or stale key: not addressed to us after all.
            SecureLogger.debug("📦 Courier envelope failed to open: \(error)", category: .encryption)
            return false
        }
    }

    private func acceptCourierDeposit(_ envelope: CourierEnvelope, from peerID: PeerID, packet: BitchatPacket) {
        // A deposit must come from its depositor over the direct link: the
        // claimed sender has to be the ingress peer, and the packet signature
        // has to verify against that peer's announced signing key. Otherwise
        // an untrusted sender could route an envelope through any trusted
        // neighbor and have us carry it under the neighbor's quota.
        guard PeerID(hexData: packet.senderID) == peerID else {
            SecureLogger.debug("📦 Courier deposit rejected: relayed envelope claims sender \(PeerID(hexData: packet.senderID).id.prefix(8))… but arrived from \(peerID.id.prefix(8))…", category: .security)
            return
        }
        let depositorInfo = peerRegistry.info(for: peerID)
        guard let depositorKey = depositorInfo?.noisePublicKey else {
            SecureLogger.debug("📦 Courier deposit from unknown peer \(peerID.id.prefix(8))… rejected", category: .session)
            return
        }
        guard let signingKey = depositorInfo?.signingPublicKey,
              noiseService.verifyPacketSignature(packet, publicKey: signingKey) else {
            SecureLogger.debug("📦 Courier deposit from \(peerID.id.prefix(8))… rejected (missing/invalid signature)", category: .security)
            return
        }
        let isVerifiedPeer = depositorInfo?.isVerifiedNickname ?? false
        let store = courierStore
        let policy = courierDepositPolicy
        guard let generation = capturePanicLifecycleGeneration() else { return }
        notifyUI { [weak self] in
            guard let self else { return }
            guard let tier = policy(depositorKey, isVerifiedPeer) else {
                SecureLogger.debug("📦 Courier deposit from \(peerID.id.prefix(8))… rejected (neither favorite nor verified)", category: .session)
                return
            }
            self.messageQueue.async { [weak self] in
                guard let self,
                      self.isCurrentPanicLifecycleGeneration(generation) else { return }
                if store.deposit(envelope, from: depositorKey, tier: tier) {
                    SecureLogger.debug("📦 Carrying courier envelope deposited by \(peerID.id.prefix(8))… (\(tier.rawValue))", category: .session)
                }
            }
        }
    }

    /// Hand over any carried envelopes addressed to a peer we just heard from.
    func deliverCourierMail(to peerID: PeerID, noiseKey: Data) {
        let accepted = courierStore.handoverEnvelopes(for: noiseKey) { [weak self] envelope in
            guard let self,
                  let payload = envelope.encode(),
                  self.sendPacketDirected(
                      self.makeCourierPacket(payload, to: peerID),
                      to: peerID,
                      requireDirectPeerLink: true,
                      requireNoiseAuthenticatedPeerLink: true
                  ) else {
                return false
            }
            return true
        }
        if accepted > 0 {
            SecureLogger.debug("📦 Handed over \(accepted) courier envelope(s) to \(peerID.id.prefix(8))…", category: .session)
        }
    }

    /// Speculative handover toward a recipient heard only via a relayed
    /// announce: the envelope floods the mesh as a directed packet (relays
    /// treat it like a directed DM). Non-destructive — the carried copy stays
    /// until a direct handover or expiry, throttled per envelope so repeated
    /// announces don't re-flood.
    func deliverCourierMailRemotely(to peerID: PeerID, noiseKey: Data) {
        let envelopes = courierStore.envelopesForRemoteHandover(
            recipientNoiseKey: noiseKey,
            cooldown: TransportConfig.courierRemoteHandoverCooldownSeconds
        )
        guard !envelopes.isEmpty else { return }
        SecureLogger.debug("📦 Remote handover: flooding \(envelopes.count) envelope(s) toward \(peerID.id.prefix(8))…", category: .session)
        for envelope in envelopes {
            guard let payload = envelope.encode() else { continue }
            broadcastPacket(makeCourierPacket(payload, to: peerID))
        }
    }

    /// Spray-and-wait: split copy budgets with another courier we just
    /// encountered, so carried mail diffuses through a moving crowd instead
    /// of riding a single carrier. Only favorites and verified peers qualify,
    /// mirroring the deposit policy they would apply to us.
    func sprayCourierMail(to peerID: PeerID, noiseKey: Data, isVerifiedPeer: Bool) {
        let store = courierStore
        let sendSpray: () -> Void = { [weak self] in
            guard let self else { return }
            let accepted = store.transferSprayCopies(to: noiseKey) { envelope in
                guard let payload = envelope.encode(),
                      self.sendPacketDirected(
                          self.makeCourierPacket(payload, to: peerID),
                          to: peerID,
                          requireDirectPeerLink: true,
                          requireNoiseAuthenticatedPeerLink: true
                      ) else {
                    return false
                }
                return true
            }
            if accepted > 0 {
                SecureLogger.debug("📦 Sprayed \(accepted) envelope copy(ies) to courier \(peerID.id.prefix(8))…", category: .session)
            }
        }
        let policy = courierDepositPolicy
        guard let generation = capturePanicLifecycleGeneration() else { return }
        notifyUI { [weak self] in
            guard let self else { return }
            // Same trust gate as deposits: don't hand mail to a peer who
            // would reject it from us.
            guard policy(noiseKey, isVerifiedPeer) != nil else { return }
            self.messageQueue.async { [weak self] in
                guard let self,
                      self.isCurrentPanicLifecycleGeneration(generation) else { return }
                sendSpray()
            }
        }
    }

    // MARK: One-Time Prekey Bundles

    /// Broadcasts our signed prekey bundle and tracks it for gossip sync.
    /// Unforced sends (piggybacked on announces) are throttled — gossip does
    /// the spreading, the broadcast just keeps our own gossip entry fresh.
    /// Forced sends (bundle changed after consumption) go immediately.
    func sendPrekeyBundle(force: Bool = false) {
        let now = Date()
        let shouldSend: Bool = onEngine {
            if !force,
               let last = lastPrekeyBundleSentAt,
               now.timeIntervalSince(last) < TransportConfig.prekeyBundleRebroadcastSeconds {
                return false
            }
            lastPrekeyBundleSentAt = now
            return true
        }
        guard shouldSend else { return }
        guard let bundle = noiseService.currentPrekeyBundle(),
              let payload = bundle.encode() else {
            SecureLogger.error("❌ Failed to build prekey bundle", category: .security)
            return
        }
        guard let signedPacket = buildSignedBroadcastPacket(
            type: .prekeyBundle,
            payload: payload,
            timestamp: now,
            logLabel: "prekey bundle packet"
        ) else { return }
        if DispatchQueue.getSpecific(key: messageQueueKey) != nil {
            broadcastPacket(signedPacket)
        } else {
            messageQueue.async { [weak self] in
                self?.broadcastPacket(signedPacket)
            }
        }
        gossipSyncManager?.onPublicPacketSeen(signedPacket)
    }

    /// Ingests a gossiped prekey bundle. Attribution is layered: the outer
    /// packet must originate from the bundle owner (fabricated sender IDs, used
    /// to multiply cache/gossip entries, are rejected), and BOTH the inner
    /// bundle signature and the outer packet signature must verify against the
    /// owner's announce-bound signing key. Verifying the outer packet — whose
    /// signed bytes cover senderID and timestamp — stops a valid bundle from
    /// being replayed under a fresh timestamp or spoofed sender to pass
    /// freshness or poison attribution. Only after that does the packet enter
    /// our own gossip store, so we never help spread a bundle we couldn't
    /// attribute.
    @discardableResult
    func handlePrekeyBundle(_ packet: BitchatPacket, from peerID: PeerID) -> Bool {
        guard let bundle = PrekeyBundle.decode(packet.payload) else {
            SecureLogger.debug("🔑 Ignoring malformed prekey bundle from \(peerID.id.prefix(8))…", category: .security)
            return false
        }
        // Our own bundle is tracked at send time; a copy echoing back adds nothing.
        guard bundle.noiseStaticPublicKey != noiseService.getStaticPublicKeyData() else { return false }
        let owner = PeerID(publicKey: bundle.noiseStaticPublicKey)
        // The owner's genuine bundle (direct or relayed) always carries the
        // owner's senderID + outer signature; gossip resends preserve both. A
        // packet whose senderID isn't the owner can't be authenticated here.
        guard PeerID(hexData: packet.senderID) == owner else {
            SecureLogger.debug("🔑 Ignoring prekey bundle whose sender ≠ owner \(owner.id.prefix(8))…", category: .security)
            return false
        }
        guard let signingKey = authenticatedSigningKey(forNoiseKey: bundle.noiseStaticPublicKey) else {
            // No Noise-authenticated signing-key binding yet: retain the latest
            // bundle per owner, bounded, and retry once Noise authentication
            // binds the signing key (engine-confined on messageQueue). Never
            // trust a TOFU self-signed announce for prekey bundles: courier
            // prekey sealing uses Noise X against the prekey alone, so a forged
            // first-contact announce + bundle would let an attacker decrypt mail
            // that static-key sealing would have protected.
            if pendingPrekeyBundles[owner] != nil
                || pendingPrekeyBundles.count < Self.pendingPrekeyBundleCap {
                pendingPrekeyBundles[owner] = packet
            }
            SecureLogger.debug("🔑 Deferring prekey bundle without a Noise-authenticated signing key (owner \(owner.id.prefix(8))…)", category: .security)
            return false
        }
        return ingestVerifiedPrekeyBundle(bundle, packet: packet, owner: owner, signingKey: signingKey)
    }

    /// Verify a bundle's inner + outer signatures against the owner's
    /// Noise-authenticated signing key and, on success, cache it and let it
    /// enter our gossip store.
    @discardableResult
    private func ingestVerifiedPrekeyBundle(_ bundle: PrekeyBundle, packet: BitchatPacket, owner: PeerID, signingKey: Data) -> Bool {
        guard noiseService.verifyPrekeyBundleSignature(bundle, signingPublicKey: signingKey),
              noiseService.verifyPacketSignature(packet, publicKey: signingKey) else {
            SecureLogger.debug("🔑 Ignoring prekey bundle without verifiable signature (owner \(owner.id.prefix(8))…)", category: .security)
            return false
        }
        if prekeyBundleStore.ingest(bundle, signingPublicKey: signingKey) {
            SecureLogger.debug("🔑 Cached prekey bundle for \(owner.id.prefix(8))… (\(bundle.prekeys.count) prekeys)", category: .security)
        }
        gossipSyncManager?.onPublicPacketSeen(packet)
        return true
    }

    /// Re-attempt any prekey bundle that arrived before Noise authentication
    /// bound this owner's signing key. Called from `handleAnnounce` and
    /// `handleAuthenticatedPeerState` on messageQueue.
    func drainPendingPrekeyBundles(for owner: PeerID) {
        guard let packet = pendingPrekeyBundles[owner],
              let bundle = PrekeyBundle.decode(packet.payload),
              let signingKey = authenticatedSigningKey(forNoiseKey: bundle.noiseStaticPublicKey) else { return }
        pendingPrekeyBundles.removeValue(forKey: owner)
        ingestVerifiedPrekeyBundle(bundle, packet: packet, owner: owner, signingKey: signingKey)
    }

    /// Ed25519 signing key cryptographically bound to a Noise static key
    /// through an authenticated Noise session (`AuthenticatedPeerStatePacket`).
    private func authenticatedSigningKey(forNoiseKey noiseKey: Data) -> Data? {
        identityManager.authenticatedSigningPublicKey(
            forFingerprint: noiseKey.sha256Fingerprint()
        )
    }

    // MARK: Gateway carrier (nostrCarrier)

    /// Sign and send an encoded `toGateway` carrier payload directed at a
    /// gateway peer. The packet is signed so the gateway can key its uplink
    /// quotas to an authenticated depositor; the carried Nostr event has its
    /// own Schnorr signature for content authenticity. Returns false when
    /// the gateway is not reachable or signing fails.
    func sendNostrCarrier(_ payload: Data, to gatewayPeer: PeerID) -> Bool {
        guard isPeerReachable(gatewayPeer) else { return false }
        let packet = BitchatPacket(
            type: MessageType.nostrCarrier.rawValue,
            senderID: myPeerIDData,
            recipientID: Data(hexString: gatewayPeer.id),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: messageTTL
        )
        guard let signed = noiseService.signPacket(packet) else { return false }
        messageQueue.async { [weak self] in
            // broadcastPacket applies a known route when one exists and
            // otherwise floods the directed packet like a DM, so a gateway
            // that is reachable but multi-hop still gets the deposit.
            self?.broadcastPacket(signed)
        }
        return true
    }

    /// Broadcast an encoded `fromGateway` carrier payload on the mesh with
    /// the default TTL. Unsigned at the packet layer — receivers verify the
    /// carried event's own Schnorr signature.
    func broadcastNostrCarrier(_ payload: Data) {
        let packet = BitchatPacket(
            type: MessageType.nostrCarrier.rawValue,
            senderID: myPeerIDData,
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: messageTTL
        )
        messageQueue.async { [weak self] in
            self?.broadcastPacket(packet)
        }
    }

    /// Transport-level handling for a received nostrCarrier packet; policy
    /// (verification of the carried event, quotas, loop prevention) lives in
    /// `GatewayService` behind `onNostrCarrierPacket`.
    func handleNostrCarrier(_ packet: BitchatPacket, from _: PeerID) {
        let senderID = PeerID(hexData: packet.senderID)
        let directedToUs: Bool
        if let recipientID = packet.recipientID {
            // Carriers addressed elsewhere ride the generic relay path untouched.
            guard recipientID == myPeerIDData else { return }
            // Uplink deposit: quotas are keyed by the depositor, so the
            // packet signature must verify against the sender's announced
            // signing key. Unlike courier deposits the depositor may be
            // multi-hop away, so ingress-link identity is not required.
            let signingKey = peerRegistry.info(for: senderID)?.signingPublicKey
            guard let signingKey,
                  noiseService.verifyPacketSignature(packet, publicKey: signingKey) else {
                SecureLogger.debug("🌐 nostrCarrier uplink from \(senderID.id.prefix(8))… rejected (missing/invalid packet signature)", category: .security)
                return
            }
            directedToUs = true
        } else {
            directedToUs = false
        }
        let payload = packet.payload
        notifyUI { [weak self] in
            self?.onNostrCarrierPacket?(payload, senderID, directedToUs)
        }
    }
}

import BitFoundation
import BitLogger
import Foundation

// MARK: - Link Auth & Noise Session Coordination

extension BLEService {
    func links(to peerID: PeerID?) -> Set<BLEIngressLinkID> {
        linkBindings.links(to: peerID)
    }

    /// Marks the exact physical ingress link that completed a fresh Noise
    /// handshake. An old session keyed only by peer ID is insufficient: a
    /// replayed announce can rebind an attacker's link to that ID.
    /// Engine-confined.
    func markNoiseAuthenticatedIngressLink(for packet: BitchatPacket, peerID: PeerID) {
        guard let link = ingressLinks.link(for: packet) else { return }
        guard linkBindings.boundPeer(for: link) == peerID else { return }
        linkAuth.markAuthenticated(link, owner: peerID)
    }

    func isNoiseAuthenticatedIngressLink(for packet: BitchatPacket, peerID: PeerID) -> Bool {
        guard let link = ingressLinks.link(for: packet) else { return false }
        return linkAuth.isAuthenticated(link, for: peerID) && linkBindings.boundPeer(for: link) == peerID
    }

    func hasCurrentNoiseAuthenticatedLink(to peerID: PeerID) -> Bool {
        !currentNoiseAuthenticatedLinks(to: peerID).isEmpty
    }

    func currentNoiseAuthenticatedLinks(to peerID: PeerID) -> Set<BLEIngressLinkID> {
        Set(linkAuth.links(ownedBy: peerID).filter { link in
            linkBindings.boundPeer(for: link) == peerID
        })
    }

    /// A peer-level session can outlive the physical link that established it.
    /// Revalidate a fresh direct link with an ordinary XX exchange, retiring
    /// cached sending keys atomically before message 1 can leave.
    ///
    /// Takes the already-resolved ingress link. Engine-confined: it runs
    /// inside the rebind's engine slot, so no observer can see the new
    /// binding while a cached peer-level sender is still considered
    /// established.
    func refreshNoiseSessionForVerifiedDirectLink(
        link: BLEIngressLinkID,
        peerID: PeerID
    ) {
        let hasEstablishedSession = noiseService.hasEstablishedSession(with: peerID)
        let authenticatedPeerLinks = currentNoiseAuthenticatedLinks(to: peerID)
        let shouldRevalidate: Bool
        if linkBindings.boundPeer(for: link) == peerID {
            shouldRevalidate = linkAuth.shouldRevalidate(
                on: link,
                for: peerID,
                hasEstablishedSession: hasEstablishedSession,
                hasAuthenticatedPeerLink: !authenticatedPeerLinks.isEmpty,
                now: Date()
            )
        } else {
            shouldRevalidate = false
        }
        guard shouldRevalidate else { return }

        SecureLogger.info(
            "🔄 Revalidating cached Noise session on fresh direct link to \(peerID.id.prefix(8))…",
            category: .session
        )
        initiateNoiseReconnectHandshake(with: peerID)
    }

    func configureNoiseServiceCallbacks(for service: NoiseEncryptionService) {
        let (peerAuthHandlers, handshakeRequiredHandler): ([(PeerID, String) -> Void], ((PeerID) -> Void)?) = {
            externalNoiseCallbacksLock.lock()
            defer { externalNoiseCallbacksLock.unlock() }
            return (externalPeerAuthenticatedHandlers, externalHandshakeRequiredHandler)
        }()
        for handler in peerAuthHandlers {
            service.addOnPeerAuthenticatedHandler(handler)
        }
        if let handshakeRequiredHandler {
            service.onHandshakeRequired = handshakeRequiredHandler
        }

        service.onPeerAuthenticatedWithGeneration = { [weak self] peerID, fingerprint, generation in
            SecureLogger.debug("🔐 Noise session authenticated with \(peerID.id.prefix(8))…, fingerprint: \(fingerprint.prefix(16))…")
            // Authentication can be reported while an initiator is still
            // returning XX message 3. Serialize generation-bound state and
            // every post-handshake drain behind the handshake packet handler.
            self?.messageQueue.async { [weak self] in
                self?.handleNoisePeerAuthenticated(
                    peerID: peerID,
                    fingerprint: fingerprint,
                    sessionGeneration: generation
                )
            }
        }
        service.onRekeyHandshakeReady = { [weak self, weak service] peerID, initiation in
            self?.messageQueue.async { [weak self, weak service] in
                guard let self,
                      let service,
                      self.noiseService === service else {
                    return
                }
                self.noteNoiseSessionCleared(for: peerID)
                guard let message = service.claimHandshakeInitiation(
                    initiation,
                    for: peerID
                ) else {
                    return
                }
                self.broadcastNoiseHandshake(message, to: peerID)
            }
        }
        service.onHandshakeRecoveryRequired = { [weak self, weak service] request in
            guard let self, let service else { return }
            #if DEBUG
            self._test_beforeHandshakeRecoveryEnqueued?(request.peerID)
            #endif
            self.messageQueue.async { [weak self, weak service] in
                guard let self,
                      let service,
                      self.noiseService === service else {
                    return
                }
                let peerID = request.peerID
                guard self.isPeerReachable(peerID) else {
                    service.cancelHandshakeRecovery(request)
                    return
                }

                do {
                    guard let preparation =
                        try service.prepareHandshakeRecovery(request) else {
                        return
                    }
                    switch preparation {
                    case .ordinary(let initiation):
                        self.noteNoiseSessionCleared(for: peerID)
                        guard let handshakeData =
                            service.claimHandshakeInitiation(
                                initiation,
                                for: peerID
                            ) else {
                            return
                        }
                        self.broadcastNoiseHandshake(
                            handshakeData,
                            to: peerID
                        )
                    case .transferred:
                        return
                    }
                } catch {
                    SecureLogger.error(
                        "Failed to prepare handshake recovery with \(peerID.id.prefix(8))…: \(error)",
                        category: .session
                    )
                }
            }
        }
        service.onSessionRestoredWithGeneration = { [weak self, weak service] peerID, generation, reason in
            guard let self, let service else { return }
            // The manager makes restored keys visible atomically. Reconcile
            // transport state and queued sends as the next serialized phase.
            self.messageQueue.async { [weak self, weak service] in
                guard let self,
                      let service,
                      self.noiseService === service,
                      let fingerprint = service.getPeerFingerprint(peerID) else {
                    return
                }
                SecureLogger.debug(
                    "🔐 Restored quarantined Noise session with \(peerID.id.prefix(8))…",
                    category: .session
                )
                // Re-enter the same generation-bound transition used after a
                // successful handshake to restore authenticated protocol
                // state. Only a terminal restore may also drain the PM and
                // typed-payload queues: after a responder timeout the
                // counterpart may have completed the replacement handshake
                // and discarded the restored keys, so encrypting the queues
                // under them would lose every message silently. The mandatory
                // convergence retry that accompanies the restore drains them
                // under the new session instead (any establishment does).
                self.handleNoisePeerAuthenticated(
                    peerID: peerID,
                    fingerprint: fingerprint,
                    sessionGeneration: generation,
                    deferOutboundUntilConvergence: reason == .pendingConvergence
                )
            }
        }
    }

    func handleNoisePeerAuthenticated(
        peerID: PeerID,
        fingerprint: String,
        sessionGeneration generation: UUID,
        deferOutboundUntilConvergence: Bool = false
    ) {
        // Engine-only: the store transition below runs inside the noise
        // manager's critical section while this engine slot stays blocked.
        // The store is a leaf lock, so that nesting is safe — but nothing in
        // that closure may sync-re-enter the engine (self-deadlock).
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(messageQueue))
        #endif
        let normalizedPeerID = peerID.toShort()
        // The generation lease serializes this transition against session
        // replacement; nil-inside-nil distinguishes a lost lease (outer)
        // from the same-generation reconciliation path (inner).
        guard let leased = noiseService.withCurrentSessionGeneration(
            for: normalizedPeerID,
            expected: generation,
            {
                privateMediaSessions.beginAuthenticatedGeneration(
                    for: normalizedPeerID,
                    fingerprint: fingerprint,
                    generation: generation
                )
            }
        ) else { return }

        guard let fresh = leased else {
            // A quarantined transport restored the same cryptographic
            // generation. Its capability proof and announce state never
            // became stale; only work queued while outbound keys were paused
            // needs one idempotent ready transition. Retrying the bounded
            // early-ciphertext queue is receive-side and therefore always
            // safe under the restored keys.
            noisePacketHandler.handleSessionAuthenticated(normalizedPeerID)
            finalizeNoisePeerAuthentication(
                for: normalizedPeerID,
                deferOutboundUntilConvergence: deferOutboundUntilConvergence,
                sendInitialStateAndAnnounce: false
            )
            return
        }

        completePrivateMediaPolicyResolution(fresh.rejected, with: .blockedDowngrade)
        schedulePrivateMediaProofTimeout(
            for: normalizedPeerID,
            fingerprint: fingerprint,
            sessionGeneration: generation,
            nonce: fresh.watchdogNonce
        )
        // Cross-link delivery can put ciphertext sent immediately after
        // message 3 ahead of message 3 itself. Retry the bounded queue only
        // after this generation's transport state has been fully installed.
        noisePacketHandler.handleSessionAuthenticated(normalizedPeerID)
        finalizeNoisePeerAuthentication(
            for: normalizedPeerID,
            deferOutboundUntilConvergence: deferOutboundUntilConvergence,
            sendInitialStateAndAnnounce: true
        )
    }

    private func finalizeNoisePeerAuthentication(
        for peerID: PeerID,
        deferOutboundUntilConvergence: Bool,
        sendInitialStateAndAnnounce: Bool
    ) {
        if deferOutboundUntilConvergence {
            // Timeout-restore: the counterpart may have completed the
            // replacement handshake and discarded these keys, so encrypting
            // the parked queues here would lose them silently. The restore's
            // mandatory convergence retry — or any later handshake — re-enters
            // with a fresh generation and drains them under keys both sides hold.
            privateMediaSessions.setOutboundDeferredUntilConvergence(peerID)
            #if DEBUG
            _test_onPrivateMediaSessionReconciled?(peerID)
            #endif
            return
        }
        privateMediaSessions.clearOutboundDeferredUntilConvergence(peerID)
        if sendInitialStateAndAnnounce {
            sendAuthenticatedPeerState(to: peerID, echo: false)
        }
        #if DEBUG
        _test_onPrivateMediaSessionReconciled?(peerID)
        #endif
        sendPendingMessagesAfterHandshake(for: peerID)
        sendPendingNoisePayloadsAfterHandshake(for: peerID)
        if sendInitialStateAndAnnounce {
            sendAnnounce(forceSend: true)
        }
    }

    private func sendAuthenticatedPeerState(to peerID: PeerID, echo: Bool) {
        let normalizedPeerID = peerID.toShort()
        guard privateMediaSessions.markPeerStateSend(for: normalizedPeerID, echo: echo) else { return }

        let capabilities = localIdentityState.snapshot().advertisedCapabilities
        let state = AuthenticatedPeerStatePacket(
            capabilities: capabilities,
            signingPublicKey: noiseService.getSigningPublicKeyData()
        )
        guard let payload = BLENoisePayloadFactory.authenticatedPeerState(state) else {
            SecureLogger.error("Failed to encode authenticated peer state", category: .security)
            return
        }
        sendNoisePayload(payload, to: normalizedPeerID)
    }

    func handleAuthenticatedPeerState(
        _ payload: Data,
        from peerID: PeerID,
        sessionGeneration generation: UUID
    ) {
        // Engine-only, like handleNoisePeerAuthenticated: the closure below
        // runs on the noise manager's queue while this engine slot stays
        // blocked, so it accesses engine-owned state directly instead of
        // sync-re-entering the engine (self-deadlock).
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(messageQueue))
        #endif
        let normalizedPeerID = peerID.toShort()
        guard let state = AuthenticatedPeerStatePacket.decode(from: payload) else {
            SecureLogger.warning(
                "Ignoring malformed authenticated peer state from \(normalizedPeerID.id.prefix(8))…",
                category: .security
            )
            return
        }
        guard let fingerprint = noiseService.getPeerFingerprint(normalizedPeerID),
              let publicKey = noiseService.getPeerPublicKeyData(normalizedPeerID),
              publicKey.sha256Fingerprint().caseInsensitiveCompare(fingerprint) == .orderedSame else {
            SecureLogger.warning(
                "Ignoring peer state without a matching authenticated Noise identity",
                category: .security
            )
            return
        }
        guard let application = noiseService.withCurrentSessionGeneration(
            for: normalizedPeerID,
            expected: generation,
            {
                () -> (accepted: Bool, completions: [@MainActor (PrivateMediaSendPolicy) -> Void]) in
                guard privateMediaSessions.currentGeneration(for: normalizedPeerID) == generation else {
                    return (false, [])
                }

                // The generation lease (plus the engine slot this section
                // holds) prevents rekey/session promotion from interleaving
                // between validation and these durable mutations.
                identityManager.bindAuthenticatedSigningPublicKey(
                    state.signingPublicKey,
                    fingerprint: fingerprint
                )
                identityManager.upsertCryptographicIdentity(
                    fingerprint: fingerprint,
                    noisePublicKey: publicKey,
                    signingPublicKey: state.signingPublicKey,
                    claimedNickname: nil
                )
                if state.capabilities.contains(.privateMedia) {
                    identityManager.markPrivateMediaCapable(fingerprint: fingerprint)
                }

                peerRegistry.mutate {
                    $0.bindAuthenticatedSigningPublicKey(
                        state.signingPublicKey,
                        for: normalizedPeerID
                    )
                }
                guard let completions = privateMediaSessions.applyAuthenticatedPeerState(
                    for: normalizedPeerID,
                    fingerprint: fingerprint,
                    generation: generation,
                    capabilities: state.capabilities
                ) else {
                    return (false, [])
                }
                return (true, completions)
            }
        ), application.accepted else { return }

        // One bounded echo makes initiator/responder proof ordering converge
        // even when message 3 and the first proof take different mesh links.
        sendAuthenticatedPeerState(to: normalizedPeerID, echo: true)
        // Purge any prekey bundle cached under a different/legacy signing key
        // and verify any pending bundle that arrived before Noise auth landed.
        prekeyBundleStore.invalidate(forNoiseKey: publicKey, unlessSignedBy: state.signingPublicKey)
        drainPendingPrekeyBundles(for: normalizedPeerID)
        let policy = privateMediaSendPolicy(to: normalizedPeerID)
        sendPendingNoisePayloadsAfterHandshake(for: normalizedPeerID)
        completePrivateMediaPolicyResolution(application.completions, with: policy)
    }

    func noteNoiseSessionCleared(for peerID: PeerID) {
        let normalizedPeerID = peerID.toShort()
        let reset = privateMediaSessions.clearSession(for: normalizedPeerID)
        if let reset {
            schedulePrivateMediaProofTimeout(
                for: normalizedPeerID,
                fingerprint: reset.fingerprint,
                sessionGeneration: nil,
                nonce: reset.nonce
            )
        }
    }

    func clearNoiseSession(for peerID: PeerID) {
        noiseService.clearSession(for: peerID)
        noteNoiseSessionCleared(for: peerID)
    }

    /// Swaps `myPeerID`/`myPeerIDData` to match the current Noise identity.
    /// The swap runs as a `messageQueue` barrier so in-flight work items that
    /// read the identity (e.g. `sendMessage` building packets) complete
    /// against the old value and everything after sees the new one atomically.
    /// Callers (init, panic reset on the main thread) are never on
    /// `messageQueue`; the re-entrancy check keeps any future on-queue caller
    /// from deadlocking.
    func refreshPeerIdentity() {
        onEngine {
            let fingerprint = noiseService.getIdentityFingerprint()
            localIdentityState.replacePeerIdentity(
                with: PeerID(str: fingerprint.prefix(16))
            )
            meshTopology.reset()
        }
    }

    func sendNoisePayload(_ typedPayload: Data, to peerID: PeerID) {
        sendOrQueueNoisePayload(
            typedPayload,
            to: peerID,
            initiateOnlyIfReachable: false,
            logLabel: "noise payload"
        )
    }

    func sendOrQueueNoisePayload(
        _ typedPayload: Data,
        to peerID: PeerID,
        initiateOnlyIfReachable: Bool,
        logLabel: String
    ) {
        // Hop like sendMessage: callers are often on the main actor, and the
        // send path sync-waits on bleQueue for link state.
        if DispatchQueue.getSpecific(key: messageQueueKey) == nil {
            messageQueue.async { [weak self] in
                self?.sendOrQueueNoisePayload(
                    typedPayload,
                    to: peerID,
                    initiateOnlyIfReachable: initiateOnlyIfReachable,
                    logLabel: logLabel
                )
            }
            return
        }
        // Sessions and pending Noise queues are keyed by the short 16-hex
        // routing ID; callers (e.g. couriered DMs, offline-favorite threads)
        // may pass the full 64-hex noise key.
        let peerID = peerID.toShort()
        guard noiseService.hasEstablishedSession(with: peerID) else {
            pendingNoiseSessionQueues.appendTypedPayload(typedPayload, for: peerID)
            SecureLogger.debug("📥 Queued \(logLabel) for \(peerID.id.prefix(8))… pending handshake", category: .session)
            if !initiateOnlyIfReachable || (!noiseService.hasSession(with: peerID) && isPeerReachable(peerID)) {
                initiateNoiseHandshake(with: peerID)
            }
            return
        }
        do {
            broadcastPacket(try makeEncryptedNoisePacket(typedPayload, to: peerID))
        } catch {
            SecureLogger.error("Failed to send \(logLabel): \(error)")
        }
    }

    func makeEncryptedNoisePacket(
        _ typedPayload: Data,
        to peerID: PeerID,
        requiresAuthenticatedPrivateMediaReceipts: Bool = false
    ) throws -> BitchatPacket {
        let encrypted: Data
        let isPrivateFile = NoisePayloadType.isPrivateFile(rawValue: typedPayload.first)
        if isPrivateFile {
            let provenGeneration = privateMediaSessions.provenGeneration(
                for: peerID,
                requireReceipts: requiresAuthenticatedPrivateMediaReceipts
            )
            guard let provenGeneration else {
                throw NoiseEncryptionError.sessionNotEstablished
            }
            encrypted = try noiseService.encryptPrivateFilePayload(
                typedPayload,
                for: peerID,
                sessionGeneration: provenGeneration
            )
        } else {
            encrypted = try noiseService.encrypt(typedPayload, for: peerID)
        }
        return BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: myPeerIDData,
            recipientID: Data(hexString: peerID.id),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: encrypted,
            signature: nil,
            ttl: messageTTL,
            // v1 has a 16-bit payload length; finalized media can exceed it.
            version: isPrivateFile ? 2 : 1
        )
    }
}

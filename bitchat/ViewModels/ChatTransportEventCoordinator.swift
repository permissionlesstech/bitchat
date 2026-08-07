import BitFoundation
import BitLogger
import Foundation

/// The narrow surface `ChatTransportEventCoordinator` needs from its owner.
///
/// Follows the `ChatDeliveryContext` exemplar: the coordinator depends on the
/// minimal context it actually uses instead of holding an `unowned` back-ref
/// to the whole `ChatViewModel`. This keeps the coordinator independently
/// testable (see `ChatTransportEventCoordinatorContextTests`) and makes its
/// true dependencies explicit.
@MainActor
protocol ChatTransportEventContext: AnyObject {
    // MARK: Connection & chat state
    var isConnected: Bool { get set }
    var nickname: String { get }
    var myPeerID: PeerID { get }
    /// A single private chat's timeline (store-direct lookup on
    /// `ChatViewModel`; no `privateChats` dictionary build).
    func privateMessages(for peerID: PeerID) -> [BitchatMessage]
    var unreadPrivateMessages: Set<PeerID> { get }
    var selectedPrivateChatPeer: PeerID? { get set }
    /// Appends a private message via the single-writer store intent;
    /// returns `false` on duplicate message ID.
    @discardableResult
    func appendPrivateMessage(_ message: BitchatMessage, to peerID: PeerID) -> Bool
    /// Removes the peer's chat entirely, including unread state.
    func removePrivateChat(_ peerID: PeerID)
    func markPrivateChatUnread(_ peerID: PeerID)
    func markPrivateChatRead(_ peerID: PeerID)
    /// Forgets that read receipts were sent for `ids` so READ acks can be
    /// re-sent after the peer reconnects. (Single mutation path for the
    /// owner's `sentReadReceipts`; this coordinator never reads the raw set.)
    func unmarkReadReceiptsSent(_ ids: [String])
    /// Signals that message state changed so observers refresh (e.g. `objectWillChange.send()`).
    func notifyUIChanged()

    // MARK: Inbound message handling
    func isMessageBlocked(_ message: BitchatMessage) -> Bool
    func handlePrivateMessage(_ message: BitchatMessage)
    func handlePublicMessage(_ message: BitchatMessage)
    func checkForMentions(_ message: BitchatMessage)
    func sendHapticFeedback(for message: BitchatMessage)
    func parseMentions(from content: String) -> [String]

    // MARK: Peer identity & sessions
    func isPeerBlocked(_ peerID: PeerID) -> Bool
    /// The peer's current entry in the unified peer service, if known.
    func unifiedPeer(for peerID: PeerID) -> BitchatPeer?
    func resolveNickname(for peerID: PeerID) -> String
    func registerEphemeralSession(peerID: PeerID)
    func removeEphemeralSession(peerID: PeerID)
    /// Resolves the peer's Noise static key from the active Noise session, if any.
    func noiseSessionPublicKeyData(for peerID: PeerID) -> Data?
    func cacheStablePeerID(_ stablePeerID: PeerID, for shortPeerID: PeerID)
    func cachedStablePeerID(for shortPeerID: PeerID) -> PeerID?

    // MARK: Routing & acknowledgements
    func flushRouterOutbox(for peerID: PeerID)
    /// Offer queued mail for *other* peers to this newly connected courier.
    func retryCourierDeposits(via peerID: PeerID)
    func sendMeshDeliveryAck(for messageID: String, to peerID: PeerID)

    // MARK: Delivery status
    /// Applies an authenticated receipt to the message only when it belongs
    /// to the supplied peer conversation aliases. Returns `false` for an
    /// unknown ID, wrong peer, or rejected status transition.
    @discardableResult
    func applyAcknowledgedMessageDeliveryStatus(
        _ messageID: String,
        status: DeliveryStatus,
        from peerIDAliases: Set<PeerID>
    ) -> Bool
    func deliveryStatus(for messageID: String) -> DeliveryStatus?

    // MARK: Verification payloads
    func handleVerifyChallengePayload(from peerID: PeerID, payload: Data)
    func handleVerifyResponsePayload(from peerID: PeerID, payload: Data)

    // MARK: Live voice (push-to-talk)
    func handleVoiceFramePayload(from peerID: PeerID, payload: Data, timestamp: Date)

    // MARK: Group payloads (creator-signed state over Noise)
    func handleGroupInvitePayload(from peerID: PeerID, payload: Data)
    func handleGroupKeyUpdatePayload(from peerID: PeerID, payload: Data)
    func handleVouchPayload(from peerID: PeerID, payload: Data)

    // MARK: Double-ratchet bootstrap
    func bootstrapDoubleRatchetIfNeeded(for peerID: PeerID)
    func handleNdrEventPayload(from peerID: PeerID, payload: Data)
}

extension ChatTransportEventContext {
    func bootstrapDoubleRatchetIfNeeded(for _: PeerID) {}
    func handleNdrEventPayload(from _: PeerID, payload _: Data) {}
}

extension ChatViewModel: ChatTransportEventContext {
    // `isConnected`, `nickname`, `myPeerID`, `privateMessages(for:)`,
    // `unreadPrivateMessages`, `selectedPrivateChatPeer`, `notifyUIChanged()`,
    // the inbound message handlers, `isPeerBlocked(_:)`,
    // `parseMentions(from:)`, `resolveNickname(for:)`,
    // `cacheStablePeerID(_:for:)`, and `cachedStablePeerID(for:)` are shared
    // requirements with the other contexts or satisfied by existing
    // `ChatViewModel` members. The single-writer intent op
    // `unmarkReadReceiptsSent(_:)` lives next to its backing state in
    // `ChatViewModel`. The members below flatten nested service accesses into
    // intent-named calls.

    func unifiedPeer(for peerID: PeerID) -> BitchatPeer? {
        unifiedPeerService.getPeer(by: peerID)
    }

    func registerEphemeralSession(peerID: PeerID) {
        identityManager.registerEphemeralSession(peerID: peerID, handshakeState: .none)
    }

    func removeEphemeralSession(peerID: PeerID) {
        identityManager.removeEphemeralSession(peerID: peerID)
    }

    func noiseSessionPublicKeyData(for peerID: PeerID) -> Data? {
        meshService.noiseSessionPublicKeyData(for: peerID)
    }

    func flushRouterOutbox(for peerID: PeerID) {
        messageRouter.flushOutbox(for: peerID)
    }

    func retryCourierDeposits(via peerID: PeerID) {
        messageRouter.courierBecameAvailable(peerID)
    }

    func sendMeshDeliveryAck(for messageID: String, to peerID: PeerID) {
        meshService.sendDeliveryAck(for: messageID, to: peerID)
    }

    @discardableResult
    func applyAcknowledgedMessageDeliveryStatus(
        _ messageID: String,
        status: DeliveryStatus,
        from peerIDAliases: Set<PeerID>
    ) -> Bool {
        deliveryCoordinator.updateAcknowledgedMessageDeliveryStatus(
            messageID,
            status: status,
            from: peerIDAliases
        )
    }

    func deliveryStatus(for messageID: String) -> DeliveryStatus? {
        deliveryCoordinator.deliveryStatus(for: messageID)
    }

    func handleVerifyChallengePayload(from peerID: PeerID, payload: Data) {
        verificationCoordinator.handleVerifyChallengePayload(from: peerID, payload: payload)
    }

    func handleVerifyResponsePayload(from peerID: PeerID, payload: Data) {
        verificationCoordinator.handleVerifyResponsePayload(from: peerID, payload: payload)
    }

    // `handleVoiceFramePayload(from:payload:timestamp:)` lives in
    // ChatViewModel+PrivateChat.swift next to the rest of the live-voice
    // surface.

    func handleGroupInvitePayload(from peerID: PeerID, payload: Data) {
        groupCoordinator.handleGroupInvitePayload(from: peerID, payload: payload)
    }

    func handleGroupKeyUpdatePayload(from peerID: PeerID, payload: Data) {
        groupCoordinator.handleGroupKeyUpdatePayload(from: peerID, payload: payload)
    }

    func handleVouchPayload(from peerID: PeerID, payload: Data) {
        vouchCoordinator.handleVouchPayload(from: peerID, payload: payload)
    }

    private var ndrTransport: MeshDoubleRatchetTransporting? {
        meshService as? MeshDoubleRatchetTransporting
    }

    func bootstrapDoubleRatchetIfNeeded(for peerID: PeerID) {
        guard ndrService.isRolloutEnabled,
              let ndrTransport,
              let authenticated =
                ndrTransport.authenticatedPeerTransportState(peerID),
              authenticated.capabilities.contains(.doubleRatchet),
              let relationship = favoritesService.getFavoriteStatus(
                for: authenticated.noisePublicKey
              ),
              relationship.isMutual,
              let peerNostrKey = relationship.peerNostrPublicKey,
              let peerPubkeyHex = Self.ndrNostrPubkeyHex(from: peerNostrKey),
              favoritesService.canUseNdrBinding(
                peerNoisePublicKey: authenticated.noisePublicKey,
                peerNostrPublicKey: peerNostrKey
              ),
              let currentIdentity = try? idBridge.getCurrentNostrIdentity()
        else {
            return
        }

        ndrService.configureIfNeeded(
            identity: currentIdentity,
            processPendingActions: false
        )
        guard prepareDoubleRatchetPeerBinding(
            peerID: peerID,
            noisePublicKey: authenticated.noisePublicKey,
            peerPubkeyHex: peerPubkeyHex,
            currentIdentityPubkeyHex: currentIdentity.publicKeyHex
        ) else {
            return
        }
        if ndrService.hasPairwiseSession(with: peerPubkeyHex) {
            guard favoritesService.markNdrRequired(
                for: authenticated.noisePublicKey
            ) else {
                return
            }
            ndrService.configureIfNeeded(identity: currentIdentity)
        }
        let shouldReleaseDeferredOutOfBand =
            ndrOutOfBandGenerationByPeer[peerID]
                != authenticated.sessionGeneration
        ndrOutOfBandGenerationByPeer[peerID] =
            authenticated.sessionGeneration
        sendNdrOutOfBandActions(
            ndrService.pendingOutOfBandActions(
                forAuthenticatedPeerPubkeyHex: peerPubkeyHex,
                releaseDeferred: shouldReleaseDeferredOutOfBand
            ),
            to: peerID,
            peerPubkeyHex: peerPubkeyHex,
            expectedTransportState: authenticated
        )
        if ndrService.hasPairwiseSession(with: peerPubkeyHex) {
            ndrInviteAttemptTokenByPeer.removeValue(forKey: peerID)
            return
        }
        guard let invite = ndrService.currentInviteAction() else { return }
        let inviteAttemptToken = [
            authenticated.sessionGeneration.uuidString,
            peerPubkeyHex,
            invite.eventID
        ].joined(separator: "|")
        guard ndrInviteAttemptTokenByPeer[peerID] != inviteAttemptToken else {
            return
        }
        ndrInviteAttemptTokenByPeer[peerID] = inviteAttemptToken

        SecureLogger.debug(
            "NDR: OOB invite -> \(peerID.id.prefix(8))… peer=\(peerPubkeyHex.prefix(8))…",
            category: .session
        )
        sendNdrInvite(
            invite,
            to: peerID,
            peerPubkeyHex: peerPubkeyHex,
            expectedTransportState: authenticated,
            inviteAttemptToken: inviteAttemptToken
        )
    }

    func handleNdrEventPayload(from peerID: PeerID, payload: Data) {
        guard ndrService.isRolloutEnabled,
              let ndrTransport,
              let eventJson = String(data: payload, encoding: .utf8),
              !eventJson.isEmpty,
              let authenticated =
                ndrTransport.authenticatedPeerTransportState(peerID),
              authenticated.capabilities.contains(.doubleRatchet),
              let relationship = favoritesService.getFavoriteStatus(
                for: authenticated.noisePublicKey
              ),
              relationship.isMutual,
              let peerNostrKey = relationship.peerNostrPublicKey,
              let peerPubkeyHex = Self.ndrNostrPubkeyHex(from: peerNostrKey),
              favoritesService.canUseNdrBinding(
                peerNoisePublicKey: authenticated.noisePublicKey,
                peerNostrPublicKey: peerNostrKey
              ),
              let currentIdentity = try? idBridge.getCurrentNostrIdentity()
        else {
            return
        }

        let isExpectedBindingCurrent: () -> Bool = { [weak self] in
            self?.isCurrentDoubleRatchetBinding(
                peerID: peerID,
                expectedTransportState: authenticated,
                expectedPeerPubkeyHex: peerPubkeyHex
            ) == true
        }
        ndrService.configureIfNeeded(
            identity: currentIdentity,
            processPendingActions: false
        )
        guard prepareDoubleRatchetPeerBinding(
            peerID: peerID,
            noisePublicKey: authenticated.noisePublicKey,
            peerPubkeyHex: peerPubkeyHex,
            currentIdentityPubkeyHex: currentIdentity.publicKeyHex
        ) else {
            return
        }
        let actions = ndrService.processOutOfBandEventJson(
            eventJson,
            expectedPeerPubkeyHex: peerPubkeyHex,
            authorization: isExpectedBindingCurrent,
            persistEstablishedBinding: { [weak self] in
                self?.favoritesService.markNdrRequired(
                    for: authenticated.noisePublicKey
                ) == true
            }
        )
        sendNdrOutOfBandActions(
            actions,
            to: peerID,
            peerPubkeyHex: peerPubkeyHex,
            expectedTransportState: authenticated
        )
    }

    private func sendNdrOutOfBandActions(
        _ actions: [NdrOutOfBandAction],
        to peerID: PeerID,
        peerPubkeyHex: String,
        expectedTransportState: AuthenticatedPeerTransportState
    ) {
        for action in actions {
            sendNdrOutOfBandAction(
                action,
                to: peerID,
                peerPubkeyHex: peerPubkeyHex,
                expectedTransportState: expectedTransportState,
                retryAttempt: 0
            )
        }
    }

    private func sendNdrInvite(
        _ invite: NdrInviteAction,
        to peerID: PeerID,
        peerPubkeyHex: String,
        expectedTransportState: AuthenticatedPeerTransportState,
        inviteAttemptToken: String,
        retryAttempt: Int = 0
    ) {
        guard let ndrTransport,
              ndrInviteAttemptTokenByPeer[peerID] == inviteAttemptToken,
              !ndrService.hasPairwiseSession(with: peerPubkeyHex),
              ndrService.isCurrentInviteAction(invite),
              isCurrentDoubleRatchetBinding(
                peerID: peerID,
                expectedTransportState: expectedTransportState,
                expectedPeerPubkeyHex: peerPubkeyHex
              )
        else {
            if ndrInviteAttemptTokenByPeer[peerID] == inviteAttemptToken {
                ndrInviteAttemptTokenByPeer.removeValue(forKey: peerID)
            }
            return
        }

        ndrTransport.sendNdrEvent(
            to: peerID,
            eventJson: invite.eventJson,
            expectedTransportState: expectedTransportState,
            completion: { [weak self] succeeded in
                guard !succeeded, let self else { return }
                guard self.ndrInviteAttemptTokenByPeer[peerID]
                        == inviteAttemptToken
                else {
                    return
                }
                self.ndrService.scheduleHostTransientRetry(
                    after: retryAttempt
                ) {
                    [weak self] in
                    self?.sendNdrInvite(
                        invite,
                        to: peerID,
                        peerPubkeyHex: peerPubkeyHex,
                        expectedTransportState: expectedTransportState,
                        inviteAttemptToken: inviteAttemptToken,
                        retryAttempt: retryAttempt + 1
                    )
                }
            }
        )
    }

    private func sendNdrOutOfBandAction(
        _ action: NdrOutOfBandAction,
        to peerID: PeerID,
        peerPubkeyHex: String,
        expectedTransportState: AuthenticatedPeerTransportState,
        retryAttempt: Int
    ) {
        guard let ndrTransport,
              action.peerPubkeyHex == peerPubkeyHex,
              isCurrentDoubleRatchetBinding(
                peerID: peerID,
                expectedTransportState: expectedTransportState,
                expectedPeerPubkeyHex: peerPubkeyHex
              )
        else {
            ndrService.completeOutOfBandAction(
                action,
                succeeded: false
            )
            return
        }

        let service = ndrService
        ndrTransport.sendNdrEvent(
            to: peerID,
            eventJson: action.eventJson,
            expectedTransportState: expectedTransportState,
            completion: { [weak self] succeeded in
                service.completeOutOfBandAction(
                    action,
                    succeeded: succeeded
                )
                guard !succeeded, let self else { return }
                self.ndrService.scheduleHostTransientRetry(
                    after: retryAttempt
                ) {
                    [weak self] in
                    guard let self else { return }
                    guard self.isCurrentDoubleRatchetBinding(
                            peerID: peerID,
                            expectedTransportState: expectedTransportState,
                            expectedPeerPubkeyHex: peerPubkeyHex
                          )
                    else {
                        if self.ndrOutOfBandGenerationByPeer[peerID]
                            == expectedTransportState.sessionGeneration
                        {
                            self.ndrOutOfBandGenerationByPeer
                                .removeValue(forKey: peerID)
                        }
                        return
                    }
                    guard
                          service.prepareOutOfBandActionForRetry(action)
                    else {
                        return
                    }
                    self.sendNdrOutOfBandAction(
                        action,
                        to: peerID,
                        peerPubkeyHex: peerPubkeyHex,
                        expectedTransportState: expectedTransportState,
                        retryAttempt: retryAttempt + 1
                    )
                }
            }
        )
    }

    private func isCurrentDoubleRatchetBinding(
        peerID: PeerID,
        expectedTransportState: AuthenticatedPeerTransportState,
        expectedPeerPubkeyHex: String
    ) -> Bool {
        guard let ndrTransport,
              ndrTransport.authenticatedPeerTransportState(peerID)
                == expectedTransportState,
              expectedTransportState.capabilities.contains(.doubleRatchet),
              let relationship = favoritesService.getFavoriteStatus(
                for: expectedTransportState.noisePublicKey
              ),
              relationship.isMutual,
              let peerNostrKey = relationship.peerNostrPublicKey,
              Self.ndrNostrPubkeyHex(from: peerNostrKey)
                == expectedPeerPubkeyHex,
              favoritesService.canUseNdrBinding(
                peerNoisePublicKey:
                    expectedTransportState.noisePublicKey,
                peerNostrPublicKey: peerNostrKey
              )
        else {
            return false
        }
        return true
    }

    private func prepareDoubleRatchetPeerBinding(
        peerID: PeerID,
        noisePublicKey: Data,
        peerPubkeyHex: String,
        currentIdentityPubkeyHex: String
    ) -> Bool {
        let identityPubkeyHex = currentIdentityPubkeyHex.lowercased()
        if ndrBindingIdentityPubkeyHex != identityPubkeyHex {
            ndrInviteAttemptTokenByPeer.removeAll()
            ndrOutOfBandGenerationByPeer.removeAll()
            ndrPeerPubkeyByNoiseKey.removeAll()
            ndrBindingIdentityPubkeyHex = identityPubkeyHex
        }

        if let previousPeerPubkeyHex =
            ndrPeerPubkeyByNoiseKey[noisePublicKey],
           previousPeerPubkeyHex != peerPubkeyHex
        {
            guard ndrService.retirePeer(previousPeerPubkeyHex) else {
                return false
            }
            ndrInviteAttemptTokenByPeer.removeValue(forKey: peerID)
            ndrOutOfBandGenerationByPeer.removeValue(forKey: peerID)
        }
        ndrPeerPubkeyByNoiseKey[noisePublicKey] = peerPubkeyHex
        return true
    }

    func authorizeDoubleRatchetFavoriteRebind(
        noisePublicKey: Data,
        oldNostrPublicKey: String?,
        newNostrPublicKey: String
    ) -> Bool {
        guard let newPeerPubkeyHex =
                Self.ndrNostrPubkeyHex(from: newNostrPublicKey)
        else {
            // A malformed destination cannot be collision-checked.
            return false
        }
        let oldPeerPubkeyHex: String?
        if let oldNostrPublicKey {
            guard let normalized =
                    Self.ndrNostrPubkeyHex(from: oldNostrPublicKey)
            else {
                // A malformed existing binding cannot be safely retired.
                return false
            }
            oldPeerPubkeyHex = normalized
        } else {
            oldPeerPubkeyHex = nil
        }
        guard oldPeerPubkeyHex != newPeerPubkeyHex else { return true }
        let otherFavoritePubkeys =
            favoritesService.peerNostrPublicKeys(
                excludingNoisePublicKey: noisePublicKey
            )
            .compactMap { Self.ndrNostrPubkeyHex(from: $0) }
        guard !otherFavoritePubkeys.contains(newPeerPubkeyHex) else {
            // A Nostr identity may have only one stable Noise binding. Without
            // this, two radio identities could both authorize the same ratchet.
            return false
        }
        guard let oldPeerPubkeyHex else {
            // Initial and nil-to-value assignments have nothing to retire.
            return true
        }
        guard ndrService.isRolloutEnabled else {
            // FavoritesPersistenceService still journals and commits a
            // previously pinned binding while rollout is dark. There is no
            // new session to discover or pin on this path.
            return true
        }
        guard let currentIdentity =
                try? idBridge.getCurrentNostrIdentity()
        else {
            return false
        }

        ndrService.configureIfNeeded(
            identity: currentIdentity,
            processPendingActions: false
        )
        guard ndrService.isConfigured else {
            return false
        }
        if ndrService.hasPairwiseSession(with: oldPeerPubkeyHex) {
            return favoritesService.markNdrRequired(
                for: noisePublicKey
            )
        }
        return true
    }

    func commitDoubleRatchetFavoriteRebind(
        noisePublicKey: Data,
        oldNostrPublicKey: String,
        newNostrPublicKey: String
    ) -> Bool {
        guard let oldPeerPubkeyHex =
                Self.ndrNostrPubkeyHex(from: oldNostrPublicKey),
              let newPeerPubkeyHex =
                Self.ndrNostrPubkeyHex(from: newNostrPublicKey),
              let currentIdentity =
                try? idBridge.getCurrentNostrIdentity()
        else {
            return false
        }
        // Representation-only changes (hex ↔ npub or case) carry no
        // retirement intent. Returning success also recovers journals written
        // by an older build before equivalent keys were normalized.
        guard oldPeerPubkeyHex != newPeerPubkeyHex else {
            return true
        }
        let otherFavoritePubkeys =
            favoritesService.peerNostrPublicKeys(
                excludingNoisePublicKey: noisePublicKey
            )
            .compactMap { Self.ndrNostrPubkeyHex(from: $0) }
        guard !otherFavoritePubkeys.contains(newPeerPubkeyHex) else {
            return false
        }

        // Configuration and retirement are intentionally action-silent here:
        // the durable rebind journal exists, but the target favorite has not
        // been committed yet. Relay work resumes through the normal setup/send
        // path only after FavoritesPersistenceService verifies that commit.
        guard ndrService.configureIfNeeded(
            identity: currentIdentity,
            processPendingActions: false,
            allowDisabledMaintenance: true
        ) else {
            return false
        }
        if !otherFavoritePubkeys.contains(oldPeerPubkeyHex),
           !ndrService.retirePeer(
                oldPeerPubkeyHex,
                processPendingActions: false,
                allowDisabledMaintenance: true
           )
        {
            return false
        }
        let reboundPeerIDs = ndrOutOfBandGenerationByPeer.keys.filter {
            ndrTransport?.authenticatedPeerTransportState($0)?
                .noisePublicKey == noisePublicKey
        }
        for peerID in reboundPeerIDs {
            ndrInviteAttemptTokenByPeer.removeValue(forKey: peerID)
            ndrOutOfBandGenerationByPeer.removeValue(forKey: peerID)
        }
        ndrPeerPubkeyByNoiseKey[noisePublicKey] = newPeerPubkeyHex
        ndrBindingIdentityPubkeyHex =
            currentIdentity.publicKeyHex.lowercased()
        return true
    }

    static func ndrNostrPubkeyHex(from npubOrHex: String) -> String? {
        let lowered = npubOrHex.lowercased()
        if lowered.hasPrefix("npub") {
            guard let (hrp, data) = try? Bech32.decode(lowered),
                  hrp == "npub",
                  data.count == 32
            else {
                return nil
            }
            return data.hexEncodedString()
        }

        guard lowered.count == 64,
              lowered.allSatisfy(\.isHexDigit)
        else {
            return nil
        }
        return lowered
    }
}

final class ChatTransportEventCoordinator {
    private unowned let context: any ChatTransportEventContext

    init(context: any ChatTransportEventContext) {
        self.context = context
    }

    func didReceiveMessage(_ message: BitchatMessage) {
        runOnMain { [self] context in
            handleReceivedMessage(message, in: context)
        }
    }

    /// Typed transport events already arrive on the main actor. Handle them
    /// synchronously so observers see the ConversationStore mutation before
    /// the transport completes delivery.
    @MainActor
    @discardableResult
    func didReceiveMessageSynchronously(_ message: BitchatMessage) -> Bool {
        handleReceivedMessage(message, in: context)
    }

    func didReceivePublicMessage(
        from peerID: PeerID,
        nickname: String,
        content: String,
        timestamp: Date,
        messageID: String?
    ) {
        runOnMain { [self] context in
            handlePublicMessage(
                from: peerID,
                nickname: nickname,
                content: content,
                timestamp: timestamp,
                messageID: messageID,
                in: context
            )
        }
    }

    @MainActor
    func didReceivePublicMessageSynchronously(
        from peerID: PeerID,
        nickname: String,
        content: String,
        timestamp: Date,
        messageID: String?
    ) {
        handlePublicMessage(
            from: peerID,
            nickname: nickname,
            content: content,
            timestamp: timestamp,
            messageID: messageID,
            in: context
        )
    }

    func didReceiveNoisePayload(
        from peerID: PeerID,
        type: NoisePayloadType,
        payload: Data,
        timestamp: Date
    ) {
        runOnMain { [self] context in
            handleNoisePayload(
                from: peerID,
                type: type,
                payload: payload,
                timestamp: timestamp,
                in: context
            )
        }
    }

    @MainActor
    func didReceiveNoisePayloadSynchronously(
        from peerID: PeerID,
        type: NoisePayloadType,
        payload: Data,
        timestamp: Date
    ) {
        handleNoisePayload(
            from: peerID,
            type: type,
            payload: payload,
            timestamp: timestamp,
            in: context
        )
    }

    func didConnectToPeer(_ peerID: PeerID) {
        runOnMain { [weak self] _ in
            self?.didConnectToPeerSynchronously(peerID)
        }
    }

    @MainActor
    func didConnectToPeerSynchronously(_ peerID: PeerID) {
        SecureLogger.debug("🤝 Peer connected: \(peerID)", category: .session)

        context.isConnected = true
        context.registerEphemeralSession(peerID: peerID)
        context.notifyUIChanged()

        if let peer = context.unifiedPeer(for: peerID) {
            let stablePeerID = PeerID(hexData: peer.noisePublicKey)
            context.cacheStablePeerID(stablePeerID, for: peerID)
        }

        context.flushRouterOutbox(for: peerID)
        context.retryCourierDeposits(via: peerID)
        context.bootstrapDoubleRatchetIfNeeded(for: peerID)
    }

    func didDisconnectFromPeer(_ peerID: PeerID) {
        runOnMain { [weak self] _ in
            self?.didDisconnectFromPeerSynchronously(peerID)
        }
    }

    @MainActor
    func didDisconnectFromPeerSynchronously(_ peerID: PeerID) {
        SecureLogger.debug("👋 Peer disconnected: \(peerID)", category: .session)

        context.removeEphemeralSession(peerID: peerID)

        var stablePeerID = context.cachedStablePeerID(for: peerID)
        if stablePeerID == nil,
           let key = context.noiseSessionPublicKeyData(for: peerID) {
            let derivedPeerID = PeerID(hexData: key)
            context.cacheStablePeerID(derivedPeerID, for: peerID)
            stablePeerID = derivedPeerID
        }

        if let currentPeerID = context.selectedPrivateChatPeer,
           currentPeerID == peerID,
           let stablePeerID {
            migrateSelectedConversationIfNeeded(
                from: peerID,
                to: stablePeerID,
                in: context
            )
        }

        let receiptIDs = context.privateMessages(for: peerID)
            .filter { $0.senderPeerID == peerID }
            .map(\.id)
        context.unmarkReadReceiptsSent(receiptIDs)

        context.notifyUIChanged()
    }
}

private extension ChatTransportEventCoordinator {
    @MainActor
    func handlePublicMessage(
        from peerID: PeerID,
        nickname: String,
        content: String,
        timestamp: Date,
        messageID: String?,
        in context: any ChatTransportEventContext
    ) {
        let normalized = content.trimmed
        let mentions = context.parseMentions(from: normalized)
        let message = BitchatMessage(
            id: messageID,
            sender: nickname,
            content: normalized,
            timestamp: timestamp,
            isRelay: false,
            originalSender: nil,
            isPrivate: false,
            recipientNickname: nil,
            senderPeerID: peerID,
            mentions: mentions.isEmpty ? nil : mentions
        )

        context.handlePublicMessage(message)
        context.checkForMentions(message)
        context.sendHapticFeedback(for: message)
    }

    @MainActor
    @discardableResult
    func handleReceivedMessage(
        _ message: BitchatMessage,
        in context: any ChatTransportEventContext
    ) -> Bool {
        guard !context.isMessageBlocked(message) else { return false }
        guard !message.content.trimmed.isEmpty || message.isPrivate else { return false }

        if message.isPrivate {
            context.handlePrivateMessage(message)
        } else {
            context.handlePublicMessage(message)
        }

        context.checkForMentions(message)
        context.sendHapticFeedback(for: message)
        return true
    }

    func runOnMain(_ action: @escaping @MainActor (any ChatTransportEventContext) -> Void) {
        Task { @MainActor [weak context = self.context] in
            guard let context else { return }
            action(context)
        }
    }

    @MainActor
    func migrateSelectedConversationIfNeeded(
        from shortPeerID: PeerID,
        to stablePeerID: PeerID,
        in context: any ChatTransportEventContext
    ) {
        let hadUnread = context.unreadPrivateMessages.contains(shortPeerID)

        let shortPeerMessages = context.privateMessages(for: shortPeerID)
        if !shortPeerMessages.isEmpty {
            for message in shortPeerMessages {
                // Rewrite senderPeerID to the stable key so read receipts
                // keep working; store append dedups by ID and keeps order.
                let migrated = BitchatMessage(
                    id: message.id,
                    sender: message.sender,
                    content: message.content,
                    timestamp: message.timestamp,
                    isRelay: message.isRelay,
                    originalSender: message.originalSender,
                    isPrivate: message.isPrivate,
                    recipientNickname: message.recipientNickname,
                    senderPeerID: message.senderPeerID == context.myPeerID
                        ? context.myPeerID
                        : stablePeerID,
                    mentions: message.mentions,
                    deliveryStatus: message.deliveryStatus
                )
                context.appendPrivateMessage(migrated, to: stablePeerID)
            }

            context.removePrivateChat(shortPeerID)
        }

        if hadUnread {
            context.markPrivateChatRead(shortPeerID)
            context.markPrivateChatUnread(stablePeerID)
        }

        context.selectedPrivateChatPeer = stablePeerID
    }

    @MainActor
    func handleNoisePayload(
        from peerID: PeerID,
        type: NoisePayloadType,
        payload: Data,
        timestamp: Date,
        in context: any ChatTransportEventContext
    ) {
        switch type {
        case .privateMessage:
            guard let packet = PrivateMessagePacket.decode(from: payload) else { return }

            guard !context.isPeerBlocked(peerID) else {
                SecureLogger.debug("🚫 Ignoring Noise payload from blocked peer: \(peerID)", category: .security)
                return
            }

            let senderName = context.unifiedPeer(for: peerID)?.nickname ?? "Unknown"
            let mentions = context.parseMentions(from: packet.content)
            let message = BitchatMessage(
                id: packet.messageID,
                sender: senderName,
                content: packet.content,
                timestamp: timestamp,
                isRelay: false,
                originalSender: nil,
                isPrivate: true,
                recipientNickname: context.nickname,
                senderPeerID: peerID,
                mentions: mentions.isEmpty ? nil : mentions
            )
            context.handlePrivateMessage(message)
            context.sendMeshDeliveryAck(for: packet.messageID, to: peerID)

        case .delivered:
            guard let messageID = String(data: payload, encoding: .utf8) else { return }

            let name = deliveryStatusName(for: peerID, in: context)
            let didUpdate = context.applyAcknowledgedMessageDeliveryStatus(
                messageID,
                status: .delivered(to: name, at: Date()),
                from: receiptPeerAliases(for: peerID, in: context)
            )

            if !didUpdate {
                if case .read? = context.deliveryStatus(for: messageID) {
                    SecureLogger.debug("📬 Ignored stale delivered ACK for already-read message id=\(messageID.prefix(8))… from \(peerID.id.prefix(8))…", category: .session)
                } else {
                    SecureLogger.debug("📬 Delivered ACK for unknown message id=\(messageID.prefix(8))… from \(peerID.id.prefix(8))…", category: .session)
                }
            }

        case .readReceipt:
            guard let messageID = String(data: payload, encoding: .utf8) else { return }

            let name = deliveryStatusName(for: peerID, in: context)
            let didUpdate = context.applyAcknowledgedMessageDeliveryStatus(
                messageID,
                status: .read(by: name, at: Date()),
                from: receiptPeerAliases(for: peerID, in: context)
            )

            if !didUpdate {
                SecureLogger.debug("📖 Read receipt for unknown message id=\(messageID.prefix(8))… from \(peerID.id.prefix(8))…", category: .session)
            }

        case .verifyChallenge:
            context.handleVerifyChallengePayload(from: peerID, payload: payload)

        case .verifyResponse:
            context.handleVerifyResponsePayload(from: peerID, payload: payload)

        case .groupInvite:
            context.handleGroupInvitePayload(from: peerID, payload: payload)

        case .groupKeyUpdate:
            context.handleGroupKeyUpdatePayload(from: peerID, payload: payload)

        case .vouch:
            context.handleVouchPayload(from: peerID, payload: payload)

        case .ndrEvent:
            context.handleNdrEventPayload(from: peerID, payload: payload)

        case .voiceFrame:
            context.handleVoiceFramePayload(from: peerID, payload: payload, timestamp: timestamp)

        case .privateFile, .authenticatedPeerState:
            // BLEService validates and persists decrypted private files before
            // emitting a normal `.messageReceived` event, and consumes peer
            // state inside the transport. Neither payload crosses this
            // UI-facing typed-payload fallback.
            break
        }
    }

    @MainActor
    func deliveryStatusName(for peerID: PeerID, in context: any ChatTransportEventContext) -> String {
        context.unifiedPeer(for: peerID)?.nickname ?? context.resolveNickname(for: peerID)
    }

    @MainActor
    func receiptPeerAliases(
        for peerID: PeerID,
        in context: any ChatTransportEventContext
    ) -> Set<PeerID> {
        var aliases: Set<PeerID> = [peerID]
        // The active authenticated Noise key is authoritative. A cached
        // ephemeral→stable mapping can predate an identity replacement, so
        // use it only when the live session cannot provide its static key.
        if let keyData = context.noiseSessionPublicKeyData(for: peerID) {
            aliases.insert(PeerID(hexData: keyData))
        } else if let stablePeerID = context.cachedStablePeerID(for: peerID) {
            aliases.insert(stablePeerID)
        }
        return aliases
    }
}

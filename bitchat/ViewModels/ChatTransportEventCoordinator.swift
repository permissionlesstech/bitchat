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
    /// Applies the status to every known location of the message.
    /// Returns `false` when no message with that ID was updated.
    @discardableResult
    func applyMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) -> Bool
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
    func applyMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) -> Bool {
        deliveryCoordinator.updateMessageDeliveryStatus(messageID, status: status)
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
}

final class ChatTransportEventCoordinator {
    private unowned let context: any ChatTransportEventContext

    init(context: any ChatTransportEventContext) {
        self.context = context
    }

    func didReceiveMessage(_ message: BitchatMessage) {
        runOnMain { context in
            guard !context.isMessageBlocked(message) else { return }
            guard !message.content.trimmed.isEmpty || message.isPrivate else { return }

            if message.isPrivate {
                context.handlePrivateMessage(message)
            } else {
                context.handlePublicMessage(message)
            }

            context.checkForMentions(message)
            context.sendHapticFeedback(for: message)
        }
    }

    func didReceivePublicMessage(
        from peerID: PeerID,
        nickname: String,
        content: String,
        timestamp: Date,
        messageID: String?
    ) {
        runOnMain { context in
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

    func didConnectToPeer(_ peerID: PeerID) {
        SecureLogger.debug("🤝 Peer connected: \(peerID)", category: .session)

        runOnMain { context in
            context.isConnected = true
            context.registerEphemeralSession(peerID: peerID)
            context.notifyUIChanged()

            if let peer = context.unifiedPeer(for: peerID) {
                let stablePeerID = PeerID(hexData: peer.noisePublicKey)
                context.cacheStablePeerID(stablePeerID, for: peerID)
            }

            context.flushRouterOutbox(for: peerID)
            context.retryCourierDeposits(via: peerID)
        }
    }

    func didDisconnectFromPeer(_ peerID: PeerID) {
        SecureLogger.debug("👋 Peer disconnected: \(peerID)", category: .session)

        runOnMain { context in
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
                self.migrateSelectedConversationIfNeeded(
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
}

private extension ChatTransportEventCoordinator {
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
            let didUpdate = context.applyMessageDeliveryStatus(
                messageID,
                status: .delivered(to: name, at: Date())
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
            let didUpdate = context.applyMessageDeliveryStatus(
                messageID,
                status: .read(by: name, at: Date())
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

        case .voiceFrame:
            context.handleVoiceFramePayload(from: peerID, payload: payload, timestamp: timestamp)
        }
    }

    @MainActor
    func deliveryStatusName(for peerID: PeerID, in context: any ChatTransportEventContext) -> String {
        context.unifiedPeer(for: peerID)?.nickname ?? context.resolveNickname(for: peerID)
    }
}

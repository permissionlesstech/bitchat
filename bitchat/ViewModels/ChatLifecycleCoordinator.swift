import BitFoundation
import BitLogger
import Foundation

/// The narrow surface `ChatLifecycleCoordinator` needs from its owner.
///
/// Follows the `ChatDeliveryContext` exemplar: the coordinator depends on the
/// minimal context it actually uses instead of holding an `unowned` back-ref
/// to the whole `ChatViewModel`. This keeps the coordinator independently
/// testable (see `ChatLifecycleCoordinatorContextTests`) and makes its true
/// dependencies explicit.
@MainActor
protocol ChatLifecycleContext: AnyObject {
    // MARK: Chat & receipt state
    var messages: [BitchatMessage] { get }
    /// A single private chat's timeline (store-direct lookup on
    /// `ChatViewModel`; no `privateChats` dictionary build).
    func privateMessages(for peerID: PeerID) -> [BitchatMessage]
    var unreadPrivateMessages: Set<PeerID> { get }
    var selectedPrivateChatPeer: PeerID? { get }
    /// Appends a private message via the single-writer store intent.
    @discardableResult
    func appendPrivateMessage(_ message: BitchatMessage, to peerID: PeerID) -> Bool
    /// Clears the peer's unread flag (store unread state only).
    func markPrivateChatRead(_ peerID: PeerID)
    var sentReadReceipts: Set<String> { get }
    var nickname: String { get }
    var myPeerID: PeerID { get }
    var activeChannel: ChannelID { get }
    var nostrKeyMapping: [PeerID: String] { get }
    /// Records that a read receipt is being sent for `messageID`.
    /// Returns `false` when one was already recorded — the caller must skip sending.
    @discardableResult
    func markReadReceiptSent(_ messageID: String) -> Bool
    /// The owner-level read pass (chat manager + receipts); used for the
    /// delayed re-run after the app becomes active.
    func markPrivateMessagesAsRead(from peerID: PeerID)
    /// Marks the chat read in the private chat manager (sends pending mesh READ acks).
    func markChatAsRead(from peerID: PeerID)
    /// Schedules main-actor work after a UI-timing delay. Injected so tests
    /// can run the work synchronously instead of polling wall-clock queues.
    func scheduleOnMainAfter(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void)
    func addSystemMessage(_ content: String)

    // MARK: Peers & sessions
    func peerNickname(for peerID: PeerID) -> String?
    /// The peer's current entry in the unified peer service, if known.
    func unifiedPeer(for peerID: PeerID) -> BitchatPeer?
    func noiseSessionState(for peerID: PeerID) -> LazyHandshakeState
    func stopMeshServices()
    /// Re-reads the transport's current Bluetooth state and updates the alert UI.
    func refreshBluetoothState()

    // MARK: Routing & receipts
    func routePrivateMessage(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String)
    @discardableResult
    func routeReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) -> Bool
    func sendMeshMessage(_ content: String, mentions: [String], messageID: String, timestamp: Date)
    func sendGeohashReadReceipt(_ messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity)

    // MARK: Nostr & geohash
    var isTeleported: Bool { get }
    func deriveNostrIdentity(forGeohash geohash: String) throws -> NostrIdentity
    func recordGeoParticipant(pubkeyHex: String)

    // MARK: Favorites (shared with `ChatPrivateConversationContext`)
    /// The persisted favorite relationship for the peer's Noise static key, if any.
    func favoriteRelationship(forNoiseKey noiseKey: Data) -> FavoritesPersistenceService.FavoriteRelationship?

    // MARK: Identity persistence
    /// Forces the identity manager to persist its state now.
    func forceSaveIdentity()
    /// Confirms the Noise identity key is still present in the keychain.
    @discardableResult
    func verifyIdentityKeyExists() -> Bool
}

extension ChatViewModel: ChatLifecycleContext {
    // `messages`, `privateMessages(for:)`, `unreadPrivateMessages`,
    // `selectedPrivateChatPeer`, `sentReadReceipts`, `nickname`, `myPeerID`,
    // `activeChannel`, `nostrKeyMapping`, `markReadReceiptSent(_:)`,
    // `markPrivateMessagesAsRead(from:)`, `appendPrivateMessage(_:to:)`,
    // `markPrivateChatRead(_:)`, `addSystemMessage(_:)`,
    // `peerNickname(for:)`, `unifiedPeer(for:)`, `noiseSessionState(for:)`,
    // the routing/ack members, `isTeleported`,
    // `deriveNostrIdentity(forGeohash:)`, `recordGeoParticipant(pubkeyHex:)`,
    // and `favoriteRelationship(forNoiseKey:)`
    // are shared requirements with the other contexts or satisfied by
    // existing `ChatViewModel` members. The members below flatten nested
    // service accesses into intent-named calls.

    func markChatAsRead(from peerID: PeerID) {
        privateChatManager.markAsRead(from: peerID)
    }

    func scheduleOnMainAfter(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Task { @MainActor in
                work()
            }
        }
    }

    func stopMeshServices() {
        meshService.stopServices()
    }

    func refreshBluetoothState() {
        if let bleService = meshService as? BLEService {
            updateBluetoothState(bleService.getCurrentBluetoothState())
        }
    }

    func forceSaveIdentity() {
        identityManager.forceSave()
    }

    @discardableResult
    func verifyIdentityKeyExists() -> Bool {
        keychain.verifyIdentityKeyExists()
    }
}

@MainActor
final class ChatLifecycleCoordinator {
    private unowned let context: any ChatLifecycleContext

    init(context: any ChatLifecycleContext) {
        self.context = context
    }

    func handleDidBecomeActive() {
        context.refreshBluetoothState()

        guard let peerID = context.selectedPrivateChatPeer else { return }

        markPrivateMessagesAsRead(from: peerID)

        let context = self.context
        context.scheduleOnMainAfter(TransportConfig.uiAnimationMediumSeconds) { [weak context] in
            context?.markPrivateMessagesAsRead(from: peerID)
        }
    }

    func handleScreenshotCaptured() {
        let screenshotMessage = "* \(context.nickname) took a screenshot *"

        if let peerID = context.selectedPrivateChatPeer {
            sendPrivateScreenshotNotificationIfPossible(
                screenshotMessage,
                to: peerID
            )
            appendPrivateScreenshotNotice(for: peerID)
            return
        }

        switch context.activeChannel {
        case .mesh:
            context.sendMeshMessage(
                screenshotMessage,
                mentions: [],
                messageID: UUID().uuidString,
                timestamp: Date()
            )

        case .location(let channel):
            sendPublicGeohashScreenshotMessage(
                screenshotMessage,
                channel: channel
            )
        }

        context.addSystemMessage("you took a screenshot")
    }

    func saveIdentityState() {
        context.forceSaveIdentity()
        context.verifyIdentityKeyExists()
    }

    func applicationWillTerminate() {
        context.stopMeshServices()
        saveIdentityState()
    }

    func markPrivateMessagesAsRead(from peerID: PeerID) {
        context.markChatAsRead(from: peerID)

        // Group chats are keyed under a virtual group_ peerID; no member IS the
        // conversation peer, so the receipt loops below (which gate on
        // senderPeerID == peerID) must never emit a read/delivered receipt for
        // one. This guard makes that explicit so a future refactor of the
        // receipt matching can't silently start leaking receipts into groups.
        guard !peerID.isGroup else { return }

        if peerID.isGeoDM,
           let recipientHex = context.nostrKeyMapping[peerID],
           case .location(let channel) = context.activeChannel,
           let identity = try? context.deriveNostrIdentity(forGeohash: channel.geohash) {
            let messages = context.privateMessages(for: peerID)
            for message in messages where message.senderPeerID == peerID && !message.isRelay {
                guard !context.sentReadReceipts.contains(message.id) else { continue }

                SecureLogger.debug(
                    "GeoDM: sending READ for mid=\(message.id.prefix(8))… to=\(recipientHex.prefix(8))…",
                    category: .session
                )
                context.sendGeohashReadReceipt(
                    message.id,
                    toRecipientHex: recipientHex,
                    from: identity
                )
                context.markReadReceiptSent(message.id)
            }
            return
        }

        var noiseKeyHex: PeerID?

        if let noiseKey = Data(hexString: peerID.id),
           context.favoriteRelationship(forNoiseKey: noiseKey) != nil {
            noiseKeyHex = peerID
        } else if let peer = context.unifiedPeer(for: peerID) {
            noiseKeyHex = PeerID(hexData: peer.noisePublicKey)

            if let noiseKeyHex, context.unreadPrivateMessages.contains(noiseKeyHex) {
                context.markPrivateChatRead(noiseKeyHex)
            }
        }

        // No Nostr-key gate here: the router picks whatever transport can
        // reach the peer (mesh included), so read receipts must flow for
        // non-favorite mesh peers too. `sentReadReceipts` dedups against the
        // PrivateChatManager path; the router drops receipts it can't route.

        for message in getPrivateChatMessages(for: peerID) {
            guard (message.senderPeerID == peerID || message.senderPeerID == noiseKeyHex) && !message.isRelay else {
                continue
            }

            guard !context.sentReadReceipts.contains(message.id) else { continue }

            let receipt = ReadReceipt(
                originalMessageID: message.id,
                readerID: context.myPeerID,
                readerNickname: context.nickname
            )
            let recipientPeerID = peerID.isHex
                ? peerID
                : (context.unifiedPeer(for: peerID)?.peerID ?? peerID)

            // Only record the receipt as sent when it actually left via a
            // reachable transport; a dropped receipt stays unmarked so the
            // next read scan retries it instead of burning it forever.
            if context.routeReadReceipt(receipt, to: recipientPeerID) {
                context.markReadReceiptSent(message.id)
            }
        }
    }

    func getMessages(for peerID: PeerID?) -> [BitchatMessage] {
        guard let peerID else { return context.messages }
        return getPrivateChatMessages(for: peerID)
    }

    func getPrivateChatMessages(for peerID: PeerID) -> [BitchatMessage] {
        var combined: [BitchatMessage] = []

        combined.append(contentsOf: context.privateMessages(for: peerID))

        if let peer = context.unifiedPeer(for: peerID) {
            let noiseKeyHex = PeerID(hexData: peer.noisePublicKey)
            if noiseKeyHex != peerID {
                combined.append(contentsOf: context.privateMessages(for: noiseKeyHex))
            }
        }

        var bestByID: [String: BitchatMessage] = [:]
        for message in combined {
            if let existing = bestByID[message.id] {
                let existingRank = deliveryStatusRank(existing.deliveryStatus)
                let candidateRank = deliveryStatusRank(message.deliveryStatus)
                if candidateRank > existingRank || (candidateRank == existingRank && message.timestamp > existing.timestamp) {
                    bestByID[message.id] = message
                }
            } else {
                bestByID[message.id] = message
            }
        }

        return bestByID.values.sorted { $0.timestamp < $1.timestamp }
    }
}

private extension ChatLifecycleCoordinator {
    func sendPrivateScreenshotNotificationIfPossible(_ message: String, to peerID: PeerID) {
        guard let peerNickname = context.peerNickname(for: peerID) else { return }

        let sessionState = context.noiseSessionState(for: peerID)
        switch sessionState {
        case .established:
            context.routePrivateMessage(
                message,
                to: peerID,
                recipientNickname: peerNickname,
                messageID: UUID().uuidString
            )

        case .none, .failed, .handshakeQueued, .handshaking:
            SecureLogger.debug(
                "Skipping screenshot notification to \(peerID) - no established session",
                category: .security
            )
        }
    }

    func appendPrivateScreenshotNotice(for peerID: PeerID) {
        let notice = BitchatMessage(
            sender: "system",
            content: "you took a screenshot",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: context.peerNickname(for: peerID),
            senderPeerID: context.myPeerID
        )

        context.appendPrivateMessage(notice, to: peerID)
    }

    func sendPublicGeohashScreenshotMessage(_ message: String, channel: GeohashChannel) {
        Task { @MainActor [weak context = self.context] in
            guard let context else { return }

            do {
                let identity = try context.deriveNostrIdentity(forGeohash: channel.geohash)
                let event = try await NostrProtocol.createMinedEphemeralGeohashEvent(
                    content: message,
                    geohash: channel.geohash,
                    senderIdentity: identity,
                    nickname: context.nickname,
                    teleported: context.isTeleported
                )

                let targetRelays = GeoRelayDirectory.shared.closestRelays(toGeohash: channel.geohash, count: 5)
                if targetRelays.isEmpty {
                    SecureLogger.warning("Geo: no geohash relays available for \(channel.geohash); not sending", category: .session)
                } else {
                    NostrRelayManager.shared.sendEvent(event, to: targetRelays)
                }

                context.recordGeoParticipant(pubkeyHex: identity.publicKeyHex)
            } catch {
                SecureLogger.error("❌ Failed to send geohash screenshot message: \(error)", category: .session)
                context.addSystemMessage(
                    String(localized: "system.location.send_failed", comment: "System message when a location channel send fails")
                )
            }
        }
    }

    func deliveryStatusRank(_ status: DeliveryStatus?) -> Int {
        guard let status else { return 0 }
        switch status {
        case .failed: return 1
        case .sending: return 2
        case .sent: return 3
        case .carried: return 4
        case .partiallyDelivered: return 5
        case .delivered: return 6
        case .read: return 7
        }
    }
}

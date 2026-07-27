import BitFoundation
import BitLogger
import Foundation

/// The narrow surface `ChatOutgoingCoordinator` needs from its owner.
///
/// Follows the `ChatDeliveryContext` exemplar: the coordinator depends on the
/// minimal context it actually uses instead of holding an `unowned` back-ref
/// to the whole `ChatViewModel`. This keeps the coordinator independently
/// testable (see `ChatOutgoingCoordinatorContextTests`) and makes its true
/// dependencies explicit.
@MainActor
protocol ChatOutgoingContext: AnyObject {
    // MARK: Identity & channel state
    var nickname: String { get }
    var myPeerID: PeerID { get }
    var activeChannel: ChannelID { get }
    var selectedPrivateChatPeer: PeerID? { get }
    var isTeleported: Bool { get }

    // MARK: Commands & private messages
    func handleCommand(_ command: String)
    func updatePrivateChatPeerIfNeeded()
    func sendPrivateMessage(_ content: String, to peerID: PeerID)

    // MARK: Public timeline (local echo)
    func parseMentions(from content: String) -> [String]
    /// Appends a public message via the single-writer store intent
    /// (immediate: the local echo must render without batching).
    @discardableResult
    func appendPublicMessage(_ message: BitchatMessage, to conversationID: ConversationID) -> Bool
    func addSystemMessage(_ content: String)

    // MARK: Content dedup
    func normalizedContentKey(_ content: String) -> String
    func recordContentKey(_ key: String, timestamp: Date)

    // MARK: Outbound routing
    /// Stamps "now" as the channel's last public activity (background nudges).
    /// (Single mutation path for the owner's `lastPublicActivityAt`; this
    /// coordinator never reads it.)
    func recordPublicActivity(forChannelKey key: String)
    func sendMeshMessage(_ content: String, mentions: [String], messageID: String, timestamp: Date)
    func sendGeohash(context: ChatViewModel.GeoOutgoingContext)
    /// Ships the bridged (rendezvous) copy of a just-sent public mesh
    /// message; no-op when the bridge is off or the send is nearby-only.
    /// Takes the origin coordinates (sender + wire timestamp) — the bridge
    /// derives the cross-device-stable mesh message ID from them, not from
    /// our local timeline UUID (which no other device can recompute).
    func bridgeOutgoingPublicMessage(_ content: String, senderPeerID: PeerID, timestamp: Date)

    // MARK: Geohash identity (shared with the other contexts)
    func deriveNostrIdentity(forGeohash geohash: String) throws -> NostrIdentity
}

extension ChatViewModel: ChatOutgoingContext {
    // `nickname`, `myPeerID`, `activeChannel`, `selectedPrivateChatPeer`,
    // `isTeleported`, `handleCommand(_:)`, `updatePrivateChatPeerIfNeeded()`,
    // `sendPrivateMessage(_:to:)`, `parseMentions(from:)`,
    // `appendPublicMessage(_:to:)`, `addSystemMessage(_:)`,
    // `normalizedContentKey(_:)`, `recordContentKey(_:timestamp:)`,
    // `sendMeshMessage(_:mentions:messageID:timestamp:)`,
    // `sendGeohash(context:)`, and `deriveNostrIdentity(forGeohash:)` are
    // shared requirements with the other contexts or satisfied by existing
    // `ChatViewModel` members. The single-writer intent op below lives next to
    // its backing state's owner.

    func recordPublicActivity(forChannelKey key: String) {
        lastPublicActivityAt[key] = Date()
    }

    func bridgeOutgoingPublicMessage(_ content: String, senderPeerID: PeerID, timestamp: Date) {
        BridgeService.shared.bridgeOutgoing(content: content, senderPeerID: senderPeerID, timestamp: timestamp)
    }
}

@MainActor
final class ChatOutgoingCoordinator {
    private unowned let context: any ChatOutgoingContext

    /// In-flight NIP-13 mining for the most recent geohash send. A newer send
    /// (or leaving the channel) cancels it, which only expedites the mining —
    /// the message still goes out at the difficulty already reached.
    /// (Read access is internal so tests can await the send's completion.)
    private(set) var geohashMiningTask: Task<Void, Never>?

    init(context: any ChatOutgoingContext) {
        self.context = context
    }

    /// Finish any in-flight geohash PoW mining early (the pending message
    /// still sends, at whatever committed difficulty it reached).
    func expeditePendingGeohashMining() {
        geohashMiningTask?.cancel()
    }

    func sendMessage(_ content: String) {
        guard let trimmed = content.trimmedOrNilIfEmpty else { return }

        if content.hasPrefix("/") {
            Task { @MainActor [weak context = self.context] in
                context?.handleCommand(content)
            }
            return
        }

        if context.selectedPrivateChatPeer != nil {
            context.updatePrivateChatPeerIfNeeded()

            if let selectedPeer = context.selectedPrivateChatPeer {
                context.sendPrivateMessage(content, to: selectedPeer)
            }
            return
        }

        let mentions = context.parseMentions(from: content)

        switch context.activeChannel {
        case .mesh:
            sendMeshPublicMessage(originalContent: content, trimmed: trimmed, mentions: mentions)
        case .location(let channel):
            sendGeohashPublicMessage(trimmed, mentions: mentions, channel: channel)
        }
    }

    /// Broadcasts a wave on the mesh channel regardless of the active channel —
    /// used by the "bitchatters nearby" notification quick action, which always
    /// refers to mesh peers.
    func sendMeshWave() {
        sendMeshPublicMessage(originalContent: "👋", trimmed: "👋", mentions: [])
    }
}

private extension ChatOutgoingCoordinator {
    func sendMeshPublicMessage(originalContent: String, trimmed: String, mentions: [String]) {
        let message = BitchatMessage(
            sender: context.nickname,
            content: trimmed,
            timestamp: Date(),
            isRelay: false,
            senderPeerID: context.myPeerID,
            mentions: mentions.isEmpty ? nil : mentions
        )

        appendLocalEcho(message, to: .mesh)
        context.recordPublicActivity(forChannelKey: "mesh")
        context.sendMeshMessage(
            originalContent,
            mentions: mentions,
            messageID: message.id,
            timestamp: message.timestamp
        )
        context.bridgeOutgoingPublicMessage(trimmed, senderPeerID: context.myPeerID, timestamp: message.timestamp)
    }

    /// Geohash sends mine a NIP-13 nonce tag first (off the main actor, see
    /// `NostrPoW`), so the whole echo-and-send runs in a task once the signed
    /// event — whose ID is also the local message ID — exists. Typical mining
    /// at the default target is well under 100 ms and hard-capped at
    /// `NostrPoW.miningTimeCap`, so sending is never meaningfully delayed.
    func sendGeohashPublicMessage(_ trimmed: String, mentions: [String], channel: GeohashChannel) {
        let identity: NostrIdentity
        do {
            identity = try context.deriveNostrIdentity(forGeohash: channel.geohash)
        } catch {
            SecureLogger.error("❌ Failed to prepare geohash message: \(error)", category: .session)
            context.addSystemMessage(
                String(localized: "system.location.send_failed", comment: "System message when a location channel send fails")
            )
            return
        }

        let displaySender = context.nickname + "#" + String(identity.publicKeyHex.suffix(4))
        let senderPeerID = PeerID(nostr: identity.publicKeyHex)
        let teleported = context.isTeleported
        let nickname = context.nickname

        // Serialize geohash sends: each send awaits the previous send's task
        // before it appends + relays, so user-visible order always matches
        // send order even when an earlier message mines longer than a later
        // one. Cancelling the previous task only *expedites* its mining (the
        // NIP-13 target is polled, not aborted), so it still finishes and
        // sends — and it finishes fast, so awaiting it never stacks mining
        // delays or blocks a send beyond `NostrPoW.miningTimeCap`.
        let previousSend = geohashMiningTask
        previousSend?.cancel()
        geohashMiningTask = Task { @MainActor [weak context = self.context] in
            await previousSend?.value

            let event: NostrEvent
            do {
                event = try await NostrProtocol.createMinedEphemeralGeohashEvent(
                    content: trimmed,
                    geohash: channel.geohash,
                    senderIdentity: identity,
                    nickname: nickname,
                    teleported: teleported
                )
            } catch {
                SecureLogger.error("❌ Failed to prepare geohash message: \(error)", category: .session)
                context?.addSystemMessage(
                    String(localized: "system.location.send_failed", comment: "System message when a location channel send fails")
                )
                return
            }
            guard let context else { return }

            let message = BitchatMessage(
                id: event.id,
                sender: displaySender,
                content: trimmed,
                timestamp: Date(timeIntervalSince1970: TimeInterval(event.created_at)),
                isRelay: false,
                senderPeerID: senderPeerID,
                mentions: mentions.isEmpty ? nil : mentions
            )

            context.appendPublicMessage(message, to: ConversationID(channelID: .location(channel)))
            let contentKey = context.normalizedContentKey(message.content)
            context.recordContentKey(contentKey, timestamp: message.timestamp)

            context.recordPublicActivity(forChannelKey: "geo:\(channel.geohash)")
            context.sendGeohash(context: (
                channel: channel,
                event: event,
                identity: identity,
                teleported: teleported
            ))
        }
    }

    func appendLocalEcho(_ message: BitchatMessage, to conversationID: ConversationID) {
        context.appendPublicMessage(message, to: conversationID)

        let contentKey = context.normalizedContentKey(message.content)
        context.recordContentKey(contentKey, timestamp: message.timestamp)
    }
}

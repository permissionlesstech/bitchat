import BitFoundation
import BitLogger
import Foundation

/// The narrow surface `ChatDeliveryCoordinator` needs from its owner.
///
/// Coordinators should depend on the minimal context they actually use rather
/// than holding an `unowned` back-reference to the whole `ChatViewModel`. This
/// keeps the coordinator independently testable (see
/// `ChatDeliveryCoordinatorContextTests`) and makes its true dependencies
/// explicit. This protocol is the exemplar for migrating the other
/// coordinators off their `unowned let viewModel: ChatViewModel` back-refs.
@MainActor
protocol ChatDeliveryContext: AnyObject {
    var isStartupPhase: Bool { get }
    /// Applies a delivery status to every copy of the message across
    /// conversations (`ConversationStore` intent, ID-only: the store's
    /// message-ID → conversation map resolves which conversations hold the
    /// message, including mirrored ephemeral/stable private copies). The
    /// no-downgrade rule is enforced in the store. Returns `false` when the
    /// message is unknown or no copy changed.
    @discardableResult
    func setDeliveryStatus(_ status: DeliveryStatus, forMessageID messageID: String) -> Bool
    /// Applies an authenticated receipt only to the direct conversations
    /// represented by the supplied peer aliases.
    @discardableResult
    func setDeliveryStatus(
        _ status: DeliveryStatus,
        forMessageID messageID: String,
        inDirectPeerAliases peerIDs: Set<PeerID>
    ) -> Bool
    /// Current delivery status of the message in whichever conversation holds it.
    func deliveryStatus(forMessageID messageID: String) -> DeliveryStatus?
    /// Message IDs across all direct conversations (read-receipt pruning).
    func privateMessageIDs() -> Set<String>
    /// Drops every recorded read receipt whose message ID is not in `validMessageIDs`.
    /// Returns the number of receipts removed. (Single mutation path for the
    /// owner's `sentReadReceipts`; this coordinator never reads the raw set.)
    func pruneSentReadReceipts(keeping validMessageIDs: Set<String>) -> Int
    /// Signals that message state changed so observers refresh (e.g. `objectWillChange.send()`).
    func notifyUIChanged()
    /// Confirms receipt so the message router stops retaining the message for resend.
    func markMessageDelivered(_ messageID: String)
    /// Peer-bound form for authenticated remote receipts. Only the supplied
    /// conversation aliases may have retained state terminalized. This is the
    /// router-side clear only: it is safe without a conversation lookup
    /// because the router scopes removal to the acking peer's own queues.
    func markMessageDelivered(_ messageID: String, from peerIDs: Set<PeerID>)
    /// Releases the media reconnect retry for a private transfer. Unlike the
    /// router clear above this is keyed only by the stable media message ID,
    /// so callers must first bind the receipt to one of our outgoing
    /// conversations for the acking peer.
    func confirmPrivateMediaDelivery(_ messageID: String)
    /// Returns true only when `messageID` is one of our outgoing messages in
    /// at least one of the authenticated peer's direct-conversation aliases.
    func isOutgoingPrivateMessage(_ messageID: String, toAny peerIDs: Set<PeerID>) -> Bool
}

extension ChatViewModel: ChatDeliveryContext {
    @discardableResult
    func setDeliveryStatus(_ status: DeliveryStatus, forMessageID messageID: String) -> Bool {
        conversations.setDeliveryStatus(status, forMessageID: messageID)
    }

    @discardableResult
    func setDeliveryStatus(
        _ status: DeliveryStatus,
        forMessageID messageID: String,
        inDirectPeerAliases peerIDs: Set<PeerID>
    ) -> Bool {
        conversations.setDeliveryStatus(
            status,
            forMessageID: messageID,
            inDirectPeerAliases: peerIDs
        )
    }

    func deliveryStatus(forMessageID messageID: String) -> DeliveryStatus? {
        conversations.deliveryStatus(forMessageID: messageID)
    }

    func privateMessageIDs() -> Set<String> {
        conversations.directMessageIDs()
    }

    func notifyUIChanged() {
        objectWillChange.send()
    }

    func markMessageDelivered(_ messageID: String) {
        messageRouter.markDelivered(messageID)
        mediaTransferCoordinator.confirmPrivateMediaDelivery(
            messageID: messageID
        )
    }

    func markMessageDelivered(_ messageID: String, from peerIDs: Set<PeerID>) {
        messageRouter.markDelivered(messageID, from: peerIDs)
    }

    func confirmPrivateMediaDelivery(_ messageID: String) {
        mediaTransferCoordinator.confirmPrivateMediaDelivery(
            messageID: messageID
        )
    }

    func isOutgoingPrivateMessage(_ messageID: String, toAny peerIDs: Set<PeerID>) -> Bool {
        peerIDs.contains { peerID in
            privateMessages(for: peerID).contains { message in
                message.id == messageID && message.senderPeerID == myPeerID
            }
        }
    }
}

/// Thin mapper from delivery events (read receipts, transport delivery
/// callbacks) onto `ConversationStore` delivery intents, plus read-receipt
/// retention cleanup. The store's message-ID → conversation map replaces the
/// positional `messageLocationIndex` this coordinator used to maintain.
final class ChatDeliveryCoordinator {
    private unowned let context: any ChatDeliveryContext

    init(context: any ChatDeliveryContext) {
        self.context = context
    }

    @MainActor
    func cleanupOldReadReceipts() {
        guard !context.isStartupPhase else { return }
        let validMessageIDs = context.privateMessageIDs()
        guard !validMessageIDs.isEmpty else { return }

        let removedCount = context.pruneSentReadReceipts(keeping: validMessageIDs)
        if removedCount > 0 {
            SecureLogger.debug("🧹 Cleaned up \(removedCount) old read receipts", category: .session)
        }
    }

    @MainActor
    func didReceiveReadReceipt(_ receipt: ReadReceipt) {
        updateAcknowledgedMessageDeliveryStatus(
            receipt.originalMessageID,
            status: .read(by: receipt.readerNickname, at: receipt.timestamp),
            from: [receipt.readerID]
        )
    }

    @MainActor
    func didUpdateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) {
        updateMessageDeliveryStatus(messageID, status: status)
    }

    @MainActor
    func deliveryStatus(for messageID: String) -> DeliveryStatus? {
        context.deliveryStatus(forMessageID: messageID)
    }

    @MainActor
    @discardableResult
    func updateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) -> Bool {
        guard context.setDeliveryStatus(status, forMessageID: messageID) else {
            return false
        }
        switch status {
        case .delivered, .read:
            // Terminalize only after the store accepted the transition.
            context.markMessageDelivered(messageID)
        default:
            break
        }
        context.notifyUIChanged()
        return true
    }

    /// Applies an authenticated remote delivery/read receipt. The durable
    /// retry state is always released for the acking peer's own aliases
    /// (`markMessageDelivered(_:from:)` is peer-scoped on the router side, so
    /// a receipt can only terminalize messages queued for that peer). Only the
    /// UI status transition and the media-retry release are gated on the
    /// in-memory conversation holding the message as one of ours: after a
    /// force-quit → relaunch the durable outbox is restored
    /// while the conversation may not be, and discarding the ack there would
    /// re-send an already-delivered message on every flush/auth event until
    /// the attempt cap marks it failed. Mirrors the Nostr path
    /// (`ChatPrivateConversationCoordinator.handleDelivered`), which clears
    /// retained state unconditionally.
    @MainActor
    @discardableResult
    func updateAcknowledgedMessageDeliveryStatus(
        _ messageID: String,
        status: DeliveryStatus,
        from peerIDAliases: Set<PeerID>
    ) -> Bool {
        switch status {
        case .delivered, .read:
            break
        default:
            return false
        }
        guard !peerIDAliases.isEmpty else { return false }
        context.markMessageDelivered(messageID, from: peerIDAliases)
        guard context.isOutgoingPrivateMessage(messageID, toAny: peerIDAliases),
              context.setDeliveryStatus(
                status,
                forMessageID: messageID,
                inDirectPeerAliases: peerIDAliases
              ) else {
            return false
        }
        // The receipt is now bound to one of our outgoing conversations for
        // the acking peer; only then release the media reconnect retry, whose
        // stable message ID is not peer-scoped.
        context.confirmPrivateMediaDelivery(messageID)
        context.notifyUIChanged()
        return true
    }
}

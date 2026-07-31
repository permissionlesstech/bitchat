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
}

extension ChatViewModel: ChatDeliveryContext {
    @discardableResult
    func setDeliveryStatus(_ status: DeliveryStatus, forMessageID messageID: String) -> Bool {
        conversations.setDeliveryStatus(status, forMessageID: messageID)
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
        updateMessageDeliveryStatus(
            receipt.originalMessageID,
            status: .read(by: receipt.readerNickname, at: receipt.timestamp)
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
        switch status {
        case .delivered, .read:
            // Confirmed receipt — stop retaining the message for resend.
            context.markMessageDelivered(messageID)
        default:
            break
        }

        guard context.setDeliveryStatus(status, forMessageID: messageID) else {
            return false
        }
        context.notifyUIChanged()
        return true
    }
}

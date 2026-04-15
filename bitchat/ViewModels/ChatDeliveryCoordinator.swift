import BitFoundation
import BitLogger
import Foundation

final class ChatDeliveryCoordinator {
    private unowned let viewModel: ChatViewModel

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    @MainActor
    func cleanupOldReadReceipts() {
        guard !viewModel.isStartupPhase, !viewModel.privateChats.isEmpty else {
            return
        }

        let validMessageIDs = Set(
            viewModel.privateChats.values.flatMap { messages in
                messages.map(\.id)
            }
        )

        let oldCount = viewModel.sentReadReceipts.count
        viewModel.sentReadReceipts = viewModel.sentReadReceipts.intersection(validMessageIDs)

        let removedCount = oldCount - viewModel.sentReadReceipts.count
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
    func updateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) {
        var didUpdateStatus = false

        if let index = viewModel.messages.firstIndex(where: { $0.id == messageID }) {
            let currentStatus = viewModel.messages[index].deliveryStatus
            if !shouldSkipUpdate(currentStatus: currentStatus, newStatus: status) {
                viewModel.messages[index].deliveryStatus = status
                didUpdateStatus = true
            }
        }

        var privateChats = viewModel.privateChats
        for (peerID, chatMessages) in privateChats {
            guard let index = chatMessages.firstIndex(where: { $0.id == messageID }) else { continue }

            let currentStatus = chatMessages[index].deliveryStatus
            guard !shouldSkipUpdate(currentStatus: currentStatus, newStatus: status) else { continue }

            privateChats[peerID]?[index].deliveryStatus = status
            didUpdateStatus = true
        }

        if didUpdateStatus {
            viewModel.privateChats = privateChats
            viewModel.objectWillChange.send()
        }
    }
}

private extension ChatDeliveryCoordinator {
    func shouldSkipUpdate(currentStatus: DeliveryStatus?, newStatus: DeliveryStatus) -> Bool {
        guard let currentStatus else { return false }

        switch (currentStatus, newStatus) {
        case (.read, .delivered), (.read, .sent):
            return true
        default:
            return false
        }
    }
}

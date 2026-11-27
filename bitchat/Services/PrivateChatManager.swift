//
// PrivateChatManager.swift
// bitchat
//
// Manages private chat sessions and messages
// This is free and unencumbered software released into the public domain.
//

import BitLogger
import BitFoundation
import Foundation

/// Manages private chat session policy (selection delegation, read receipts,
/// consolidation). Message and selection state live in the single-writer
/// `ConversationStore`.
@MainActor
final class PrivateChatManager {
    /// Current direct-conversation selection, read directly from `ConversationStore`.
    var selectedPeer: PeerID? {
        conversationStore?.selectedPrivatePeerID
    }

    var sentReadReceipts: Set<String> = []  // Made accessible for ChatViewModel

    weak var meshService: Transport?
    // Route acks/receipts via MessageRouter (chooses mesh or Nostr)
    weak var messageRouter: MessageRouter?
    // Peer service for looking up peer info during consolidation
    weak var unifiedPeerService: UnifiedPeerService?
    /// Single source of truth for message and selection state; injected by
    /// the bootstrapper (`wireServiceGraph`).
    var conversationStore: ConversationStore?

    init(meshService: Transport? = nil, conversationStore: ConversationStore? = nil) {
        self.meshService = meshService
        self.conversationStore = conversationStore
    }

    func resetForPanic() {
        sentReadReceipts.removeAll(keepingCapacity: false)
    }

    #if DEBUG
    // MARK: - Derived message state (read-only compat views)

    /// All private chats keyed by routing peer ID, derived from the store.
    /// Mutations go through the store's intent API only.
    @MainActor
    var privateChats: [PeerID: [BitchatMessage]] {
        conversationStore?.directMessagesByRoutingPeerID() ?? [:]
    }

    /// Unread chats, derived from the store's unread state.
    @MainActor
    var unreadMessages: Set<PeerID> {
        conversationStore?.unreadDirectRoutingPeerIDs() ?? []
    }
    #endif

    @MainActor
    private func messages(for peerID: PeerID) -> [BitchatMessage] {
        conversationStore?.conversationsByID[.directPeer(peerID)]?.messages ?? []
    }

    // MARK: - Message Consolidation

    /// Consolidates history stored under the peer's known Noise key into its chat.
    /// - Parameters:
    ///   - peerID: The target peer ID to consolidate messages into
    ///   - persistedReadReceipts: The persisted read receipts set from ChatViewModel (UserDefaults-backed)
    /// - Returns: True if any unread messages were found during consolidation
    @MainActor
    func consolidateMessages(for peerID: PeerID, persistedReadReceipts: Set<String>) -> Bool {
        guard let meshService = meshService, let store = conversationStore else { return false }
        var hasUnreadMessages = false

        if let peer = unifiedPeerService?.getPeer(by: peerID) {
            let noiseKeyHex = PeerID(hexData: peer.noisePublicKey)
            let nostrMessages = messages(for: noiseKeyHex)

            if noiseKeyHex != peerID, !nostrMessages.isEmpty {
                for message in nostrMessages {
                    // Update senderPeerID for correct read receipts
                    let updatedMessage = BitchatMessage(
                        id: message.id,
                        sender: message.sender,
                        content: message.content,
                        timestamp: message.timestamp,
                        isRelay: message.isRelay,
                        originalSender: message.originalSender,
                        isPrivate: message.isPrivate,
                        recipientNickname: message.recipientNickname,
                        senderPeerID: message.senderPeerID == meshService.myPeerID ? meshService.myPeerID : peerID,
                        mentions: message.mentions,
                        deliveryStatus: message.deliveryStatus
                    )
                    // Store append dedups by message ID (skips ones the
                    // target chat already has).
                    guard store.append(updatedMessage, to: .directPeer(peerID)) else { continue }

                    // Check for recent unread messages (< 60s, not sent by us, not already read)
                    // Use persistedReadReceipts to correctly identify already-read messages after app restart
                    if message.senderPeerID != meshService.myPeerID {
                        let messageAge = Date().timeIntervalSince(message.timestamp)
                        if messageAge < 60 && !persistedReadReceipts.contains(message.id) {
                            hasUnreadMessages = true
                        }
                    }
                }

                if hasUnreadMessages {
                    store.markUnread(.directPeer(peerID))
                } else {
                    store.markRead(.directPeer(noiseKeyHex))
                }

                store.removeConversation(.directPeer(noiseKeyHex))
            }
        }

        return hasUnreadMessages
    }

    /// Syncs the read receipt tracking between manager and view model for sent
    /// messages. "Sent" means carrying my peer ID, never merely my nickname:
    /// a namesake's delivered message still gets its READ receipt, and my
    /// messages from before a rename still count as mine.
    @MainActor
    func syncReadReceiptsForSentMessages(peerID: PeerID, externalReceipts: inout Set<String>) {
        guard let myPeerID = meshService?.myPeerID else { return }
        var syncedIDs: [String] = []
        for message in messages(for: peerID) {
            if message.isOwn(myPeerID: myPeerID, myGeoChatPeerID: nil) {
                switch message.deliveryStatus {
                case .read, .delivered:
                    syncedIDs.append(message.id)
                case .notSentYet, .failed, .partiallyDelivered, .sending, .sent, .carried:
                    break
                }
            }
        }
        guard !syncedIDs.isEmpty else { return }
        externalReceipts.formUnion(syncedIDs)
        sentReadReceipts.formUnion(syncedIDs)
    }

    /// Start a private chat with a peer. Selection is mutated through the
    /// store's intent (the store owns it); the manager keeps its side
    /// effects (read receipts, unread clearing).
    @MainActor
    func startChat(with peerID: PeerID) {
        // Also creates the conversation if needed and updates the derived
        // `selectedConversationID`; `selectedPeer` mirrors the change.
        conversationStore?.setSelectedPrivatePeer(peerID)

        // Mark messages as read
        markAsRead(from: peerID)
    }

    /// End the current private chat (selection returns to the active public
    /// channel's conversation).
    func endChat() {
        conversationStore?.setSelectedPrivatePeer(nil)
    }

    /// Mark messages from a peer as read
    @MainActor
    func markAsRead(from peerID: PeerID) {
        conversationStore?.markRead(.directPeer(peerID))

        // Send read receipts for unread messages that haven't been sent yet
        // A courier join preserves the mesh rows' short sender IDs.
        let shortPeerID = peerID.toShort()
        for message in messages(for: peerID) {
            if (message.senderPeerID == peerID || message.senderPeerID == shortPeerID)
                && !message.isRelay && !sentReadReceipts.contains(message.id) {
                sendReadReceipt(for: message)
            }
        }
    }

    // MARK: - Private Methods

    private func sendReadReceipt(for message: BitchatMessage) {
        guard !sentReadReceipts.contains(message.id),
              let senderPeerID = message.senderPeerID else {
            return
        }

        // Create read receipt using the simplified method
        let receipt = ReadReceipt(
            originalMessageID: message.id,
            readerID: meshService?.myPeerID ?? PeerID(str: ""),
            readerNickname: meshService?.myNickname ?? ""
        )

        // Route via MessageRouter to avoid handshakeRequired spam when session isn't established
        if let router = messageRouter {
            SecureLogger.debug("PrivateChatManager: sending READ ack for \(message.id.prefix(8))… to \(senderPeerID.id.prefix(8))… via router", category: .session)
            let messageID = message.id
            // Claim the receipt synchronously so a second read scan in the
            // same runloop pass (chat open triggers two) can't route a
            // duplicate; release the claim on a failed route (no reachable
            // transport) so a later read scan retries instead of permanently
            // losing the receipt.
            sentReadReceipts.insert(messageID)
            Task { @MainActor [weak self] in
                if !router.sendReadReceipt(receipt, to: senderPeerID) {
                    self?.sentReadReceipts.remove(messageID)
                }
            }
        } else {
            // Fallback: preserve previous behavior (best-effort mesh send).
            sentReadReceipts.insert(message.id)
            meshService?.sendReadReceipt(receipt, to: senderPeerID)
        }
    }
}

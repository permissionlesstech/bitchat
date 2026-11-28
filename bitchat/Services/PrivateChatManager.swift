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

/// Manages private chat session policy (selection delegation, unread clearing,
/// consolidation). Message and selection state live in the single-writer
/// `ConversationStore`; read-receipt tracking and sending live exclusively in
/// `ChatViewModel` / `ChatLifecycleCoordinator`.
@MainActor
final class PrivateChatManager {
    /// Current direct-conversation selection, read directly from `ConversationStore`.
    var selectedPeer: PeerID? {
        conversationStore?.selectedPrivatePeerID
    }

    weak var meshService: Transport?
    // Peer service for looking up peer info during consolidation
    weak var unifiedPeerService: UnifiedPeerService?
    /// Single source of truth for message and selection state; injected by
    /// the bootstrapper (`wireServiceGraph`).
    var conversationStore: ConversationStore?

    init(meshService: Transport? = nil, conversationStore: ConversationStore? = nil) {
        self.meshService = meshService
        self.conversationStore = conversationStore
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

    /// Start a private chat with a peer. Selection and unread clearing mutate
    /// through the store's intent API; outbound read-receipt routing is owned
    /// solely by `ChatLifecycleCoordinator.markPrivateMessagesAsRead(from:)`.
    @MainActor
    func startChat(with peerID: PeerID) {
        // Also creates the conversation if needed and updates the derived
        // `selectedConversationID`; `selectedPeer` mirrors the change.
        conversationStore?.setSelectedPrivatePeer(peerID)
        markAsRead(from: peerID)
    }

    /// End the current private chat (selection returns to the active public
    /// channel's conversation).
    func endChat() {
        conversationStore?.setSelectedPrivatePeer(nil)
    }

    /// Clears the unread indicator for a peer's direct conversation.
    /// Read-receipt transmission is owned exclusively by `ChatLifecycleCoordinator`
    /// so there is a single source of truth for sent receipts and privacy gates.
    @MainActor
    func markAsRead(from peerID: PeerID) {
        conversationStore?.markRead(.directPeer(peerID))
    }
}

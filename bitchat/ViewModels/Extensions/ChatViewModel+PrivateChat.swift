//
// ChatViewModel+PrivateChat.swift
// bitchat
//
// Private chat and media transfer logic for ChatViewModel
//

import BitFoundation
import Foundation
import SwiftUI

extension ChatViewModel {

    @MainActor
    func sendPrivateMessage(_ content: String, to peerID: PeerID) {
        privateConversationCoordinator.sendPrivateMessage(content, to: peerID)
    }

    @MainActor
    func sendGeohashDM(_ content: String, to peerID: PeerID) {
        privateConversationCoordinator.sendGeohashDM(content, to: peerID)
    }

    @MainActor
    func handlePrivateMessage(
        _ payload: NoisePayload,
        senderPubkey: String,
        convKey: PeerID,
        id: NostrIdentity,
        messageTimestamp: Date
    ) {
        privateConversationCoordinator.handlePrivateMessage(
            payload,
            senderPubkey: senderPubkey,
            convKey: convKey,
            id: id,
            messageTimestamp: messageTimestamp
        )
    }

    @MainActor
    func handleDelivered(_ payload: NoisePayload, senderPubkey: String, convKey: PeerID) {
        privateConversationCoordinator.handleDelivered(payload, senderPubkey: senderPubkey, convKey: convKey)
    }

    @MainActor
    func handleReadReceipt(_ payload: NoisePayload, senderPubkey: String, convKey: PeerID) {
        privateConversationCoordinator.handleReadReceipt(payload, senderPubkey: senderPubkey, convKey: convKey)
    }

    @MainActor
    func sendDeliveryAckIfNeeded(to messageId: String, senderPubKey: String, from id: NostrIdentity) {
        privateConversationCoordinator.sendDeliveryAckIfNeeded(to: messageId, senderPubKey: senderPubKey, from: id)
    }

    @MainActor
    func sendReadReceiptIfNeeded(to messageId: String, senderPubKey: String, from id: NostrIdentity) {
        privateConversationCoordinator.sendReadReceiptIfNeeded(to: messageId, senderPubKey: senderPubKey, from: id)
    }

    @MainActor
    func sendVoiceNote(at url: URL) {
        mediaTransferCoordinator.sendVoiceNote(at: url)
    }

    #if os(iOS)
    func processThenSendImage(_ image: UIImage?) {
        mediaTransferCoordinator.processThenSendImage(image)
    }
    #elseif os(macOS)
    func processThenSendImage(from url: URL?) {
        mediaTransferCoordinator.processThenSendImage(from: url)
    }
    #endif

    @MainActor
    func sendImage(from sourceURL: URL, cleanup: (() -> Void)? = nil) {
        mediaTransferCoordinator.sendImage(from: sourceURL, cleanup: cleanup)
    }

    @MainActor
    func enqueueMediaMessage(content: String, targetPeer: PeerID?) -> BitchatMessage {
        mediaTransferCoordinator.enqueueMediaMessage(content: content, targetPeer: targetPeer)
    }

    @MainActor
    func registerTransfer(transferId: String, messageID: String) {
        mediaTransferCoordinator.registerTransfer(transferId: transferId, messageID: messageID)
    }

    func makeTransferID(messageID: String) -> String {
        mediaTransferCoordinator.makeTransferID(messageID: messageID)
    }

    @MainActor
    func clearTransferMapping(for messageID: String) {
        mediaTransferCoordinator.clearTransferMapping(for: messageID)
    }

    @MainActor
    func handleMediaSendFailure(messageID: String, reason: String) {
        mediaTransferCoordinator.handleMediaSendFailure(messageID: messageID, reason: reason)
    }

    @MainActor
    func handleTransferEvent(_ event: TransferProgressManager.Event) {
        mediaTransferCoordinator.handleTransferEvent(event)
    }

    func cleanupLocalFile(forMessage message: BitchatMessage) {
        mediaTransferCoordinator.cleanupLocalFile(forMessage: message)
    }

    @MainActor
    func cancelMediaSend(messageID: String) {
        mediaTransferCoordinator.cancelMediaSend(messageID: messageID)
    }

    @MainActor
    func deleteMediaMessage(messageID: String) {
        mediaTransferCoordinator.deleteMediaMessage(messageID: messageID)
    }

    @MainActor
    func handlePrivateMessage(
        _ payload: NoisePayload,
        actualSenderNoiseKey: Data?,
        senderNickname: String,
        targetPeerID: PeerID,
        messageTimestamp: Date,
        senderPubkey: String
    ) {
        privateConversationCoordinator.handlePrivateMessage(
            payload,
            actualSenderNoiseKey: actualSenderNoiseKey,
            senderNickname: senderNickname,
            targetPeerID: targetPeerID,
            messageTimestamp: messageTimestamp,
            senderPubkey: senderPubkey
        )
    }

    @MainActor
    func handlePrivateMessage(_ message: BitchatMessage) {
        privateConversationCoordinator.handlePrivateMessage(message)
    }

    @MainActor
    func isDuplicateMessage(_ messageId: String, targetPeerID: PeerID) -> Bool {
        privateConversationCoordinator.isDuplicateMessage(messageId, targetPeerID: targetPeerID)
    }

    @MainActor
    func addMessageToPrivateChatsIfNeeded(_ message: BitchatMessage, targetPeerID: PeerID) {
        privateConversationCoordinator.addMessageToPrivateChatsIfNeeded(message, targetPeerID: targetPeerID)
    }

    @MainActor
    func mirrorToEphemeralIfNeeded(_ message: BitchatMessage, targetPeerID: PeerID, key: Data?) {
        privateConversationCoordinator.mirrorToEphemeralIfNeeded(message, targetPeerID: targetPeerID, key: key)
    }

    @MainActor
    func handleViewingThisChat(_ message: BitchatMessage, targetPeerID: PeerID, key: Data?, senderPubkey: String) {
        privateConversationCoordinator.handleViewingThisChat(
            message,
            targetPeerID: targetPeerID,
            key: key,
            senderPubkey: senderPubkey
        )
    }

    @MainActor
    func markAsUnreadIfNeeded(
        shouldMarkAsUnread: Bool,
        targetPeerID: PeerID,
        key: Data?,
        isRecentMessage: Bool,
        senderNickname: String,
        messageContent: String
    ) {
        privateConversationCoordinator.markAsUnreadIfNeeded(
            shouldMarkAsUnread: shouldMarkAsUnread,
            targetPeerID: targetPeerID,
            key: key,
            isRecentMessage: isRecentMessage,
            senderNickname: senderNickname,
            messageContent: messageContent
        )
    }

    @MainActor
    func handleFavoriteNotificationFromMesh(_ content: String, from peerID: PeerID, senderNickname: String) {
        privateConversationCoordinator.handleFavoriteNotificationFromMesh(
            content,
            from: peerID,
            senderNickname: senderNickname
        )
    }

    @MainActor
    func processActionMessage(_ message: BitchatMessage) -> BitchatMessage {
        privateConversationCoordinator.processActionMessage(message)
    }

    @MainActor
    func migratePrivateChatsIfNeeded(for peerID: PeerID, senderNickname: String) {
        privateConversationCoordinator.migratePrivateChatsIfNeeded(for: peerID, senderNickname: senderNickname)
    }

    @MainActor
    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {
        privateConversationCoordinator.sendFavoriteNotification(to: peerID, isFavorite: isFavorite)
    }

    @MainActor
    func isMessageBlocked(_ message: BitchatMessage) -> Bool {
        privateConversationCoordinator.isMessageBlocked(message)
    }
}

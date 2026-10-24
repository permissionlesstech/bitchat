//
// RecordingMessageListActions.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
@testable import bitchat

/// Records each conversation action a message list sends, with the target it
/// sent it in.
@MainActor
final class RecordingMessageListActions: MessageListActionPerforming {
    enum Call: Equatable {
        case hug(String, ConversationTarget)
        case slap(String, ConversationTarget)
        case block(PeerID?, String?, ConversationTarget)
        case clear(ConversationTarget)
        case resend(String, ConversationTarget)
    }

    private(set) var calls: [Call] = []

    func sendHug(to sender: String, in target: ConversationTarget) {
        calls.append(.hug(sender, target))
    }

    func sendSlap(to sender: String, in target: ConversationTarget) {
        calls.append(.slap(sender, target))
    }

    func block(peerID: PeerID?, displayName: String?, from target: ConversationTarget) {
        calls.append(.block(peerID, displayName, target))
    }

    func clearConversation(_ target: ConversationTarget) {
        calls.append(.clear(target))
    }

    func resendFailedPrivateMessage(_ message: BitchatMessage, in target: ConversationTarget) {
        calls.append(.resend(message.id, target))
    }
}

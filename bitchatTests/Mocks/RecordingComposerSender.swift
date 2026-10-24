//
// RecordingComposerSender.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

@testable import bitchat

/// Records each text a composer sends, with the conversation it went to.
@MainActor
final class RecordingComposerSender: ComposerMessageSending {
    struct Sent {
        let text: String
        let target: ConversationTarget
    }

    private(set) var sent: [Sent] = []

    func sendMessage(_ message: String, to target: ConversationTarget) {
        sent.append(Sent(text: message, target: target))
    }
}

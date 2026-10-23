//
// MessageListActions.swift
// bitchat
//
// What a message list's actions act on: the list's own conversation and the
// composer under it, never the selection. Beside another pane the selection
// names the other pane's conversation, so a hug, a /clear or a mention taken
// from the selection would land there.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation

/// The conversation actions a message list sends on. `ConversationUIModel`
/// is the app's.
@MainActor
protocol MessageListActionPerforming: AnyObject {
    func sendHug(to sender: String, in target: ConversationTarget)
    func sendSlap(to sender: String, in target: ConversationTarget)
    func block(peerID: PeerID?, displayName: String?, from target: ConversationTarget)
    func clearConversation(_ target: ConversationTarget)
    func resendFailedPrivateMessage(_ message: BitchatMessage, in target: ConversationTarget)
}

extension ConversationUIModel: MessageListActionPerforming {}

/// A message list's row and sender actions, bound to the list.
@MainActor
struct MessageListActions {
    /// The conversation the list shows.
    let target: ConversationTarget
    /// The composer under the list, which a mention types into; nil while
    /// that composer isn't on screen, when the list offers no mention.
    let composer: ComposerSession?
    /// Gives the keyboard to a composer.
    let focusComposer: (ComposerSlot) -> Void
    let performer: any MessageListActionPerforming

    /// The conversation a list's actions act in: a DM list's own DM (its
    /// owner's target, carrying the DM's scope), else the channel the list's
    /// own timeline model shows. Never the selection, which can name
    /// another pane's conversation or run ahead of the timeline.
    static func target(
        privateTarget: ConversationTarget?,
        timelineChannel: ChannelID?
    ) -> ConversationTarget? {
        if let privateTarget, privateTarget.isPrivate {
            return privateTarget
        }
        return timelineChannel.map(ConversationTarget.publicChannel)
    }

    var canMention: Bool { composer != nil }

    /// Appends `@sender` to the list's own composer and gives it the
    /// keyboard.
    func mention(_ sender: String) {
        guard let composer else { return }
        composer.insertMention(sender)
        focusComposer(composer.slot)
    }

    func hug(_ sender: String) {
        performer.sendHug(to: sender, in: target)
    }

    func slap(_ sender: String) {
        performer.sendSlap(to: sender, in: target)
    }

    /// Blocks someone shown in this list; the confirmation lands here too.
    func block(peerID: PeerID?, displayName: String?) {
        performer.block(peerID: peerID, displayName: displayName, from: target)
    }

    /// The triple-tap clear: empties this list's conversation.
    func clear() {
        performer.clearConversation(target)
    }

    func resend(_ message: BitchatMessage) {
        performer.resendFailedPrivateMessage(message, in: target)
    }
}

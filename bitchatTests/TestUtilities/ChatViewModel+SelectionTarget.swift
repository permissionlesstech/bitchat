//
// ChatViewModel+SelectionTarget.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
@testable import bitchat

extension ChatViewModel {
    /// The selection as a send target: the open DM, in the selected
    /// channel's scope, or the selected channel's timeline. The app sends
    /// and runs commands only in a conversation it names; tests that act
    /// where a single composer would, on whatever is selected, name this.
    @MainActor
    var selectionTarget: ConversationTarget {
        ConversationTarget(channel: activeChannel, privatePeer: selectedPrivateChatPeer)
    }
}

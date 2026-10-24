import BitFoundation
import Combine
import SwiftUI

/// Feature model for one public (mesh/geohash) timeline.
///
/// Observes ONE `Conversation` object in the single-writer
/// `ConversationStore`, so appends to every other conversation (other
/// geohashes, private chats, and the other pane's timeline) never invalidate
/// it. `messages` reads the observed conversation's backing array directly;
/// there is no mirror copy.
///
/// By default the model follows the store's active channel (the compact
/// timeline, and the split layout's trailing pane). A model pinned to a
/// channel shows that channel whatever is selected: the split layout's
/// leading #mesh pane.
@MainActor
final class PublicChatModel: ObservableObject {
    /// The channel `messages` belongs to. Changes in the same synchronous
    /// update as the conversation swap, so a view never pairs one channel
    /// with another channel's messages. Never changes on a pinned model.
    @Published private(set) var channel: ChannelID

    /// The observed conversation's timeline.
    var messages: [BitchatMessage] { conversation.messages }

    private let conversations: ConversationStore
    private var conversation: Conversation
    private var conversationCancellable: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()

    /// - Parameter pinnedChannel: The channel to show regardless of the
    ///   selection, or nil to follow the store's active channel.
    init(conversations: ConversationStore, pinnedTo pinnedChannel: ChannelID? = nil) {
        let channel = pinnedChannel ?? conversations.activeChannel
        self.conversations = conversations
        self.channel = channel
        self.conversation = conversations.conversation(for: ConversationID(channelID: channel))

        observeConversation()
        bind(followsActiveChannel: pinnedChannel == nil)
    }

    private func bind(followsActiveChannel: Bool) {
        if followsActiveChannel {
            conversations.$activeChannel
                .dropFirst()
                .sink { [weak self] channel in
                    guard let self else { return }
                    self.channel = channel
                    self.retargetConversation(to: channel)
                }
                .store(in: &cancellables)
        }

        // The store drops a conversation's object when it is removed (panic
        // clear) without emptying it; retarget to the fresh instance so the
        // observation never goes stale and wiped messages never stay on
        // screen. Pinned models need this as much as following ones.
        conversations.changes
            .sink { [weak self] change in
                guard let self,
                      case .removed(let id) = change,
                      id == self.conversation.id else { return }
                self.retargetConversation(to: self.channel)
            }
            .store(in: &cancellables)
    }

    private func retargetConversation(to channel: ChannelID) {
        let conversation = conversations.conversation(for: ConversationID(channelID: channel))
        guard conversation !== self.conversation else {
            // Same object (e.g. re-selected channel): keep the existing
            // observation, but `messages` may still differ from what views
            // last rendered, so republish.
            objectWillChange.send()
            return
        }
        objectWillChange.send()
        self.conversation = conversation
        observeConversation()
    }

    private func observeConversation() {
        conversationCancellable = conversation.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }
}

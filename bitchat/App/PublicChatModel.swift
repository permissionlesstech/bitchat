import BitFoundation
import Combine
import SwiftUI

/// Feature model for the active public (mesh/geohash) timeline.
///
/// Observes ONE `Conversation` object in the single-writer
/// `ConversationStore` — the active channel's — so appends to background
/// conversations (other geohashes, private chats) never invalidate it.
/// `messages` reads the observed conversation's backing array directly;
/// there is no mirror copy.
@MainActor
final class PublicChatModel: ObservableObject {
    @Published private(set) var activeChannel: ChannelID

    /// The active public conversation's timeline.
    var messages: [BitchatMessage] { activeConversation.messages }

    private let conversations: ConversationStore
    private var activeConversation: Conversation
    private var activeConversationCancellable: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()

    init(conversations: ConversationStore) {
        let channel = conversations.activeChannel
        self.conversations = conversations
        self.activeChannel = channel
        self.activeConversation = conversations.conversation(for: ConversationID(channelID: channel))

        observeActiveConversation()
        bind()
    }

    private func bind() {
        conversations.$activeChannel
            .dropFirst()
            .sink { [weak self] channel in
                guard let self else { return }
                self.activeChannel = channel
                self.retargetActiveConversation(to: channel)
            }
            .store(in: &cancellables)

        // The store replaces a conversation's object when it is removed
        // (panic clear); retarget to the fresh instance so the observation
        // never goes stale.
        conversations.changes
            .sink { [weak self] change in
                guard let self,
                      case .removed(let id) = change,
                      id == self.activeConversation.id else { return }
                self.retargetActiveConversation(to: self.activeChannel)
            }
            .store(in: &cancellables)
    }

    private func retargetActiveConversation(to channel: ChannelID) {
        let conversation = conversations.conversation(for: ConversationID(channelID: channel))
        guard conversation !== activeConversation else {
            // Same object (e.g. re-selected channel): keep the existing
            // observation, but `messages` may still differ from what views
            // last rendered, so republish.
            objectWillChange.send()
            return
        }
        objectWillChange.send()
        activeConversation = conversation
        observeActiveConversation()
    }

    private func observeActiveConversation() {
        activeConversationCancellable = activeConversation.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }
}

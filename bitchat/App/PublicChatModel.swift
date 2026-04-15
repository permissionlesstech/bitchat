import BitFoundation
import Combine
import SwiftUI

@MainActor
final class PublicChatModel: ObservableObject {
    @Published private(set) var activeChannel: ChannelID
    @Published private(set) var messages: [BitchatMessage] = []

    private let conversationStore: ConversationStore
    private var cancellables = Set<AnyCancellable>()

    init(conversationStore: ConversationStore) {
        self.activeChannel = conversationStore.activeChannel
        self.conversationStore = conversationStore

        bind()
        refreshMessages()
    }

    private func bind() {
        conversationStore.$activeChannel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] channel in
                self?.activeChannel = channel
                self?.refreshMessages()
            }
            .store(in: &cancellables)

        conversationStore.$messagesByConversation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshMessages()
            }
            .store(in: &cancellables)
    }

    private func refreshMessages() {
        messages = conversationStore.messages(for: ConversationID(channelID: activeChannel))
    }
}

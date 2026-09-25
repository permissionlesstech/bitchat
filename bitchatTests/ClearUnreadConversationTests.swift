import BitFoundation
import Foundation
import Testing
@testable import bitchat

@MainActor
struct ClearUnreadConversationTests {
    @Test("markPrivateChatRead clears unread without removing messages")
    func markPrivateChatRead_clearsBadgeOnly() {
        let viewModel = makeViewModel()
        let peerID = PeerID(str: "0011223344556677")
        let message = BitchatMessage(
            sender: "alice",
            content: "ping",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            senderPeerID: peerID
        )

        viewModel.appendPrivateMessage(message, to: peerID)
        viewModel.markPrivateChatUnread(peerID)

        #expect(viewModel.hasUnreadMessages(for: peerID))
        #expect(viewModel.privateMessages(for: peerID).count == 1)

        viewModel.markPrivateChatRead(peerID)

        #expect(!viewModel.hasUnreadMessages(for: peerID))
        #expect(viewModel.privateMessages(for: peerID).count == 1)
    }

    @Test("PeerListModel.clearUnread forwards to the conversation store")
    func peerListModel_clearUnread() {
        let viewModel = makeViewModel()
        let conversations = viewModel.conversations
        let locationChannelsModel = LocationChannelsModel()
        let peerListModel = PeerListModel(
            chatViewModel: viewModel,
            conversations: conversations,
            locationChannelsModel: locationChannelsModel
        )
        let peerID = PeerID(str: "0011223344556677")

        conversations.markUnread(.directPeer(peerID))
        #expect(viewModel.hasUnreadMessages(for: peerID))

        peerListModel.clearUnread(for: peerID)

        #expect(!viewModel.hasUnreadMessages(for: peerID))
    }

    @Test("ConversationUIModel.clearUnread clears one peer badge")
    func conversationUIModel_clearUnread() {
        let viewModel = makeViewModel()
        let privateConversationModel = PrivateConversationModel(
            chatViewModel: viewModel,
            conversations: viewModel.conversations
        )
        let uiModel = ConversationUIModel(
            chatViewModel: viewModel,
            privateConversationModel: privateConversationModel,
            conversations: viewModel.conversations
        )
        let peerID = PeerID(str: "0011223344556677")

        viewModel.markPrivateChatUnread(peerID)
        uiModel.clearUnread(for: peerID)

        #expect(!viewModel.hasUnreadMessages(for: peerID))
    }

    @Test("markPrivateChatRead is a no-op when the conversation is already read")
    func markPrivateChatRead_idempotent() {
        let viewModel = makeViewModel()
        let peerID = PeerID(str: "0011223344556677")

        viewModel.markPrivateChatRead(peerID)
        viewModel.markPrivateChatUnread(peerID)
        viewModel.markPrivateChatRead(peerID)
        viewModel.markPrivateChatRead(peerID)

        #expect(!viewModel.hasUnreadMessages(for: peerID))
    }
}

@MainActor
private func makeViewModel() -> ChatViewModel {
    let keychain = MockKeychain()
    let keychainHelper = MockKeychainHelper()
    let idBridge = NostrIdentityBridge(keychain: keychainHelper)
    let identityManager = MockIdentityManager(keychain)

    return ChatViewModel(
        keychain: keychain,
        idBridge: idBridge,
        identityManager: identityManager,
        transport: MockTransport()
    )
}

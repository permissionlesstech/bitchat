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

    #if os(macOS)
    // Source-wiring guard only: this does not render the lists or exercise
    // context-menu and accessibility behavior on either platform.
    @Test("Both recent-chat sections forward unread clearing (source wiring)")
    func recentChatSections_forwardClearUnread() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("bitchat/Views/ContentSheetViews.swift"),
            encoding: .utf8
        )
        let calls = try NSRegularExpression(pattern: #"RecentChatList\([\s\S]*?\n\s*\)"#)
        let matches = calls.matches(in: source, range: NSRange(source.startIndex..., in: source))
        #expect(matches.count == 2, "Keep both location and mesh recent-chat sections covered")
        for match in matches {
            let callRange = try #require(Range(match.range, in: source))
            let call = String(source[callRange])
            #expect(call.range(
                of: #"onClearUnread:\s*\{\s*peerID\s+in\s+peerListModel\.clearUnread\(for:\s*peerID\)\s*\}"#,
                options: .regularExpression
            ) != nil, "Every recent-chat section must forward unread clearing to PeerListModel")
        }
    }
    #endif

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

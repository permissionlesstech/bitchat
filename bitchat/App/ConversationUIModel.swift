import BitFoundation
import Combine
import SwiftUI
#if os(iOS)
import UIKit
#endif

@MainActor
final class ConversationUIModel: ObservableObject {
    @Published private(set) var showAutocomplete = false
    @Published private(set) var autocompleteSuggestions: [String] = []
    @Published private(set) var currentNickname: String
    @Published private(set) var isBatchingPublic = false
    @Published private(set) var canSendMediaInCurrentContext = true

    private let chatViewModel: ChatViewModel
    private let privateConversationModel: PrivateConversationModel
    private let conversationStore: ConversationStore
    private var activeChannel: ChannelID
    private var cancellables = Set<AnyCancellable>()

    init(
        chatViewModel: ChatViewModel,
        privateConversationModel: PrivateConversationModel,
        conversationStore: ConversationStore
    ) {
        self.chatViewModel = chatViewModel
        self.privateConversationModel = privateConversationModel
        self.conversationStore = conversationStore
        self.activeChannel = conversationStore.activeChannel
        self.currentNickname = chatViewModel.nickname
        self.isBatchingPublic = chatViewModel.isBatchingPublic
        self.showAutocomplete = chatViewModel.showAutocomplete
        self.autocompleteSuggestions = chatViewModel.autocompleteSuggestions
        self.canSendMediaInCurrentContext = chatViewModel.canSendMediaInCurrentContext

        bind()
    }

    func setCurrentColorScheme(_ colorScheme: ColorScheme) {
        chatViewModel.currentColorScheme = colorScheme
    }

    func sendMessage(_ message: String) {
        chatViewModel.sendMessage(message)
    }

    func clearCurrentConversation() {
        chatViewModel.sendMessage("/clear")
    }

    func sendHug(to sender: String) {
        chatViewModel.sendMessage("/hug @\(sender)")
    }

    func sendSlap(to sender: String) {
        chatViewModel.sendMessage("/slap @\(sender)")
    }

    func block(peerID: PeerID?, displayName: String?) {
        guard let displayName else { return }

        if let peerID, peerID.isGeoChat,
           let full = chatViewModel.fullNostrHex(forSenderPeerID: peerID) {
            chatViewModel.blockGeohashUser(pubkeyHexLowercased: full, displayName: displayName)
        } else {
            chatViewModel.sendMessage("/block \(displayName)")
        }
    }

    func updateAutocomplete(for text: String, cursorPosition: Int) {
        chatViewModel.updateAutocomplete(for: text, cursorPosition: cursorPosition)
    }

    func completeNickname(_ nickname: String, in text: inout String) -> Int {
        chatViewModel.completeNickname(nickname, in: &text)
    }

    func formatMessage(_ message: BitchatMessage, colorScheme: ColorScheme) -> AttributedString {
        chatViewModel.formatMessageAsText(message, colorScheme: colorScheme)
    }

    func formatMessageHeader(_ message: BitchatMessage, colorScheme: ColorScheme) -> AttributedString {
        chatViewModel.formatMessageHeader(message, colorScheme: colorScheme)
    }

    func mediaAttachment(for message: BitchatMessage) -> BitchatMessage.Media? {
        message.mediaAttachment(for: currentNickname)
    }

    func isSelfSender(peerID: PeerID?, displayName: String?) -> Bool {
        chatViewModel.isSelfSender(peerID: peerID, displayName: displayName)
    }

    func isSentByCurrentUser(_ message: BitchatMessage) -> Bool {
        message.sender == currentNickname || message.sender.hasPrefix(currentNickname + "#")
    }

    func isMediaMessageFromCurrentUser(_ message: BitchatMessage) -> Bool {
        message.sender == currentNickname || message.senderPeerID == chatViewModel.meshService.myPeerID
    }

    func senderDisplayName(for peerID: PeerID, fallbackMessages: [BitchatMessage]) -> String? {
        if peerID.isGeoDM || peerID.isGeoChat {
            return chatViewModel.geohashDisplayName(for: peerID)
        }
        if let nickname = chatViewModel.meshService.peerNickname(peerID: peerID) {
            return nickname
        }
        return fallbackMessages.last(where: { $0.senderPeerID == peerID && $0.sender != "system" })?.sender
    }

    #if os(iOS)
    func processSelectedImage(_ image: UIImage?) {
        chatViewModel.processThenSendImage(image)
    }
    #endif

    func processSelectedImage(from url: URL?) {
        #if os(macOS)
        chatViewModel.processThenSendImage(from: url)
        #endif
    }

    func sendVoiceNote(at url: URL) {
        chatViewModel.sendVoiceNote(at: url)
    }

    func cancelMediaSend(messageID: String) {
        chatViewModel.cancelMediaSend(messageID: messageID)
    }

    func deleteMediaMessage(messageID: String) {
        chatViewModel.deleteMediaMessage(messageID: messageID)
    }

    private func bind() {
        chatViewModel.$nickname
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentNickname)

        chatViewModel.$showAutocomplete
            .receive(on: DispatchQueue.main)
            .assign(to: &$showAutocomplete)

        chatViewModel.$autocompleteSuggestions
            .receive(on: DispatchQueue.main)
            .assign(to: &$autocompleteSuggestions)

        chatViewModel.$isBatchingPublic
            .receive(on: DispatchQueue.main)
            .assign(to: &$isBatchingPublic)

        conversationStore.$activeChannel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] channel in
                self?.activeChannel = channel
                self?.refreshComputedState()
            }
            .store(in: &cancellables)

        privateConversationModel.$selectedPeerID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshComputedState()
            }
            .store(in: &cancellables)
    }

    private func refreshComputedState() {
        if let selectedPeerID = privateConversationModel.selectedPeerID {
            canSendMediaInCurrentContext = !(selectedPeerID.isGeoDM || selectedPeerID.isGeoChat)
            return
        }

        switch activeChannel {
        case .mesh:
            canSendMediaInCurrentContext = true
        case .location:
            canSendMediaInCurrentContext = false
        }
    }
}

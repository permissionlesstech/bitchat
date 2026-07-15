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
    /// Who is talking live in the public mesh channel right now (floor
    /// courtesy: the composer mic tints "busy" while someone holds the floor).
    @Published private(set) var activeLiveVoiceTalker: String?

    private let chatViewModel: ChatViewModel
    private let privateConversationModel: PrivateConversationModel
    private let conversations: ConversationStore
    private var activeChannel: ChannelID
    private var cancellables = Set<AnyCancellable>()

    init(
        chatViewModel: ChatViewModel,
        privateConversationModel: PrivateConversationModel,
        conversations: ConversationStore
    ) {
        self.chatViewModel = chatViewModel
        self.privateConversationModel = privateConversationModel
        self.conversations = conversations
        self.activeChannel = conversations.activeChannel
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

    func setCurrentTheme(_ theme: AppTheme) {
        chatViewModel.currentTheme = theme
    }

    func sendMessage(_ message: String) {
        chatViewModel.sendMessage(message)
    }

    /// Resends a failed private message through the normal send path,
    /// removing the failed original so the re-submission replaces it
    /// instead of stacking a duplicate under the red bubble.
    func resendFailedPrivateMessage(_ message: BitchatMessage) {
        chatViewModel.removePrivateMessage(withID: message.id)
        chatViewModel.sendMessage(message.content)
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
        } else if let peerID, !peerID.isGeoDM, !peerID.isGeoChat {
            // Mesh: block the peer's stable Noise identity resolved from the
            // tapped peerID rather than re-resolving a display-name string.
            chatViewModel.blockMeshPeer(peerID: peerID, displayName: displayName)
        } else {
            chatViewModel.sendMessage("/block \(displayName)")
        }
    }

    /// Mesh counterpart of `block(peerID:displayName:)`. Resolves the unblock by
    /// the tapped peer's stable identity so the exact row is unblocked — this
    /// also works for offline peers, which the `/unblock <displayName>` command
    /// cannot resolve.
    func unblock(peerID: PeerID, displayName: String) {
        chatViewModel.unblockMeshPeer(peerID: peerID, displayName: displayName)
    }

    func updateAutocomplete(for text: String, cursorPosition: Int) {
        chatViewModel.updateAutocomplete(for: text, cursorPosition: cursorPosition)
    }

    func completeNickname(_ nickname: String, in text: inout String) -> Int {
        chatViewModel.completeNickname(nickname, in: &text)
    }

    func formatMessage(_ message: BitchatMessage, colorScheme: ColorScheme, theme: AppTheme? = nil) -> AttributedString {
        chatViewModel.formatMessageAsText(message, colorScheme: colorScheme, theme: theme)
    }

    func formatMessageHeader(_ message: BitchatMessage, colorScheme: ColorScheme, theme: AppTheme? = nil) -> AttributedString {
        chatViewModel.formatMessageHeader(message, colorScheme: colorScheme, theme: theme)
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

    /// Capture backend for the mic gesture: live PTT when the current DM
    /// peer can hear it now, classic voice note otherwise.
    func makeVoiceCaptureSession() -> VoiceCaptureSession {
        chatViewModel.makeVoiceCaptureSession()
    }

    /// Whether this message is a live voice burst still streaming in.
    func isLiveVoiceMessage(_ message: BitchatMessage) -> Bool {
        chatViewModel.liveVoiceCoordinator.isLiveVoiceMessage(message)
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

        chatViewModel.$activePublicVoiceTalker
            .receive(on: DispatchQueue.main)
            .assign(to: &$activeLiveVoiceTalker)

        conversations.$activeChannel
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
            // Media transfer is not wired for groups in v1; keep it off so the
            // composer can't strand a media placeholder that never sends.
            canSendMediaInCurrentContext = !(selectedPeerID.isGeoDM || selectedPeerID.isGeoChat || selectedPeerID.isGroup)
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

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
    @Published private(set) var selectedAutocompleteIndex = 0
    @Published private(set) var currentNickname: String
    @Published private(set) var canSendMediaInCurrentContext = true
    @Published private(set) var legacyPrivateMediaConsentRequest: LegacyPrivateMediaConsentRequest?
    /// Who is talking live in the public mesh channel right now (floor
    /// courtesy: the composer mic tints "busy" while someone holds the floor).
    @Published private(set) var activeLiveVoiceTalker: String?

    private let chatViewModel: ChatViewModel
    private let privateConversationModel: PrivateConversationModel
    private let conversations: ConversationStore
    private var activeChannel: ChannelID
    private var cancellables = Set<AnyCancellable>()
    /// My geochat sender ID for the location channel on screen, kept with the
    /// public key it was built from. `publicKeyHex` hex-encodes on every
    /// access, too slow to repeat per row render; keying on the key itself
    /// means a geohash switch or a panic wipe (which reseeds every identity)
    /// can never leave a stale ID behind. A switch to #mesh, where no row
    /// reads it, drops it: a panic wipe always lands there, and the retired
    /// key must not stay in memory until a geochat row next renders.
    /// (Read access is internal so tests can check that.)
    private(set) var ownGeoChatSender: (publicKey: Data, peerID: PeerID)?

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
        self.showAutocomplete = chatViewModel.showAutocomplete
        self.autocompleteSuggestions = chatViewModel.autocompleteSuggestions
        self.selectedAutocompleteIndex = chatViewModel.selectedAutocompleteIndex
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

    func getFingerprint(for peerID: PeerID) -> String? {
        chatViewModel.getFingerprint(for: peerID)
    }

    func updateAutocomplete(for text: String, cursorPosition: Int) {
        chatViewModel.updateAutocomplete(for: text, cursorPosition: cursorPosition)
    }

    func completeNickname(_ nickname: String, in text: inout String) -> Int {
        chatViewModel.completeNickname(nickname, in: &text)
    }

    /// Accept the currently highlighted mention suggestion, if any.
    func completeSelectedSuggestion(in text: inout String) -> Bool {
        guard showAutocomplete,
              autocompleteSuggestions.indices.contains(selectedAutocompleteIndex)
        else { return false }
        _ = completeNickname(autocompleteSuggestions[selectedAutocompleteIndex], in: &text)
        return true
    }

    /// Dismiss the mention suggestion panel without inserting (Escape).
    func dismissAutocomplete() {
        guard showAutocomplete else { return }
        chatViewModel.showAutocomplete = false
        chatViewModel.autocompleteSuggestions = []
        chatViewModel.autocompleteRange = nil
        chatViewModel.selectedAutocompleteIndex = 0
    }

    func moveAutocompleteSelection(by delta: Int) {
        guard showAutocomplete, !autocompleteSuggestions.isEmpty else { return }
        let count = min(4, autocompleteSuggestions.count)
        let next = (selectedAutocompleteIndex + delta + count) % count
        chatViewModel.selectedAutocompleteIndex = next
    }

    func formatMessage(_ message: BitchatMessage, colorScheme: ColorScheme, theme: AppTheme? = nil) -> AttributedString {
        chatViewModel.formatMessageAsText(message, colorScheme: colorScheme, theme: theme)
    }

    func formatMessageHeader(_ message: BitchatMessage, colorScheme: ColorScheme, theme: AppTheme? = nil) -> AttributedString {
        chatViewModel.formatMessageHeader(message, colorScheme: colorScheme, theme: theme)
    }

    func mediaAttachment(for message: BitchatMessage) -> BitchatMessage.Media? {
        // The model loads from outgoing/ exactly when the row's sender equals
        // the name it is given. Ask with the row's own sender first: text rows,
        // most of the timeline, stop here without an identity check per render.
        guard let outgoing = message.mediaAttachment(for: message.sender) else { return nil }
        if isSentByCurrentUser(message) { return outgoing }
        // Not mine by identity: a name the sender can never equal (one
        // character longer) loads it from incoming/, so a namesake's file
        // resolves there while my send from before a rename stays outgoing.
        return message.mediaAttachment(for: message.sender + "\u{0}")
    }

    func isSelfSender(peerID: PeerID?, displayName: String?) -> Bool {
        chatViewModel.isSelfSender(peerID: peerID, displayName: displayName)
    }

    /// Whether this device wrote the row, by the sender ID it carries (see
    /// `BitchatMessage.isOwn`), never by its display name: a namesake, an
    /// `anon#xxxx` stranger next to a reader named "anon", and my own rows
    /// from before a rename are all told apart correctly.
    func isSentByCurrentUser(_ message: BitchatMessage) -> Bool {
        message.isOwn(
            myPeerID: chatViewModel.meshService.myPeerID,
            myGeoChatPeerID: ownGeoChatPeerID()
        )
    }

    func isMediaMessageFromCurrentUser(_ message: BitchatMessage) -> Bool {
        isSentByCurrentUser(message)
    }

    /// My geochat sender ID in the location channel on screen (nil on #mesh),
    /// memoized in `ownGeoChatSender`.
    private func ownGeoChatPeerID() -> PeerID? {
        // The store's channel, not the mirrored `activeChannel`, which trails
        // a switch by a runloop turn.
        guard case .location(let channel) = conversations.activeChannel,
              let identity = chatViewModel.geohashIdentity(for: channel.geohash)
        else { return nil }
        if let cached = ownGeoChatSender, cached.publicKey == identity.publicKey {
            return cached.peerID
        }
        let peerID = PeerID(nostr: identity.publicKeyHex)
        ownGeoChatSender = (identity.publicKey, peerID)
        return peerID
    }

    /// Whether a private-message row should show the filled verification seal
    /// next to the sender name (#1439). Scoped to DMs only — public timelines
    /// have different trust semantics and stay undressed.
    func showsVerifiedSeal(for message: BitchatMessage) -> Bool {
        guard message.isPrivate,
              message.sender != "system",
              !isSentByCurrentUser(message),
              let peerID = message.senderPeerID else { return false }
        guard let fingerprint = chatViewModel.getFingerprint(for: peerID) else { return false }
        return chatViewModel.peerIdentityStore.isVerified(fingerprint)
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

    func resolveLegacyPrivateMediaConsent(requestID: UUID, approved: Bool) {
        chatViewModel.resolveLegacyPrivateMediaConsent(
            requestID: requestID,
            approved: approved
        )
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
        // Every message row observes this model, so each republish re-renders
        // all of them: forward only real changes, never a re-sent equal value.
        chatViewModel.$nickname
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentNickname)

        chatViewModel.$showAutocomplete
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$showAutocomplete)

        chatViewModel.$autocompleteSuggestions
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$autocompleteSuggestions)

        chatViewModel.$selectedAutocompleteIndex
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$selectedAutocompleteIndex)

        chatViewModel.$activePublicVoiceTalker
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$activeLiveVoiceTalker)

        chatViewModel.$legacyPrivateMediaConsentRequest
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$legacyPrivateMediaConsentRequest)

        conversations.$activeChannel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] channel in
                self?.activeChannel = channel
                if channel == .mesh {
                    self?.ownGeoChatSender = nil
                }
                self?.refreshComputedState()
            }
            .store(in: &cancellables)

        privateConversationModel.$selectedPeerID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshComputedState()
            }
            .store(in: &cancellables)

        // Verify/unverify while a DM is open must repaint existing rows —
        // showsVerifiedSeal is computed per render, so forward the store change.
        chatViewModel.peerIdentityStore.$verifiedFingerprints
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    private func refreshComputedState() {
        let canSendMedia: Bool
        if let selectedPeerID = privateConversationModel.selectedPeerID {
            // Media transfer is not wired for groups in v1; keep it off so the
            // composer can't strand a media placeholder that never sends.
            canSendMedia = !(selectedPeerID.isGeoDM || selectedPeerID.isGeoChat || selectedPeerID.isGroup)
        } else {
            switch activeChannel {
            case .mesh:
                canSendMedia = true
            case .location:
                canSendMedia = false
            }
        }
        // Every write republishes to every message row, and most triggers
        // (each peer, favorite or status refresh of the selection) leave the
        // value as it was.
        if canSendMediaInCurrentContext != canSendMedia {
            canSendMediaInCurrentContext = canSendMedia
        }
    }
}

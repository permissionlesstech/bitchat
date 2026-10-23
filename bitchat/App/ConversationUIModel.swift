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

    // MARK: Sending and list actions
    //
    // Each takes the conversation the person acted in: the composer's or
    // the list's own target, captured when they acted. The few target-less
    // forms left act on the selection.

    func sendMessage(_ message: String) {
        sendMessage(message, to: chatViewModel.selectionTarget)
    }

    /// Sends `message` (or runs it as a command) in `target`, whatever is
    /// selected by the time it goes out.
    func sendMessage(_ message: String, to target: ConversationTarget) {
        chatViewModel.sendMessage(message, to: target)
    }

    /// Resends a failed private message through the normal send path,
    /// removing the failed original so the re-submission replaces it
    /// instead of stacking a duplicate under the red bubble.
    func resendFailedPrivateMessage(_ message: BitchatMessage, in target: ConversationTarget) {
        chatViewModel.removePrivateMessage(withID: message.id)
        chatViewModel.sendMessage(message.content, to: target)
    }

    /// Clears `target`: its DM, or its channel's timeline.
    func clearConversation(_ target: ConversationTarget) {
        chatViewModel.sendMessage("/clear", to: target)
    }

    func sendHug(to sender: String, in target: ConversationTarget) {
        chatViewModel.sendMessage("/hug @\(sender)", to: target)
    }

    func sendSlap(to sender: String, in target: ConversationTarget) {
        chatViewModel.sendMessage("/slap @\(sender)", to: target)
    }

    func block(peerID: PeerID?, displayName: String?) {
        block(peerID: peerID, displayName: displayName, from: chatViewModel.selectionTarget)
    }

    /// Blocks someone tapped in `target`'s list; a confirmation or failure
    /// line lands in that conversation.
    func block(peerID: PeerID?, displayName: String?, from target: ConversationTarget) {
        guard let displayName else { return }

        if let peerID, peerID.isGeoChat,
           let full = chatViewModel.fullNostrHex(forSenderPeerID: peerID) {
            chatViewModel.blockGeohashUser(pubkeyHexLowercased: full, displayName: displayName)
        } else if let peerID, !peerID.isGeoDM, !peerID.isGeoChat {
            // Mesh: block the peer's stable Noise identity resolved from the
            // tapped peerID rather than re-resolving a display-name string.
            chatViewModel.blockMeshPeer(peerID: peerID, displayName: displayName, from: target)
        } else {
            chatViewModel.sendMessage("/block \(displayName)", to: target)
        }
    }

    /// Mesh counterpart of `block(peerID:displayName:)`. Resolves the unblock by
    /// the tapped peer's stable identity so the exact row is unblocked — this
    /// also works for offline peers, which the `/unblock <displayName>` command
    /// cannot resolve.
    func unblock(peerID: PeerID, displayName: String) {
        unblock(peerID: peerID, displayName: displayName, from: chatViewModel.selectionTarget)
    }

    /// Unblocks someone toggled in `target`'s list; a confirmation or
    /// failure line lands in that conversation.
    func unblock(peerID: PeerID, displayName: String, from target: ConversationTarget) {
        chatViewModel.unblockMeshPeer(peerID: peerID, displayName: displayName, from: target)
    }

    func getFingerprint(for peerID: PeerID) -> String? {
        chatViewModel.getFingerprint(for: peerID)
    }

    /// Mention suggestions for `text` in `target`'s composer. The composer
    /// keeps the returned state; nothing shared changes.
    func autocomplete(
        for text: String,
        cursorPosition: Int,
        in target: ConversationTarget
    ) -> ComposerAutocompleteState {
        chatViewModel.autocomplete(for: text, cursorPosition: cursorPosition, in: target)
    }

    /// Applies a picked suggestion to the text `state` was computed for and
    /// returns the cursor position after it.
    func complete(_ suggestion: String, in text: inout String, state: ComposerAutocompleteState) -> Int {
        chatViewModel.complete(suggestion, in: &text, state: state)
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
    /// Sends a photo picked from `target`'s composer to that conversation.
    /// Capture the target when the camera or library button is tapped.
    func processSelectedImage(_ image: UIImage?, to target: ConversationTarget) {
        chatViewModel.processThenSendImage(image, to: target)
    }
    #endif

    #if os(macOS)
    /// Sends a photo file picked from `target`'s composer to that
    /// conversation. Capture the target when the photo button is clicked.
    func processSelectedImage(from url: URL?, to target: ConversationTarget) {
        chatViewModel.processThenSendImage(from: url, to: target)
    }
    #endif

    /// Make this at the mic's release and pass it as the recorder's
    /// completion: the voice note goes to the conversation on screen then,
    /// even if the person leaves it before the file is finalized.
    func makeVoiceNoteSender() -> (URL) -> Void {
        chatViewModel.makeVoiceNoteSender()
    }

    /// The release completion for `target`'s composer: the note goes to that
    /// conversation, whatever is selected once the file is finalized.
    func makeVoiceNoteSender(for target: ConversationTarget) -> (URL) -> Void {
        chatViewModel.makeVoiceNoteSender(for: target)
    }

    func resolveLegacyPrivateMediaConsent(requestID: UUID, approved: Bool) {
        chatViewModel.resolveLegacyPrivateMediaConsent(
            requestID: requestID,
            approved: approved
        )
    }

    /// Capture backend for a hold in `target`'s composer: live to that DM's
    /// peer or to #mesh when they can hear it now, a classic note otherwise.
    /// Never live to any conversation but the composer's own.
    func makeVoiceCaptureSession(for target: ConversationTarget) -> VoiceCaptureSession {
        chatViewModel.makeVoiceCaptureSession(for: target)
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
        // One table for every composer: the selection's target allows media
        // exactly where a composer's own target would. (Media transfer is not
        // wired for groups in v1, so a group never takes it.)
        let canSendMedia = ConversationTarget(
            channel: activeChannel,
            privatePeer: privateConversationModel.selectedPeerID
        ).allowsMedia
        // Every write republishes to every message row, and most triggers
        // (each peer, favorite or status refresh of the selection) leave the
        // value as it was.
        if canSendMediaInCurrentContext != canSendMedia {
            canSendMediaInCurrentContext = canSendMedia
        }
    }
}

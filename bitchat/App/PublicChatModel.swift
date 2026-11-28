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
    struct UnreadMeshPreview: Equatable {
        let sender: String
        let text: String
    }

    @Published private(set) var activeChannel: ChannelID
    private(set) var unreadMeshMessageCount: Int = 0
    private(set) var latestUnreadMeshPreview: UnreadMeshPreview? = nil

    /// The active public conversation's timeline.
    var messages: [BitchatMessage] { activeConversation.messages }

    private let conversations: ConversationStore
    private let myPeerIDProvider: () -> PeerID?
    private var activeConversation: Conversation
    private var activeConversationCancellable: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()
    private var isViewingNearbyMesh: Bool

    init(
        conversations: ConversationStore,
        myPeerIDProvider: @escaping () -> PeerID? = { nil }
    ) {
        let channel = conversations.activeChannel
        self.conversations = conversations
        self.myPeerIDProvider = myPeerIDProvider
        self.activeChannel = channel
        self.isViewingNearbyMesh = (channel == .mesh)
        self.activeConversation = conversations.conversation(for: ConversationID(channelID: channel))

        observeActiveConversation()
        bind()
    }

    /// Tracks whether the user is currently looking at the Nearby (`#mesh`)
    /// timeline. Switching to Nearby immediately clears any unread badge.
    func setViewingNearbyMesh(_ viewing: Bool) {
        isViewingNearbyMesh = viewing
        if viewing {
            clearUnreadMesh()
        }
    }

    func clearUnreadMesh() {
        guard unreadMeshMessageCount != 0 || latestUnreadMeshPreview != nil else { return }
        objectWillChange.send()
        unreadMeshMessageCount = 0
        latestUnreadMeshPreview = nil
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

        conversations.changes
            .sink { [weak self] change in
                guard let self else { return }
                switch change {
                case .removed(let id):
                    if id == .mesh {
                        self.clearUnreadMesh()
                    }
                    if id == self.activeConversation.id {
                        self.retargetActiveConversation(to: self.activeChannel)
                    }
                case .cleared(let id):
                    if id == .mesh {
                        self.clearUnreadMesh()
                    }
                case .appended(let id, let message):
                    guard id == .mesh else { return }
                    self.recordInboundMeshMessageIfUnread(message)
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }

    private func recordInboundMeshMessageIfUnread(_ message: BitchatMessage) {
        guard !isViewingNearbyMesh else { return }
        guard message.sender != "system" else { return }
        if let myID = myPeerIDProvider(), message.senderPeerID == myID {
            return
        }
        guard MessageInteractionCodec.parseReaction(from: message.content) == nil else {
            return
        }

        let preview = Self.formattedPreview(for: message.content)
        // When `activeConversation` is already `.mesh`, `ConversationStore`
        // emits a single `activeConversation.objectWillChange` per append/batch;
        // only emit explicitly here when observing a non-mesh channel.
        if activeConversation.id != .mesh {
            objectWillChange.send()
        }
        unreadMeshMessageCount += 1
        latestUnreadMeshPreview = UnreadMeshPreview(sender: message.sender, text: preview)
    }

    private static func formattedPreview(for rawContent: String) -> String {
        let body = MessageInteractionCodec.parseReply(from: rawContent)?.body ?? rawContent
        if body.hasPrefix(MimeType.Category.audio.messagePrefix) {
            return String(localized: "chats.nearby_banner.voice_preview", defaultValue: "Voice message", comment: "Preview text for an unread Nearby voice message")
        }
        if body.hasPrefix(MimeType.Category.image.messagePrefix) {
            return String(localized: "chats.nearby_banner.photo_preview", defaultValue: "Photo", comment: "Preview text for an unread Nearby photo message")
        }
        return body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

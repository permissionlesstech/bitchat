import BitFoundation
import BitLogger
import Foundation

/// The surface `ChatNostrCoordinator` needs from its owner.
///
/// Inherits the component contexts (`GeohashSubscriptionContext`,
/// `NostrInboundPipelineContext`, `GeoPresenceContext`) so a single object —
/// `ChatViewModel` in production, one mock in tests — can back the whole
/// Nostr stack. The members declared here are only the residual
/// favorites/ack glue the slimmed coordinator still owns.
@MainActor
protocol ChatNostrContext: GeohashSubscriptionContext, NostrInboundPipelineContext, GeoPresenceContext {
    var selectedPrivateChatPeer: PeerID? { get }
    var nostrKeyMapping: [PeerID: String] { get }
    func startPrivateChat(with peerID: PeerID)
    func visibleGeohashPeople() -> [GeoPerson]

    // MARK: Routing & acknowledgements (shared with `ChatPrivateConversationContext`)
    func routeFavoriteNotification(to peerID: PeerID, isFavorite: Bool)
    func sendGeohashDeliveryAck(for messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity)
    func sendGeohashReadReceipt(_ messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity)

    // MARK: Favorites (shared with the other contexts)
    /// The persisted favorite relationship for the peer's Noise static key, if any.
    func favoriteRelationship(forNoiseKey noiseKey: Data) -> FavoritesPersistenceService.FavoriteRelationship?
}

extension ChatViewModel: ChatNostrContext {
    // All requirements — including the component-context witnesses declared
    // in `GeohashSubscriptionManager.swift`, `NostrInboundPipeline.swift`,
    // `GeoPresenceTracker.swift`, and the favorites/notification witnesses in
    // `ChatPrivateConversationCoordinator.swift`,
    // `ChatPeerIdentityCoordinator.swift`, and
    // `ChatVerificationCoordinator.swift` — already exist on `ChatViewModel`.
}

/// Thin facade over the Nostr stack: owns and wires the three components and
/// keeps the residual favorites/ack glue that fits none of them.
///
/// - `subscriptions`: relay lifecycle and subscription IDs
///   (`GeohashSubscriptionManager`)
/// - `inbound`: the hot event -> message/payload pipeline
///   (`NostrInboundPipeline`)
/// - `presence`: teleport marking, sampling dedup, notification cooldown
///   (`GeoPresenceTracker`)
final class ChatNostrCoordinator {
    private weak var context: (any ChatNostrContext)?
    let presence: GeoPresenceTracker
    let inbound: NostrInboundPipeline
    let subscriptions: GeohashSubscriptionManager

    init(context: any ChatNostrContext) {
        self.context = context
        let presence = GeoPresenceTracker(context: context)
        let inbound = NostrInboundPipeline(context: context, presence: presence)
        self.presence = presence
        self.inbound = inbound
        self.subscriptions = GeohashSubscriptionManager(context: context, inbound: inbound, presence: presence)
    }

    @MainActor
    func sendDeliveryAckViaNostrEmbedded(
        _ message: BitchatMessage,
        wasReadBefore: Bool,
        senderPubkey: String,
        key: Data?
    ) {
        guard let context else { return }
        if key != nil {
            if let identity = context.currentNostrIdentity() {
                context.sendGeohashDeliveryAck(for: message.id, toRecipientHex: senderPubkey, from: identity)
            }
        } else if let identity = context.currentNostrIdentity() {
            context.sendGeohashDeliveryAck(for: message.id, toRecipientHex: senderPubkey, from: identity)
            SecureLogger.debug(
                "Sent DELIVERED ack directly to Nostr pub=\(senderPubkey.prefix(8))… for mid=\(message.id.prefix(8))…",
                category: .session
            )
        }

        if !wasReadBefore && context.selectedPrivateChatPeer == message.senderPeerID {
            if key != nil {
                if let identity = context.currentNostrIdentity() {
                    context.sendGeohashReadReceipt(message.id, toRecipientHex: senderPubkey, from: identity)
                }
            } else if let identity = context.currentNostrIdentity() {
                context.sendGeohashReadReceipt(message.id, toRecipientHex: senderPubkey, from: identity)
                SecureLogger.debug(
                    "Viewing chat; sent READ ack directly to Nostr pub=\(senderPubkey.prefix(8))… for mid=\(message.id.prefix(8))…",
                    category: .session
                )
            }
        }
    }

    @MainActor
    func sendFavoriteNotificationViaNostr(noisePublicKey: Data, isFavorite: Bool) {
        guard let context else { return }
        guard let relationship = context.favoriteRelationship(forNoiseKey: noisePublicKey),
              relationship.peerNostrPublicKey != nil else {
            SecureLogger.warning("⚠️ Cannot send favorite notification - no Nostr key for peer", category: .session)
            return
        }

        let peerID = PeerID(hexData: noisePublicKey)
        context.routeFavoriteNotification(to: peerID, isFavorite: isFavorite)
    }

    @MainActor
    func nostrPubkeyForDisplayName(_ name: String) -> String? {
        guard let context else { return nil }
        for person in context.visibleGeohashPeople() where person.displayName == name {
            return person.id
        }
        for (pub, nick) in context.geoNicknames where nick == name {
            return pub
        }
        return nil
    }

    @MainActor
    func startGeohashDM(withPubkeyHex hex: String) {
        guard let context else { return }
        let convKey = PeerID(nostr_: hex)
        context.registerNostrKeyMapping(hex, for: convKey)
        context.startPrivateChat(with: convKey)
    }

    @MainActor
    func fullNostrHex(forSenderPeerID senderID: PeerID) -> String? {
        guard let context else { return nil }
        return context.nostrKeyMapping[senderID]
    }

    @MainActor
    func geohashDisplayName(for convKey: PeerID) -> String {
        guard let context else { return convKey.bare }
        guard let full = context.nostrKeyMapping[convKey] else {
            return convKey.bare
        }
        return context.displayNameForNostrPubkey(full)
    }
}

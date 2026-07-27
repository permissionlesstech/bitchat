import BitFoundation
import BitLogger
import Foundation
import Tor

/// The narrow surface `GeohashSubscriptionManager` needs from its owner.
///
/// Split out of `ChatNostrContext`: member names are shared with the sibling
/// component contexts so `ChatViewModel` provides a single witness for each.
@MainActor
protocol GeohashSubscriptionContext: AnyObject {
    // MARK: Channel & subscription state
    var activeChannel: ChannelID { get set }
    var currentGeohash: String? { get set }
    var geoSubscriptionID: String? { get }
    var geoDmSubscriptionID: String? { get }
    func setGeoChatSubscriptionID(_ id: String?)
    func setGeoDmSubscriptionID(_ id: String?)
    /// Geohash sampling subscriptions: subscription ID -> geohash.
    var geoSamplingSubs: [String: String] { get }
    func addGeoSamplingSub(_ subID: String, forGeohash geohash: String)
    func removeGeoSamplingSub(_ subID: String)
    /// Clears all sampling subscriptions and returns the removed subscription IDs
    /// so the caller can unsubscribe them from the relay manager.
    func clearGeoSamplingSubs() -> [String]
    var nostrRelayManager: NostrRelayManager? { get }

    // MARK: Public timeline & pipeline
    var messages: [BitchatMessage] { get }
    /// Commits any batched-but-unflushed public messages to the store so a
    /// channel switch never strands them in the pipeline buffer.
    func flushPublicMessagePipeline()
    func refreshVisibleMessages(from channel: ChannelID?)
    func addPublicSystemMessage(_ content: String)
    func drainPendingGeohashSystemMessages() -> [String]

    // MARK: Nostr identity & dedup
    func deriveNostrIdentity(forGeohash geohash: String) throws -> NostrIdentity
    func currentNostrIdentity() -> NostrIdentity?
    func recordProcessedNostrEvent(_ eventID: String)
    func clearProcessedNostrEvents()
    /// Records the Nostr pubkey behind a (possibly virtual) peer ID.
    func registerNostrKeyMapping(_ pubkey: String, for peerID: PeerID)

    // MARK: Geo participants & presence
    var teleportedGeoCount: Int { get }
    func startGeoParticipantRefreshTimer()
    func stopGeoParticipantRefreshTimer()
    func setActiveParticipantGeohash(_ geohash: String?)
    func recordGeoParticipant(pubkeyHex: String)
    func markGeoTeleported(_ pubkeyHexLowercased: String)
    func clearGeoTeleported(_ pubkeyHexLowercased: String)
    func clearTeleportedGeo()
    func clearGeoNicknames()

    // MARK: Location channels
    var isTeleported: Bool { get }
    /// True when regional channels are known and the geohash is not one of them.
    func isGeohashOutsideRegionalChannels(_ geohash: String) -> Bool
}

extension ChatViewModel: GeohashSubscriptionContext {
    // `activeChannel`, `currentGeohash`, the subscription-ID accessors, the
    // identity members, and the timeline members already have witnesses on
    // `ChatViewModel`. The members below flatten nested service accesses into
    // intent-named calls.

    func flushPublicMessagePipeline() {
        publicMessagePipeline.flushIfNeeded()
    }

    func clearProcessedNostrEvents() {
        deduplicationService.clearNostrCaches()
    }

    func startGeoParticipantRefreshTimer() {
        participantTracker.startRefreshTimer()
    }

    func stopGeoParticipantRefreshTimer() {
        participantTracker.stopRefreshTimer()
    }

    func setActiveParticipantGeohash(_ geohash: String?) {
        participantTracker.setActiveGeohash(geohash)
    }

    func clearGeoTeleported(_ pubkeyHexLowercased: String) {
        locationPresenceStore.clearTeleported(pubkeyHexLowercased)
    }

    func clearTeleportedGeo() {
        locationPresenceStore.clearTeleportedGeo()
    }

    func clearGeoNicknames() {
        locationPresenceStore.clearGeoNicknames()
    }

    var isTeleported: Bool {
        locationManager.teleported
    }

    func isGeohashOutsideRegionalChannels(_ geohash: String) -> Bool {
        let channels = locationManager.availableChannels
        return !channels.isEmpty && !channels.contains { $0.geohash == geohash }
    }
}

/// Owns subscription IDs and relay lifecycle for geohash channels, geohash
/// DMs, the account gift-wrap mailbox, and background geohash sampling. The
/// only component that talks to `NostrRelayManager`; inbound events are
/// forwarded to `NostrInboundPipeline` / `GeoPresenceTracker`.
final class GeohashSubscriptionManager {
    private weak var context: (any GeohashSubscriptionContext)?
    private let inbound: NostrInboundPipeline
    private let presence: GeoPresenceTracker
    /// Geohashes already told "sent via mesh gateway" this session, so the
    /// notice appears once per channel instead of once per message.
    private var gatewayNoticeGeohashes = Set<String>()

    init(context: any GeohashSubscriptionContext, inbound: NostrInboundPipeline, presence: GeoPresenceTracker) {
        self.context = context
        self.inbound = inbound
        self.presence = presence
    }

    @MainActor
    func resubscribeCurrentGeohash() {
        guard let context else { return }
        guard case .location(let channel) = context.activeChannel else { return }
        guard let subID = context.geoSubscriptionID else {
            switchLocationChannel(to: context.activeChannel)
            return
        }

        context.startGeoParticipantRefreshTimer()
        NostrRelayManager.shared.unsubscribe(id: subID)
        let filter = NostrFilter.geohashEphemeral(
            channel.geohash,
            since: Date().addingTimeInterval(-TransportConfig.nostrGeohashInitialLookbackSeconds),
            limit: TransportConfig.nostrGeohashInitialLimit
        )
        let subRelays = GeoRelayDirectory.shared.closestRelays(
            toGeohash: channel.geohash,
            count: TransportConfig.nostrGeoRelayCount
        )
        NostrRelayManager.shared.subscribe(filter: filter, id: subID, relayUrls: subRelays) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.inbound.subscribeNostrEvent(event)
                // Gateway downlink: rebroadcast relay events for the viewed
                // channel onto the mesh (no-op unless gateway mode is on).
                GatewayService.shared.rebroadcastRelayEvent(event, geohash: channel.geohash)
            }
        }

        if let dmSub = context.geoDmSubscriptionID {
            NostrRelayManager.shared.unsubscribe(id: dmSub)
            context.setGeoDmSubscriptionID(nil)
        }

        if let identity = try? context.deriveNostrIdentity(forGeohash: channel.geohash) {
            let dmSub = "geo-dm-\(channel.geohash)"
            context.setGeoDmSubscriptionID(dmSub)
            let dmFilter = NostrFilter.giftWrapsFor(
                pubkey: identity.publicKeyHex,
                since: Date().addingTimeInterval(-TransportConfig.nostrDMSubscribeLookbackSeconds)
            )
            NostrRelayManager.shared.subscribe(filter: dmFilter, id: dmSub) { [weak self] giftWrap in
                Task { @MainActor [weak self] in
                    self?.inbound.subscribeGiftWrap(giftWrap, id: identity)
                }
            }
        }
    }

    @MainActor
    func switchLocationChannel(to channel: ChannelID) {
        guard let context else { return }
        context.flushPublicMessagePipeline()
        context.activeChannel = channel

        context.clearProcessedNostrEvents()
        switch channel {
        case .mesh:
            context.refreshVisibleMessages(from: .mesh)
            let emptyMesh = context.messages.filter { $0.content.trimmed.isEmpty }.count
            if emptyMesh > 0 {
                SecureLogger.debug("RenderGuard: mesh timeline contains \(emptyMesh) empty messages", category: .session)
            }
            context.stopGeoParticipantRefreshTimer()
            context.setActiveParticipantGeohash(nil)
            context.clearTeleportedGeo()

        case .location:
            context.refreshVisibleMessages(from: channel)
        }

        if case .location = channel {
            for content in context.drainPendingGeohashSystemMessages() {
                context.addPublicSystemMessage(content)
            }
        }

        if let sub = context.geoSubscriptionID {
            NostrRelayManager.shared.unsubscribe(id: sub)
            context.setGeoChatSubscriptionID(nil)
        }
        if let dmSub = context.geoDmSubscriptionID {
            NostrRelayManager.shared.unsubscribe(id: dmSub)
            context.setGeoDmSubscriptionID(nil)
        }
        context.currentGeohash = nil
        context.setActiveParticipantGeohash(nil)
        context.clearGeoNicknames()

        guard case .location(let channel) = channel else { return }
        context.currentGeohash = channel.geohash
        context.setActiveParticipantGeohash(channel.geohash)

        if let identity = try? context.deriveNostrIdentity(forGeohash: channel.geohash) {
            context.recordGeoParticipant(pubkeyHex: identity.publicKeyHex)
            let key = identity.publicKeyHex.lowercased()
            if context.isTeleported && context.isGeohashOutsideRegionalChannels(channel.geohash) {
                context.markGeoTeleported(key)
                SecureLogger.info(
                    "GeoTeleport: channel switch mark self teleported key=\(key.prefix(8))… total=\(context.teleportedGeoCount)",
                    category: .session
                )
            } else {
                context.clearGeoTeleported(key)
            }
        }

        let subID = "geo-\(channel.geohash)"
        context.setGeoChatSubscriptionID(subID)
        context.startGeoParticipantRefreshTimer()
        let ts = Date().addingTimeInterval(-TransportConfig.nostrGeohashInitialLookbackSeconds)
        let filter = NostrFilter.geohashEphemeral(channel.geohash, since: ts, limit: TransportConfig.nostrGeohashInitialLimit)
        let subRelays = GeoRelayDirectory.shared.closestRelays(toGeohash: channel.geohash, count: 5)
        NostrRelayManager.shared.subscribe(filter: filter, id: subID, relayUrls: subRelays) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.inbound.handleNostrEvent(event)
                // Gateway downlink: rebroadcast relay events for the viewed
                // channel onto the mesh (no-op unless gateway mode is on).
                GatewayService.shared.rebroadcastRelayEvent(event, geohash: channel.geohash)
            }
        }

        subscribeToGeoChat(channel)
    }

    @MainActor
    func subscribeToGeoChat(_ channel: GeohashChannel) {
        guard let context else { return }
        guard let identity = try? context.deriveNostrIdentity(forGeohash: channel.geohash) else { return }

        let dmSub = "geo-dm-\(channel.geohash)"
        context.setGeoDmSubscriptionID(dmSub)
        if TorManager.shared.isReady {
            SecureLogger.debug("GeoDM: subscribing DMs pub=\(identity.publicKeyHex.prefix(8))… sub=\(dmSub)", category: .session)
        }
        let dmFilter = NostrFilter.giftWrapsFor(
            pubkey: identity.publicKeyHex,
            since: Date().addingTimeInterval(-TransportConfig.nostrDMSubscribeLookbackSeconds)
        )
        NostrRelayManager.shared.subscribe(filter: dmFilter, id: dmSub) { [weak self] giftWrap in
            Task { @MainActor [weak self] in
                self?.inbound.handleGiftWrap(giftWrap, id: identity)
            }
        }
    }

    @MainActor
    func sendGeohash(context geoContext: ChatViewModel.GeoOutgoingContext) {
        guard let context else { return }
        let channel = geoContext.channel
        let event = geoContext.event
        let identity = geoContext.identity

        let targetRelays = GeoRelayDirectory.shared.closestRelays(
            toGeohash: channel.geohash,
            count: TransportConfig.nostrGeoRelayCount
        )

        if targetRelays.isEmpty {
            SecureLogger.warning("Geo: no geohash relays available for \(channel.geohash); not sending", category: .session)
        } else {
            NostrRelayManager.shared.sendEvent(event, to: targetRelays)
        }

        // Mesh gateway uplink: with no working relay connection, hand the
        // locally signed event to a mesh peer advertising the gateway
        // capability (keys never leave this device — only the finished,
        // signed event travels). Uplink is only ever attempted here, for a
        // freshly composed event, never for received carrier events (loop
        // rule 3 in GatewayService).
        if GatewayService.shared.uplinkViaMesh(event: event, geohash: channel.geohash),
           gatewayNoticeGeohashes.insert(channel.geohash).inserted {
            context.addPublicSystemMessage(
                String(
                    localized: "system.gateway.sent_via_mesh",
                    defaultValue: "sent via mesh gateway",
                    comment: "System message when a geohash message was handed to a mesh internet gateway because no relay is reachable"
                )
            )
        }

        context.recordGeoParticipant(pubkeyHex: identity.publicKeyHex)
        context.registerNostrKeyMapping(identity.publicKeyHex, for: PeerID(nostr: identity.publicKeyHex))
        SecureLogger.debug(
            "GeoTeleport: sent geo message pub=\(identity.publicKeyHex.prefix(8))… teleported=\(geoContext.teleported)",
            category: .session
        )

        if geoContext.teleported && context.isGeohashOutsideRegionalChannels(channel.geohash) {
            let key = identity.publicKeyHex.lowercased()
            context.markGeoTeleported(key)
            SecureLogger.info(
                "GeoTeleport: mark self teleported key=\(key.prefix(8))… total=\(context.teleportedGeoCount)",
                category: .session
            )
        }

        context.recordProcessedNostrEvent(event.id)
    }

    @MainActor
    func beginGeohashSampling(for geohashes: [String]) {
        guard let context else { return }
        if !TorManager.shared.isForeground() {
            endGeohashSampling()
            return
        }

        let desired = Set(geohashes)
        let current = Set(context.geoSamplingSubs.values)
        let toAdd = desired.subtracting(current)
        let toRemove = current.subtracting(desired)

        for (subID, gh) in context.geoSamplingSubs where toRemove.contains(gh) {
            NostrRelayManager.shared.unsubscribe(id: subID)
            context.removeGeoSamplingSub(subID)
        }

        for gh in toAdd {
            subscribe(gh)
        }
    }

    @MainActor
    func subscribe(_ gh: String) {
        guard let context else { return }
        let subID = "geo-sample-\(gh)"
        context.addGeoSamplingSub(subID, forGeohash: gh)
        let filter = NostrFilter.geohashEphemeral(
            gh,
            since: Date().addingTimeInterval(-TransportConfig.nostrGeohashSampleLookbackSeconds),
            limit: TransportConfig.nostrGeohashSampleLimit
        )
        let subRelays = GeoRelayDirectory.shared.closestRelays(toGeohash: gh, count: 5)
        NostrRelayManager.shared.subscribe(filter: filter, id: subID, relayUrls: subRelays) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.presence.subscribeNostrEvent(event, gh: gh)
            }
        }
    }

    @MainActor
    func endGeohashSampling() {
        guard let context else { return }
        for subID in context.clearGeoSamplingSubs() {
            NostrRelayManager.shared.unsubscribe(id: subID)
        }
        presence.clearGeoSamplingEventDedup()
    }

    @MainActor
    func setupNostrMessageHandling() {
        guard let context else { return }
        guard let currentIdentity = context.currentNostrIdentity() else {
            SecureLogger.warning("⚠️ No Nostr identity available for message handling", category: .session)
            return
        }

        SecureLogger.debug(
            "🔑 Setting up Nostr subscription for pubkey: \(currentIdentity.publicKeyHex.prefix(16))...",
            category: .session
        )

        let filter = NostrFilter.giftWrapsFor(
            pubkey: currentIdentity.publicKeyHex,
            since: Date().addingTimeInterval(-TransportConfig.nostrDMSubscribeLookbackSeconds)
        )

        context.nostrRelayManager?.subscribe(filter: filter, id: "chat-messages") { [weak self] event in
            Task { @MainActor [weak self] in
                self?.inbound.handleNostrMessage(event)
            }
        }
    }
}

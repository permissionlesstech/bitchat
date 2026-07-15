import BitFoundation
import BitLogger
import Foundation
import SwiftUI

/// The narrow surface `GeoPresenceTracker` needs from its owner.
///
/// Split out of `ChatNostrContext`: member names are shared with the sibling
/// component contexts so `ChatViewModel` provides a single witness for each.
@MainActor
protocol GeoPresenceContext: AnyObject {
    var activeChannel: ChannelID { get }
    /// Per-geohash notification cooldown: geohash -> last notify time.
    var lastGeoNotificationAt: [String: Date] { get set }
    var geoNicknames: [String: String] { get }
    var teleportedGeoCount: Int { get }

    func deriveNostrIdentity(forGeohash geohash: String) throws -> NostrIdentity
    func isNostrBlocked(pubkeyHexLowercased: String) -> Bool
    func parseMentions(from content: String) -> [String]

    func recordGeoParticipant(pubkeyHex: String, geohash: String)
    func geoParticipantCount(for geohash: String) -> Int
    func markGeoTeleported(_ pubkeyHexLowercased: String)

    /// Appends a geohash message if absent (single-writer store intent).
    /// Returns `true` when stored.
    @discardableResult
    func appendGeohashMessageIfAbsent(_ message: BitchatMessage, toGeohash geohash: String) -> Bool

    /// Posts the sampled-geohash-activity local notification.
    func notifyGeohashActivity(geohash: String, bodyPreview: String)
}

extension ChatViewModel: GeoPresenceContext {
    // `activeChannel`, `lastGeoNotificationAt`, `geoNicknames`, the Nostr
    // identity/blocking members, and the
    // `appendGeohashMessageIfAbsent(_:toGeohash:)` store intent already have
    // witnesses on `ChatViewModel`. The members below flatten nested service
    // accesses into intent-named calls.

    var teleportedGeoCount: Int {
        locationPresenceStore.teleportedGeo.count
    }

    func recordGeoParticipant(pubkeyHex: String, geohash: String) {
        participantTracker.recordParticipant(pubkeyHex: pubkeyHex, geohash: geohash)
    }

    func geoParticipantCount(for geohash: String) -> Int {
        participantTracker.participantCount(for: geohash)
    }

    func markGeoTeleported(_ pubkeyHexLowercased: String) {
        locationPresenceStore.markTeleported(pubkeyHexLowercased)
    }

    func notifyGeohashActivity(geohash: String, bodyPreview: String) {
        NotificationService.shared.sendGeohashActivityNotification(geohash: geohash, bodyPreview: bodyPreview)
    }
}

/// Geohash presence bookkeeping that is independent of relay subscriptions:
/// teleport-tag detection and marking, the sampling-event LRU dedup, and the
/// per-geohash notification cooldown for sampled activity.
final class GeoPresenceTracker {
    private weak var context: (any GeoPresenceContext)?
    private var recentGeoSamplingEventIDs = Set<String>()
    private var recentGeoSamplingEventIDOrder: [String] = []

    init(context: any GeoPresenceContext) {
        self.context = context
    }

    /// True when the event carries a `["t", "teleport"]` tag.
    static func hasTeleportTag(_ event: NostrEvent) -> Bool {
        event.tags.contains { tag in
            tag.count >= 2 && tag[0].lowercased() == "t" && tag[1].lowercased() == "teleport"
        }
    }

    /// Marks a peer teleported on a follow-up main-actor hop (keeps the
    /// inbound hot path free of presence-store writes).
    @MainActor
    func scheduleMarkPeerTeleported(_ key: String, logged: Bool) {
        Task { @MainActor [weak context] in
            guard let context else { return }
            context.markGeoTeleported(key)
            if logged {
                SecureLogger.info(
                    "GeoTeleport: mark peer teleported key=\(key.prefix(8))… total=\(context.teleportedGeoCount)",
                    category: .session
                )
            }
        }
    }

    @MainActor
    func subscribeNostrEvent(_ event: NostrEvent, gh: String) {
        guard let context else { return }
        guard (event.kind == NostrProtocol.EventKind.ephemeralEvent.rawValue
            || event.kind == NostrProtocol.EventKind.geohashPresence.rawValue)
        else {
            return
        }
        guard event.isValidSignature() else { return }
        guard shouldProcessGeoSamplingEvent(event.id) else { return }

        let existingCount = context.geoParticipantCount(for: gh)
        context.recordGeoParticipant(pubkeyHex: event.pubkey, geohash: gh)

        guard let content = event.content.trimmedOrNilIfEmpty else { return }
        if context.isNostrBlocked(pubkeyHexLowercased: event.pubkey.lowercased()) { return }
        if let my = try? context.deriveNostrIdentity(forGeohash: gh),
           my.publicKeyHex.lowercased() == event.pubkey.lowercased() {
            return
        }

        // Non-empty content on a sampled event means an actual chat message
        // (presence events are empty) — feed the nearby-conversation hint.
        GeohashChatActivityTracker.shared.recordChatMessage(
            geohash: gh,
            senderName: Self.sampledSenderName(for: event, context: context),
            content: content,
            timestamp: Date(timeIntervalSince1970: TimeInterval(event.created_at))
        )

        guard existingCount == 0 else { return }

        let eventTime = Date(timeIntervalSince1970: TimeInterval(event.created_at))
        if Date().timeIntervalSince(eventTime) > 30 { return }

        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else { return }
        if case .location(let channel) = context.activeChannel, channel.geohash == gh { return }
        #elseif os(macOS)
        guard NSApplication.shared.isActive else { return }
        if case .location(let channel) = context.activeChannel, channel.geohash == gh { return }
        #endif

        cooldownPerGeohash(gh, content: content, event: event)
    }

    /// Attribution for a sampled event: the event's own `n` tag wins (the
    /// active-channel nickname table only covers the selected geohash),
    /// falling back to the table, then "anon", always suffixed with the
    /// pubkey tail like every other geohash display name.
    @MainActor
    static func sampledSenderName(for event: NostrEvent, context: any GeoPresenceContext) -> String {
        let suffix = String(event.pubkey.suffix(4))
        let tagNick = event.tags.first { $0.count >= 2 && $0[0].lowercased() == "n" }?[1]
        let nick = tagNick?.trimmedOrNilIfEmpty
            ?? context.geoNicknames[event.pubkey.lowercased()]?.trimmedOrNilIfEmpty
        return (nick ?? "anon") + "#" + suffix
    }

    @MainActor
    func cooldownPerGeohash(_ gh: String, content: String, event: NostrEvent) {
        guard let context else { return }
        let now = Date()
        let last = context.lastGeoNotificationAt[gh] ?? .distantPast
        if now.timeIntervalSince(last) < TransportConfig.uiGeoNotifyCooldownSeconds { return }

        let preview: String = {
            let maxLen = TransportConfig.uiGeoNotifySnippetMaxLen
            if content.count <= maxLen { return content }
            let idx = content.index(content.startIndex, offsetBy: maxLen)
            return String(content[..<idx]) + "…"
        }()

        Task { @MainActor [weak context] in
            guard let context else { return }
            context.lastGeoNotificationAt[gh] = now
            let senderSuffix = String(event.pubkey.suffix(4))
            let nick = context.geoNicknames[event.pubkey.lowercased()]
            let senderName = (nick?.isEmpty == false ? nick! : "anon") + "#" + senderSuffix

            let rawTs = Date(timeIntervalSince1970: TimeInterval(event.created_at))
            let ts = min(rawTs, Date())
            let mentions = context.parseMentions(from: content)
            let message = BitchatMessage(
                id: event.id,
                sender: senderName,
                content: content,
                timestamp: ts,
                isRelay: false,
                senderPeerID: PeerID(nostr: event.pubkey),
                mentions: mentions.isEmpty ? nil : mentions
            )
            if context.appendGeohashMessageIfAbsent(message, toGeohash: gh) {
                context.notifyGeohashActivity(geohash: gh, bodyPreview: preview)
            }
        }
    }

    /// First-seen check for sampled geohash events with LRU eviction so the
    /// dedup set stays bounded across long sampling sessions.
    func shouldProcessGeoSamplingEvent(_ eventID: String) -> Bool {
        guard !eventID.isEmpty else { return true }
        guard recentGeoSamplingEventIDs.insert(eventID).inserted else {
            return false
        }
        recentGeoSamplingEventIDOrder.append(eventID)

        let cap = TransportConfig.geoSamplingEventLRUCap
        if recentGeoSamplingEventIDOrder.count > cap {
            let removeCount = recentGeoSamplingEventIDOrder.count - cap
            for staleID in recentGeoSamplingEventIDOrder.prefix(removeCount) {
                recentGeoSamplingEventIDs.remove(staleID)
            }
            recentGeoSamplingEventIDOrder.removeFirst(removeCount)
        }
        return true
    }

    func clearGeoSamplingEventDedup() {
        recentGeoSamplingEventIDs.removeAll()
        recentGeoSamplingEventIDOrder.removeAll()
    }
}

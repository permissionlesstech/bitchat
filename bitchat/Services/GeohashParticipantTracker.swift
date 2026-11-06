//
// GeohashParticipantTracker.swift
// bitchat
//
// Tracks participants in geohash-based location channels.
// This is free and unencumbered software released into the public domain.
//

import Foundation

/// Represents a participant in a geohash channel
struct GeoPerson: Identifiable, Equatable, Sendable {
    let id: String        // pubkey hex (lowercased)
    let displayName: String
    let lastSeen: Date

    init(id: String, displayName: String, lastSeen: Date) {
        self.id = id
        self.displayName = displayName
        self.lastSeen = lastSeen
    }
}

/// Protocol for resolving display names and checking block status
@MainActor
protocol GeohashParticipantContext: AnyObject {
    /// Returns display name for a Nostr pubkey (e.g., "alice#a1b2" or "anon#c3d4")
    func displayNameForPubkey(_ pubkeyHex: String) -> String
    /// Returns true if the pubkey is blocked
    func isBlocked(_ pubkeyHexLowercased: String) -> Bool
}

/// Tracks participants across multiple geohash channels
@MainActor
final class GeohashParticipantTracker: ObservableObject {

    /// Presence window as a negative offset from now (defaults to 5 minutes).
    let activityCutoff: TimeInterval

    /// Who counts per geohash, under the rule the globe picker uses too: a
    /// heartbeat or message in the presence window, or a message in the last hour.
    private var activity: GeohashActivityAggregator

    /// Currently visible people for the active geohash
    @Published private(set) var visiblePeople: [GeoPerson] = []

    /// The subset of `visiblePeople` active inside the presence window. Chat
    /// authors stay in the roster for the hour; state that describes people
    /// present now (teleport badges) follows this instead. Refreshed with the
    /// roster and on the refresh timer, so it lapses on time even when the
    /// roster itself doesn't change.
    @Published private(set) var recentlyPresentIDs: Set<String> = []

    /// Bumps whenever the set of ids in `visiblePeople` changes, so derived
    /// per-roster state (the sender color palette) is rebuilt only when
    /// membership changes — not on every activity timestamp update.
    private(set) var visibleMembershipRevision: UInt64 = 0
    private var visibleMemberIDs: Set<String> = []

    /// The currently active geohash (if any)
    private var activeGeohash: String?

    /// Context for display name resolution and block checking
    private weak var context: GeohashParticipantContext?

    /// Timer for periodic refresh
    private var refreshTimer: Timer?

    init(
        activityCutoff: TimeInterval = -GeohashActivityAggregator.presenceWindow,
        chatWindow: TimeInterval = GeohashActivityAggregator.chatWindow
    ) {
        self.activityCutoff = activityCutoff
        activity = GeohashActivityAggregator(presenceWindow: -activityCutoff, chatWindow: chatWindow)
    }

    /// Configure with a context provider
    func configure(context: GeohashParticipantContext) {
        self.context = context
    }

    /// Set the currently active geohash
    func setActiveGeohash(_ geohash: String?) {
        activeGeohash = geohash
        if geohash == nil {
            publishVisiblePeople([])
        } else {
            refresh()
        }
    }

    /// Record activity from a participant in the current active geohash.
    /// Returns `false`, recording nothing, when no geohash is active.
    @discardableResult
    func recordParticipant(pubkeyHex: String, seenAt: Date = Date(), chatEventID: String? = nil) -> Bool {
        guard let gh = activeGeohash else { return false }
        return recordParticipant(pubkeyHex: pubkeyHex, geohash: gh, seenAt: seenAt, chatEventID: chatEventID)
    }

    /// Record activity from a participant in a specific geohash.
    ///
    /// `seenAt` is when the activity happened, clamped to now: arrival time
    /// for live events, the event's own timestamp for history relays replay
    /// on subscribe. A heartbeat counts for the presence window; a chat
    /// message (`chatEventID` set) counts its author for the hour, so replayed
    /// history older than that must not make its authors count as present.
    /// Returns whether the activity counted, i.e. fell inside its window.
    ///
    /// Runs for every inbound geohash event, so the common case — someone
    /// already present sending a heartbeat or message — only moves their
    /// timestamp. The roster is republished only when someone becomes
    /// visible; departures are picked up by the refresh timer.
    @discardableResult
    func recordParticipant(pubkeyHex: String, geohash: String, seenAt: Date = Date(), chatEventID: String? = nil) -> Bool {
        let now = Date()
        let wasActive = activity.isActive(pubkeyHex, in: geohash, now: now)
        guard activity.record(geohash: geohash, pubkey: pubkeyHex, at: seenAt, chatEventID: chatEventID, now: now) else {
            return false
        }
        guard !wasActive else { return true }
        // Someone newly counts as present here: participant counts for
        // this geohash changed (sampled channels included).
        objectWillChange.send()
        if activeGeohash == geohash {
            refresh()
        }
        return true
    }

    /// A participant's display name may have changed (a nickname was learned
    /// or edited). Republishes the roster if they're currently visible.
    func noteDisplayNameChanged(pubkeyHex: String) {
        guard visibleMemberIDs.contains(pubkeyHex.lowercased()) else { return }
        refresh()
    }

    /// Remove a participant from all geohashes (used when blocking)
    func removeParticipant(pubkeyHex: String) {
        activity.remove(pubkey: pubkeyHex)
        refresh()
    }

    /// Participant count for a specific geohash. Blocked people are left out,
    /// as they are from the roster and the globe.
    func participantCount(for geohash: String) -> Int {
        activity.count(in: geohash, excluding: isBlocked)
    }

    /// Drops entries that aged out of the activity window, in every geohash
    /// (sampled ones included) so a long session doesn't keep every pubkey
    /// it ever saw.
    func pruneExpired(now: Date = Date()) {
        activity.prune(now: now)
    }

    /// Get the visible people list for the active geohash (read-only query)
    func getVisiblePeople() -> [GeoPerson] {
        guard let gh = activeGeohash, let context = context else { return [] }
        return activity.activePeople(in: gh, excluding: context.isBlocked)
            .map { (pub, seen) in
                GeoPerson(id: pub, displayName: context.displayNameForPubkey(pub), lastSeen: seen)
            }
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Refresh the visible people list. Publishes only when what the roster
    /// shows changed — who is present or how they're named — so subscribers
    /// (the people sheet, the bootstrapper's prune) don't rebuild on
    /// activity that only moved timestamps.
    func refresh() {
        let people = getVisiblePeople()
        updateRecentlyPresent(from: people)
        guard Self.rosterKey(people) != Self.rosterKey(visiblePeople) else { return }
        publishVisiblePeople(people)
    }

    private static func rosterKey(_ people: [GeoPerson]) -> [String: String] {
        Dictionary(people.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }

    private func updateRecentlyPresent(from people: [GeoPerson]) {
        let cutoff = Date().addingTimeInterval(activityCutoff)
        let recent = Set(people.lazy.filter { $0.lastSeen >= cutoff }.map(\.id))
        if recent != recentlyPresentIDs { recentlyPresentIDs = recent }
    }

    private func publishVisiblePeople(_ people: [GeoPerson]) {
        updateRecentlyPresent(from: people)
        let ids = Set(people.map(\.id))
        if ids != visibleMemberIDs {
            visibleMemberIDs = ids
            visibleMembershipRevision &+= 1
        }
        visiblePeople = people
    }

    /// Start the periodic refresh timer: expires people who went quiet.
    private func isBlocked(_ pubkeyHexLowercased: String) -> Bool {
        context?.isBlocked(pubkeyHexLowercased) ?? false
    }

    func startRefreshTimer(interval: TimeInterval = 30.0) {
        stopRefreshTimer()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pruneExpired()
                self?.refresh()
            }
        }
    }

    /// Stop the periodic refresh timer
    func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Clear all participant data
    func clear() {
        activity.removeAll()
        publishVisiblePeople([])
    }

    /// Clear participant data for a specific geohash
    func clear(geohash: String) {
        activity.removeChannel(geohash)
        if activeGeohash == geohash {
            publishVisiblePeople([])
        }
    }
}

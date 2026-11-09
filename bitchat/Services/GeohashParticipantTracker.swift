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

    /// Activity cutoff duration (defaults to 5 minutes)
    let activityCutoff: TimeInterval

    /// Per-geohash participant map: [geohash: [pubkeyHex: lastSeen]]
    private var participants: [String: [String: Date]] = [:]

    /// Currently visible people for the active geohash
    @Published private(set) var visiblePeople: [GeoPerson] = []

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

    init(activityCutoff: TimeInterval = -300) { // default 5 minutes
        self.activityCutoff = activityCutoff
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
    func recordParticipant(pubkeyHex: String, seenAt: Date = Date()) -> Bool {
        guard let gh = activeGeohash else { return false }
        return recordParticipant(pubkeyHex: pubkeyHex, geohash: gh, seenAt: seenAt)
    }

    /// Record activity from a participant in a specific geohash.
    ///
    /// `seenAt` is when the activity happened, clamped to now: arrival time
    /// for live events, the event's own timestamp for history relays replay
    /// on subscribe. Replayed history older than the activity window must
    /// not make its authors count as present. Returns whether the activity
    /// counted, i.e. fell inside the window.
    ///
    /// Runs for every inbound geohash event, so the common case — someone
    /// already present sending a heartbeat or message — only moves their
    /// timestamp. The roster is republished only when someone becomes
    /// visible; departures are picked up by the refresh timer.
    @discardableResult
    func recordParticipant(pubkeyHex: String, geohash: String, seenAt: Date = Date()) -> Bool {
        let now = Date()
        let cutoff = now.addingTimeInterval(activityCutoff)
        let stamp = min(seenAt, now)
        guard stamp >= cutoff else { return false }

        let key = pubkeyHex.lowercased()
        let previous = participants[geohash]?[key]
        if let previous, previous >= stamp { return true }
        participants[geohash, default: [:]][key] = stamp

        let wasActive = previous.map { $0 >= cutoff } ?? false
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
        let key = pubkeyHex.lowercased()
        for geohash in participants.keys {
            participants[geohash]?.removeValue(forKey: key)
        }
        refresh()
    }

    /// Get participant count for a specific geohash
    func participantCount(for geohash: String) -> Int {
        let cutoff = Date().addingTimeInterval(activityCutoff)
        let map = participants[geohash] ?? [:]
        return map.values.reduce(0) { $1 >= cutoff ? $0 + 1 : $0 }
    }

    /// Drops entries that aged out of the activity window, in every geohash
    /// (sampled ones included) so a long session doesn't keep every pubkey
    /// it ever saw.
    func pruneExpired(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(activityCutoff)
        for (geohash, map) in participants {
            let active = map.filter { $0.value >= cutoff }
            if active.isEmpty {
                participants.removeValue(forKey: geohash)
            } else if active.count != map.count {
                participants[geohash] = active
            }
        }
    }

    /// Get the visible people list for the active geohash (read-only query)
    func getVisiblePeople() -> [GeoPerson] {
        guard let gh = activeGeohash, let context = context else { return [] }
        let cutoff = Date().addingTimeInterval(activityCutoff)
        let map = (participants[gh] ?? [:])
            .filter { $0.value >= cutoff }
            .filter { !context.isBlocked($0.key) }

        return map
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
        guard Self.rosterKey(people) != Self.rosterKey(visiblePeople) else { return }
        publishVisiblePeople(people)
    }

    private static func rosterKey(_ people: [GeoPerson]) -> [String: String] {
        Dictionary(people.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }

    private func publishVisiblePeople(_ people: [GeoPerson]) {
        let ids = Set(people.map(\.id))
        if ids != visibleMemberIDs {
            visibleMemberIDs = ids
            visibleMembershipRevision &+= 1
        }
        visiblePeople = people
    }

    /// Start the periodic refresh timer: expires people who went quiet.
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
        participants.removeAll()
        publishVisiblePeople([])
    }

    /// Clear participant data for a specific geohash
    func clear(geohash: String) {
        participants.removeValue(forKey: geohash)
        if activeGeohash == geohash {
            publishVisiblePeople([])
        }
    }
}

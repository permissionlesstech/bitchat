//
// GeohashParticipantTracker.swift
// bitchat
//
// Tracks participants in geohash-based location channels.
// This is free and unencumbered software released into the public domain.
//

import Foundation

/// Represents a participant in a geohash channel
public struct GeoPerson: Identifiable, Equatable, Sendable {
    public let id: String        // pubkey hex (lowercased)
    public let displayName: String
    public let lastSeen: Date

    public init(id: String, displayName: String, lastSeen: Date) {
        self.id = id
        self.displayName = displayName
        self.lastSeen = lastSeen
    }
}

/// Protocol for resolving display names and checking block status
@MainActor
public protocol GeohashParticipantContext: AnyObject {
    /// Returns display name for a Nostr pubkey (e.g., "alice#a1b2" or "anon#c3d4")
    func displayNameForPubkey(_ pubkeyHex: String) -> String
    /// Returns true if the pubkey is blocked
    func isBlocked(_ pubkeyHexLowercased: String) -> Bool
}

/// Tracks participants across multiple geohash channels
@MainActor
public final class GeohashParticipantTracker: ObservableObject {

    /// Activity cutoff duration (defaults to 5 minutes)
    public let activityCutoff: TimeInterval

    /// Per-geohash participant map: [geohash: [pubkeyHex: lastSeen]]
    private var participants: [String: [String: Date]] = [:]

    /// Currently visible people for the active geohash
    @Published public private(set) var visiblePeople: [GeoPerson] = []

    /// The currently active geohash (if any)
    private var activeGeohash: String?

    /// Context for display name resolution and block checking
    private weak var context: GeohashParticipantContext?

    /// Timer for periodic refresh
    private var refreshTimer: Timer?

    public init(activityCutoff: TimeInterval = -300) { // default 5 minutes
        self.activityCutoff = activityCutoff
    }

    /// Configure with a context provider
    public func configure(context: GeohashParticipantContext) {
        self.context = context
    }

    /// Set the currently active geohash
    public func setActiveGeohash(_ geohash: String?) {
        activeGeohash = geohash
        if geohash == nil {
            visiblePeople = []
        } else {
            refresh()
        }
    }

    /// Record activity from a participant in the current active geohash
    public func recordParticipant(pubkeyHex: String) {
        guard let gh = activeGeohash else { return }
        recordParticipant(pubkeyHex: pubkeyHex, geohash: gh)
    }

    /// Record activity from a participant in a specific geohash
    public func recordParticipant(pubkeyHex: String, geohash: String) {
        let key = pubkeyHex.lowercased()
        var map = participants[geohash] ?? [:]
        map[key] = Date()
        participants[geohash] = map
        
        // Always notify observers that state has changed so counts in UI update
        objectWillChange.send()

        // Only refresh visible list if this geohash is currently active
        if activeGeohash == geohash {
            refresh()
        }
    }

    /// Remove a participant from all geohashes (used when blocking)
    public func removeParticipant(pubkeyHex: String) {
        let key = pubkeyHex.lowercased()
        for (gh, var map) in participants {
            map.removeValue(forKey: key)
            participants[gh] = map
        }
        refresh()
    }

    /// Get participant count for a specific geohash
    public func participantCount(for geohash: String) -> Int {
        let cutoff = Date().addingTimeInterval(activityCutoff)
        let map = participants[geohash] ?? [:]
        return map.values.filter { $0 >= cutoff }.count
    }

    /// Get the visible people list for the active geohash (read-only query)
    public func getVisiblePeople() -> [GeoPerson] {
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

    /// Refresh the visible people list
    public func refresh() {
        visiblePeople = getVisiblePeople()
    }

    /// Start the periodic refresh timer
    public func startRefreshTimer(interval: TimeInterval = 30.0) {
        stopRefreshTimer()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    /// Stop the periodic refresh timer
    public func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Clear all participant data
    public func clear() {
        participants.removeAll()
        visiblePeople = []
    }

    /// Clear participant data for a specific geohash
    public func clear(geohash: String) {
        participants.removeValue(forKey: geohash)
        if activeGeohash == geohash {
            visiblePeople = []
        }
    }
}

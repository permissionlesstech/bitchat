//
// GeohashParticipantsService.swift
// bitchat
//
// Manages tracking of participants in geohash-based location channels
// This is free and unencumbered software released into the public domain.
//

import BitLogger
import Foundation
import Combine

/// Service for tracking and managing participants in geohash channels
/// Handles automatic expiration, refresh timers, and participant list management
final class GeohashParticipantsService: ObservableObject {

    // MARK: - Published Properties

    @Published private(set) var geohashPeople: [GeoPerson] = []

    // MARK: - Private State

    private var geoParticipants: [String: [String: Date]] = [:] // geohash -> [pubkeyHex -> lastSeen]
    private var geoParticipantsTimer: Timer? = nil
    private var currentGeohash: String? = nil

    // MARK: - Dependencies

    private let identityManager: SecureIdentityStateManagerProtocol
    private let displayNameProvider: (String) -> String

    // MARK: - Configuration

    private let activityWindowSeconds: TimeInterval
    private let refreshIntervalSeconds: TimeInterval

    // MARK: - Initialization

    init(
        identityManager: SecureIdentityStateManagerProtocol,
        displayNameProvider: @escaping (String) -> String,
        activityWindowSeconds: TimeInterval = TransportConfig.uiRecentCutoffFiveMinutesSeconds,
        refreshIntervalSeconds: TimeInterval = 30.0
    ) {
        self.identityManager = identityManager
        self.displayNameProvider = displayNameProvider
        self.activityWindowSeconds = activityWindowSeconds
        self.refreshIntervalSeconds = refreshIntervalSeconds
    }

    deinit {
        // Note: deinit cannot call @MainActor methods
        // Timer cleanup will happen automatically when service is deallocated
        SecureLogger.debug("GeohashParticipantsService deinitialized", category: .session)
    }

    // MARK: - Public API

    /// Set the current geohash being tracked (starts/stops timer accordingly)
    func setCurrentGeohash(_ geohash: String?) {
        if currentGeohash != geohash {
            currentGeohash = geohash
            refreshPeopleList()

            if geohash != nil {
                startTimer()
            } else {
                stopTimer()
            }
        }
    }

    /// Record a participant activity in the current geohash
    func recordParticipant(pubkeyHex: String) {
        guard let gh = currentGeohash else { return }
        recordParticipant(pubkeyHex: pubkeyHex, geohash: gh)
    }

    /// Record a participant activity in a specific geohash
    func recordParticipant(pubkeyHex: String, geohash: String) {
        let key = pubkeyHex.lowercased()
        var map = geoParticipants[geohash] ?? [:]
        map[key] = Date()
        geoParticipants[geohash] = map

        // Only refresh list if this geohash is currently selected
        if currentGeohash == geohash {
            refreshPeopleList()
        }
    }

    /// Get visible people for the current geohash (without mutating state)
    func visiblePeople() -> [GeoPerson] {
        guard let gh = currentGeohash else { return [] }
        return visiblePeople(for: gh)
    }

    /// Get visible people for a specific geohash
    func visiblePeople(for geohash: String) -> [GeoPerson] {
        let cutoff = Date().addingTimeInterval(-activityWindowSeconds)
        let map = (geoParticipants[geohash] ?? [:])
            .filter { $0.value >= cutoff }
            .filter { !identityManager.isNostrBlocked(pubkeyHexLowercased: $0.key) }
        let people = map
            .map { (pub, seen) in
                GeoPerson(id: pub, displayName: displayNameProvider(pub), lastSeen: seen)
            }
            .sorted { $0.lastSeen > $1.lastSeen }
        return people
    }

    /// Get participant count for a specific geohash (using activity window)
    func participantCount(for geohash: String) -> Int {
        let cutoff = Date().addingTimeInterval(-activityWindowSeconds)
        let map = geoParticipants[geohash] ?? [:]
        return map.values.filter { $0 >= cutoff }.count
    }

    /// Remove a participant from all geohashes (e.g., when blocked)
    func removeParticipant(pubkeyHexLowercased: String) {
        let hex = pubkeyHexLowercased.lowercased()
        for (gh, var map) in geoParticipants {
            map.removeValue(forKey: hex)
            geoParticipants[gh] = map
        }
        refreshPeopleList()
    }

    /// Clear all participant data (for testing or reset)
    func reset() {
        stopTimer()
        geoParticipants.removeAll()
        geohashPeople.removeAll()
        currentGeohash = nil
    }

    // MARK: - Private Helpers

    private func refreshPeopleList() {
        guard let gh = currentGeohash else {
            geohashPeople = []
            return
        }

        let cutoff = Date().addingTimeInterval(-activityWindowSeconds)
        var map = geoParticipants[gh] ?? [:]

        // Prune expired entries
        map = map.filter { $0.value >= cutoff }

        // Remove blocked Nostr pubkeys
        map = map.filter { !identityManager.isNostrBlocked(pubkeyHexLowercased: $0.key) }

        // Update cleaned map
        geoParticipants[gh] = map

        // Build display list
        let people = map
            .map { (pub, seen) in
                GeoPerson(id: pub, displayName: displayNameProvider(pub), lastSeen: seen)
            }
            .sorted { $0.lastSeen > $1.lastSeen }

        geohashPeople = people
    }

    private func startTimer() {
        stopTimer()
        geoParticipantsTimer = Timer.scheduledTimer(withTimeInterval: refreshIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPeopleList()
            }
        }
    }

    private func stopTimer() {
        geoParticipantsTimer?.invalidate()
        geoParticipantsTimer = nil
    }
}

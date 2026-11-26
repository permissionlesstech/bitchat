//
// MeshSightingsTracker.swift
// bitchat
//
// Privacy-preserving daily tally of mesh peers that came within radio range,
// so an empty timeline can say "3 devices passed within range today" instead
// of feeling dead. Stores only a per-day salted hash per peer plus a count —
// no identities, no history beyond today.
// This is free and unencumbered software released into the public domain.
//

import BitFoundation
import CryptoKit
import Foundation

@MainActor
final class MeshSightingsTracker: ObservableObject {
    static let shared = MeshSightingsTracker()

    private enum Keys {
        static let dayKey = "meshSightings.dayKey"
        static let salt = "meshSightings.salt"
        static let hashes = "meshSightings.hashes"
        static let lastSeenAt = "meshSightings.lastSeenAt"
    }

    /// Distinct devices seen within range today (rotating peer IDs may count
    /// a long-lived neighbor more than once across rotations; that is fine
    /// for an ambient stat).
    @Published private(set) var todayCount: Int = 0
    @Published private(set) var lastSightingAt: Date?

    private let defaults: UserDefaults
    private let now: () -> Date
    private var seenHashes: Set<String> = []
    private var seenPeerIDsToday: Set<String> = []
    private var currentDayKey: String = ""
    private var currentSalt: Data = Data()

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
        restore()
    }

    func recordSighting(peerID: PeerID) {
        recordSightings([peerID])
    }

    func recordSightings(_ peerIDs: [PeerID]) {
        guard !peerIDs.isEmpty else { return }
        let seenAt = now()
        rollOverIfNeeded(at: seenAt)

        var insertedAnyHash = false
        for peerID in peerIDs {
            let rawID = peerID.id
            guard seenPeerIDsToday.insert(rawID).inserted else { continue }
            let hash = saltedHash(rawID)
            if seenHashes.insert(hash).inserted {
                insertedAnyHash = true
            }
        }

        if lastSightingAt != seenAt {
            lastSightingAt = seenAt
            defaults.set(seenAt, forKey: Keys.lastSeenAt)
        }
        if insertedAnyHash {
            todayCount = seenHashes.count
            defaults.set(Array(seenHashes), forKey: Keys.hashes)
        }
    }

    /// Re-evaluates the day boundary for the UI. `recordSighting` handles
    /// rollover when peers are seen, but an idle app open across midnight
    /// would otherwise keep showing yesterday's tally until the next sighting;
    /// the empty-state view calls this on its periodic refresh tick.
    func refreshForDisplay() {
        rollOverIfNeeded(at: now())
    }

    func clear() {
        seenHashes.removeAll()
        seenPeerIDsToday.removeAll()
        currentDayKey = ""
        currentSalt = Data()
        todayCount = 0
        lastSightingAt = nil
        defaults.removeObject(forKey: Keys.dayKey)
        defaults.removeObject(forKey: Keys.salt)
        defaults.removeObject(forKey: Keys.hashes)
        defaults.removeObject(forKey: Keys.lastSeenAt)
    }

    private func restore() {
        rollOverIfNeeded(at: now())
        seenHashes = Set(defaults.stringArray(forKey: Keys.hashes) ?? [])
        todayCount = seenHashes.count
        lastSightingAt = defaults.object(forKey: Keys.lastSeenAt) as? Date
    }

    /// Resets the tally when the local calendar day changes; the salt rotates
    /// with it so hashes from different days can never be correlated.
    private func rollOverIfNeeded(at date: Date) {
        let today = Self.dayKey(for: date)
        if currentDayKey == today && !currentSalt.isEmpty {
            return
        }
        if defaults.string(forKey: Keys.dayKey) == today {
            currentDayKey = today
            if let persistedSalt = defaults.data(forKey: Keys.salt), !persistedSalt.isEmpty {
                currentSalt = persistedSalt
            } else {
                let fresh = Self.randomSalt()
                currentSalt = fresh
                defaults.set(fresh, forKey: Keys.salt)
            }
            return
        }
        let freshSalt = Self.randomSalt()
        currentDayKey = today
        currentSalt = freshSalt
        defaults.set(today, forKey: Keys.dayKey)
        defaults.set(freshSalt, forKey: Keys.salt)
        defaults.removeObject(forKey: Keys.hashes)
        defaults.removeObject(forKey: Keys.lastSeenAt)
        seenHashes.removeAll()
        seenPeerIDsToday.removeAll()
        todayCount = 0
        lastSightingAt = nil
    }

    private func saltedHash(_ value: String) -> String {
        if currentSalt.isEmpty {
            let fresh = Self.randomSalt()
            currentSalt = fresh
            defaults.set(fresh, forKey: Keys.salt)
        }
        var digest = SHA256()
        digest.update(data: currentSalt)
        digest.update(data: Data(value.utf8))
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func dayKey(for date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    private static func randomSalt() -> Data {
        Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
    }
}

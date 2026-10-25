//
// MeshSightingsTracker.swift
// bitchat
//
// Privacy-preserving daily tally of mesh peers that came within radio range,
// so an empty timeline can say "3 devices passed within range today" instead
// of feeling dead. Persists only a per-day salted hash per peer plus a count
// — no identities, no history beyond today. In memory it keeps the raw IDs
// of the peers present in the latest batch (as the transport's peer registry
// does), so a peer that stays in range is hashed once, not on every update.
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
        /// Written by older builds on every sighting. Nothing reads it any
        /// more; it is only removed (at launch, rollover and wipe).
        static let lastSeenAt = "meshSightings.lastSeenAt"
    }

    /// Distinct devices seen within range today (rotating peer IDs may count
    /// a long-lived neighbor more than once across rotations; that is fine
    /// for an ambient stat).
    @Published private(set) var todayCount: Int = 0

    private let defaults: UserDefaults
    private let now: () -> Date
    private var seenHashes: Set<String> = []
    /// Peers of the latest batch, all already hashed into `seenHashes`.
    /// Bounded to who is present now: a peer that leaves is forgotten here
    /// and, on return, hashed once more (which dedups without a write).
    private var countedPeerIDs: Set<PeerID> = []
    /// Today's salt, cached so the steady state reads no defaults. Valid
    /// whenever `currentDay` is set.
    private var salt = Data()
    /// The local day `salt` and `seenHashes` belong to; nil until the first
    /// rollover check and after `clear()`.
    private var currentDay: DateInterval?

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
        restore()
    }

    /// Records the mesh peers present now (the full set, not a delta).
    /// Only peers that were absent from the previous batch are hashed, and
    /// the hash list is persisted only when one of them is new today, so a
    /// steady mesh costs set lookups: no hashing, no defaults writes, no
    /// publishes.
    func recordSightings(of peerIDs: some Sequence<PeerID>) {
        rollOverIfNeeded()
        let present = Set(peerIDs)
        var insertedHash = false
        for peerID in present where !countedPeerIDs.contains(peerID) {
            if seenHashes.insert(saltedHash(peerID.id)).inserted {
                insertedHash = true
            }
        }
        countedPeerIDs = present
        guard insertedHash else { return }
        todayCount = seenHashes.count
        defaults.set(Array(seenHashes), forKey: Keys.hashes)
    }

    /// Re-evaluates the day boundary for the UI. `recordSightings` handles
    /// rollover when peers are seen, but an idle app open across midnight
    /// would otherwise keep showing yesterday's tally until the next sighting;
    /// the empty-state view calls this on its periodic refresh tick.
    func refreshForDisplay() {
        rollOverIfNeeded()
    }

    func clear() {
        seenHashes.removeAll()
        countedPeerIDs.removeAll()
        salt = Data()
        currentDay = nil
        todayCount = 0
        defaults.removeObject(forKey: Keys.dayKey)
        defaults.removeObject(forKey: Keys.salt)
        defaults.removeObject(forKey: Keys.hashes)
        defaults.removeObject(forKey: Keys.lastSeenAt)
    }

    private func restore() {
        rollOverIfNeeded()
        seenHashes = Set(defaults.stringArray(forKey: Keys.hashes) ?? [])
        todayCount = seenHashes.count
        defaults.removeObject(forKey: Keys.lastSeenAt)
    }

    /// Resets the tally when the local calendar day changes; the salt rotates
    /// with it so hashes from different days can never be correlated. Within
    /// the cached day this is two date comparisons.
    private func rollOverIfNeeded() {
        let current = now()
        // Half-open: the exact midnight instant already belongs to the new
        // day. A clock moved backwards also lands outside the interval.
        if let day = currentDay, day.start <= current, current < day.end {
            return
        }
        currentDay = Self.dayCalendar.dateInterval(of: .day, for: current)
        let today = Self.dayKey(for: current)
        if defaults.string(forKey: Keys.dayKey) == today {
            // Today's tally is already persisted (the first check after a
            // launch): keep its salt so its hashes still match.
            if let persisted = defaults.data(forKey: Keys.salt) {
                salt = persisted
            } else {
                salt = Self.randomSalt()
                defaults.set(salt, forKey: Keys.salt)
            }
            return
        }
        defaults.set(today, forKey: Keys.dayKey)
        salt = Self.randomSalt()
        defaults.set(salt, forKey: Keys.salt)
        defaults.removeObject(forKey: Keys.hashes)
        defaults.removeObject(forKey: Keys.lastSeenAt)
        seenHashes.removeAll()
        countedPeerIDs.removeAll()
        todayCount = 0
    }

    /// Lowercase hex of SHA-256(salt ‖ value): byte-identical to the
    /// `%02x`-per-byte form earlier builds persisted, so hashes stored
    /// before an upgrade keep deduplicating.
    private func saltedHash(_ value: String) -> String {
        #if DEBUG
        _test_hashCount += 1
        #endif
        var digest = SHA256()
        digest.update(data: salt)
        digest.update(data: Data(value.utf8))
        return Data(digest.finalize()).hexEncodedString()
    }

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// The day-key formatter's calendar in its time zone, so cached day
    /// boundaries (DST-length days included) match the keys it formats.
    private static let dayCalendar: Calendar = {
        var calendar = dayKeyFormatter.calendar ?? Calendar.current
        calendar.timeZone = dayKeyFormatter.timeZone ?? TimeZone.current
        return calendar
    }()

    private static func dayKey(for date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    private static func randomSalt() -> Data {
        Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
    }

    #if DEBUG
    /// Raw peer IDs held in memory; tests pin the present-peers-only bound.
    var _test_heldPeerIDCount: Int { countedPeerIDs.count }
    /// Salted hashes computed so far; tests pin that peers still present
    /// from the previous batch are not hashed again.
    private(set) var _test_hashCount = 0
    #endif
}

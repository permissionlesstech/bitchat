//
// MeshSightingsTrackerTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Combine
import CryptoKit
import Foundation
import Testing
@testable import bitchat
import BitFoundation

/// Counts value writes per key, so tests can prove a batch wrote nothing.
/// In memory, so a test leaves no preferences plist behind.
private final class CountingDefaults: InMemoryUserDefaults {
    private(set) var setCounts: [String: Int] = [:]

    var totalSetCount: Int { setCounts.values.reduce(0, +) }

    override func set(_ value: Any?, forKey defaultName: String) {
        // Storing nil is a removal; only count writes.
        if value != nil {
            setCounts[defaultName, default: 0] += 1
        }
        super.set(value, forKey: defaultName)
    }

    func resetCounts() {
        setCounts.removeAll()
    }
}

@MainActor
struct MeshSightingsTrackerTests {

    private func makeDefaults() -> CountingDefaults {
        CountingDefaults()
    }

    private let noon = Date(timeIntervalSince1970: 1_700_000_000)

    /// The local day containing `noon`, in the calendar and time zone the
    /// tracker's day key uses (the process's current ones), so the midnight
    /// cases hold in any time zone the suite runs in.
    private var noonDay: DateInterval {
        Calendar.current.dateInterval(of: .day, for: noon)!
    }

    private func peers(_ count: Int) -> [PeerID] {
        (0..<count).map { PeerID(str: String(format: "%016llx", UInt64(0xA000_0000_0000_0000) + UInt64($0))) }
    }

    @Test
    func countsDistinctPeersOnce() {
        let defaults = makeDefaults()
        let tracker = MeshSightingsTracker(defaults: defaults, now: { self.noon })

        tracker.recordSightings(of: [PeerID(str: "aaaa111122223333"), PeerID(str: "aaaa111122223333")])
        tracker.recordSightings(of: [PeerID(str: "aaaa111122223333"), PeerID(str: "bbbb444455556666")])

        #expect(tracker.todayCount == 2)
    }

    @Test
    func persistsAcrossInstances() {
        let defaults = makeDefaults()
        let first = MeshSightingsTracker(defaults: defaults, now: { self.noon })
        first.recordSightings(of: [PeerID(str: "aaaa111122223333")])

        let second = MeshSightingsTracker(defaults: defaults, now: { self.noon.addingTimeInterval(60) })
        #expect(second.todayCount == 1)

        // Same peer again does not double count after a relaunch.
        second.recordSightings(of: [PeerID(str: "aaaa111122223333")])
        #expect(second.todayCount == 1)
    }

    @Test
    func rollsOverOnNewDay() {
        let defaults = makeDefaults()
        var currentNow = noon
        let tracker = MeshSightingsTracker(defaults: defaults, now: { currentNow })
        tracker.recordSightings(of: [PeerID(str: "aaaa111122223333")])
        #expect(tracker.todayCount == 1)

        currentNow = noon.addingTimeInterval(2 * 24 * 60 * 60)
        tracker.recordSightings(of: [PeerID(str: "bbbb444455556666")])

        #expect(tracker.todayCount == 1)
    }

    @Test
    func clearResetsEverything() {
        let defaults = makeDefaults()
        let tracker = MeshSightingsTracker(defaults: defaults, now: { self.noon })
        tracker.recordSightings(of: [PeerID(str: "aaaa111122223333")])

        tracker.clear()

        #expect(tracker.todayCount == 0)
        #expect(defaults.object(forKey: "meshSightings.hashes") == nil)
        #expect(defaults.object(forKey: "meshSightings.salt") == nil)

        let reloaded = MeshSightingsTracker(defaults: defaults, now: { self.noon })
        #expect(reloaded.todayCount == 0)
    }

    /// The steady state of a busy mesh: every update lists peers already
    /// counted. It used to hash each one and write UserDefaults per peer.
    @Test
    func repeatedBatchesWriteNothingAfterTheFirst() {
        let defaults = makeDefaults()
        let tracker = MeshSightingsTracker(defaults: defaults, now: { self.noon })
        let present = peers(50)
        tracker.recordSightings(of: present)
        #expect(tracker.todayCount == 50)

        defaults.resetCounts()
        let hashesBefore = tracker._test_hashCount
        var publishes = 0
        let subscription = tracker.objectWillChange.sink { publishes += 1 }
        defer { subscription.cancel() }

        for _ in 0..<5 {
            tracker.recordSightings(of: present)
        }

        #expect(defaults.totalSetCount == 0)
        #expect(publishes == 0)
        // Peers still present from the previous batch cost a set lookup,
        // not a hash.
        #expect(tracker._test_hashCount == hashesBefore)
        #expect(tracker.todayCount == 50)
    }

    /// Only peers present in the latest batch are held in memory, so a peer
    /// that leaves and returns is hashed again — and dedups against today's
    /// persisted hashes without a write.
    @Test
    func peerLeavingAndReturningDedupsWithoutWriting() {
        let defaults = makeDefaults()
        let tracker = MeshSightingsTracker(defaults: defaults, now: { self.noon })
        let peerA = PeerID(str: "aaaa111122223333")
        let peerB = PeerID(str: "bbbb444455556666")
        tracker.recordSightings(of: [peerA, peerB])

        defaults.resetCounts()
        let hashesBefore = tracker._test_hashCount
        tracker.recordSightings(of: [peerB])
        #expect(tracker._test_heldPeerIDCount == 1)
        tracker.recordSightings(of: [])
        #expect(tracker._test_heldPeerIDCount == 0)
        tracker.recordSightings(of: [peerA, peerB])

        #expect(defaults.totalSetCount == 0)
        #expect(tracker.todayCount == 2)
        #expect(tracker._test_heldPeerIDCount == 2)
        // Only the two returns were hashed; peerB staying put was not.
        #expect(tracker._test_hashCount - hashesBefore == 2)
    }

    /// Hashes persisted before the upgrade were `%02x` per digest byte; the
    /// table encoder must produce the same string or a relaunch would count
    /// every peer twice.
    @Test
    func persistedHashMatchesThePrintfHexFormat() {
        let defaults = makeDefaults()
        // Establish today's day key, then pin a known salt for it.
        _ = MeshSightingsTracker(defaults: defaults, now: { self.noon })
        let salt = Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ 3) })
        defaults.set(salt, forKey: "meshSightings.salt")
        let peer = PeerID(str: "aaaa111122223333")

        let tracker = MeshSightingsTracker(defaults: defaults, now: { self.noon })
        tracker.recordSightings(of: [peer])

        var digest = SHA256()
        digest.update(data: salt)
        digest.update(data: Data(peer.id.utf8))
        let expected = digest.finalize().map { String(format: "%02x", $0) }.joined()
        #expect(defaults.stringArray(forKey: "meshSightings.hashes") == [expected])
    }

    /// A peer present across midnight counts again on the new day, under a
    /// fresh salt: the in-memory set is part of the day's state.
    @Test
    func peersStillPresentAfterMidnightCountAgain() {
        let defaults = makeDefaults()
        var currentNow = noonDay.end.addingTimeInterval(-60)
        let tracker = MeshSightingsTracker(defaults: defaults, now: { currentNow })
        let peer = PeerID(str: "aaaa111122223333")
        tracker.recordSightings(of: [peer])
        let saltBefore = defaults.data(forKey: "meshSightings.salt")
        let hashesBefore = defaults.stringArray(forKey: "meshSightings.hashes")
        #expect(tracker.todayCount == 1)

        currentNow = noonDay.end.addingTimeInterval(60)
        tracker.recordSightings(of: [peer])

        #expect(tracker.todayCount == 1)
        #expect(defaults.data(forKey: "meshSightings.salt") != saltBefore)
        #expect(defaults.stringArray(forKey: "meshSightings.hashes") != hashesBefore)
        #expect(defaults.stringArray(forKey: "meshSightings.hashes")?.count == 1)
    }

    /// The cached day is half-open: the midnight instant itself already
    /// starts the new day, as the per-call day-key compare it replaces did.
    @Test
    func exactMidnightStartsTheNewDay() {
        let defaults = makeDefaults()
        var currentNow = noonDay.end.addingTimeInterval(-1)
        let tracker = MeshSightingsTracker(defaults: defaults, now: { currentNow })
        tracker.recordSightings(of: [PeerID(str: "aaaa111122223333")])
        let dayKeyBefore = defaults.string(forKey: "meshSightings.dayKey")
        let saltBefore = defaults.data(forKey: "meshSightings.salt")

        currentNow = noonDay.end
        tracker.refreshForDisplay()

        #expect(defaults.string(forKey: "meshSightings.dayKey") != dayKeyBefore)
        #expect(defaults.data(forKey: "meshSightings.salt") != saltBefore)
        #expect(tracker.todayCount == 0)
    }

    @Test
    func clearForgetsPeersCountedInMemory() {
        let defaults = makeDefaults()
        let tracker = MeshSightingsTracker(defaults: defaults, now: { self.noon })
        let peer = PeerID(str: "aaaa111122223333")
        tracker.recordSightings(of: [peer])

        // A panic wipe must drop the raw IDs now, not at the next batch.
        tracker.clear()
        #expect(tracker._test_heldPeerIDCount == 0)
        defaults.resetCounts()
        tracker.recordSightings(of: [peer])

        #expect(tracker.todayCount == 1)
        #expect(defaults.setCounts["meshSightings.hashes"] == 1)
        #expect(defaults.data(forKey: "meshSightings.salt") != nil)
    }

    @Test
    func relaunchDedupsWithoutWriting() {
        let defaults = makeDefaults()
        let present = peers(20)
        MeshSightingsTracker(defaults: defaults, now: { self.noon }).recordSightings(of: present)

        defaults.resetCounts()
        let relaunched = MeshSightingsTracker(defaults: defaults, now: { self.noon.addingTimeInterval(60) })
        relaunched.recordSightings(of: present)

        #expect(relaunched.todayCount == 20)
        #expect(defaults.totalSetCount == 0)
    }

    /// Older builds wrote a last-sighting date on every sighting; nothing
    /// reads it now, so it goes at launch instead of lingering until midnight.
    @Test
    func launchRemovesTheLegacyLastSeenDate() {
        let defaults = makeDefaults()
        defaults.set(noon, forKey: "meshSightings.lastSeenAt")

        _ = MeshSightingsTracker(defaults: defaults, now: { self.noon })

        #expect(defaults.object(forKey: "meshSightings.lastSeenAt") == nil)
    }
}

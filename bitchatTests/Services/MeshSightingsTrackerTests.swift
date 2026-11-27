//
// MeshSightingsTrackerTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import bitchat
import BitFoundation

@MainActor
struct MeshSightingsTrackerTests {

    private func makeDefaults() -> UserDefaults {
        let suite = "MeshSightingsTrackerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private let noon = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func countsDistinctPeersOnce() {
        let defaults = makeDefaults()
        let tracker = MeshSightingsTracker(defaults: defaults, now: { self.noon })

        tracker.recordSightings([PeerID(str: "aaaa111122223333")])
        tracker.recordSightings([PeerID(str: "aaaa111122223333")])
        tracker.recordSightings([PeerID(str: "bbbb444455556666")])

        #expect(tracker.todayCount == 2)
    }

    @Test
    func persistsAcrossInstances() {
        let defaults = makeDefaults()
        let first = MeshSightingsTracker(defaults: defaults, now: { self.noon })
        first.recordSightings([PeerID(str: "aaaa111122223333")])

        let second = MeshSightingsTracker(defaults: defaults, now: { self.noon.addingTimeInterval(60) })
        #expect(second.todayCount == 1)

        // Same peer again does not double count after a relaunch.
        second.recordSightings([PeerID(str: "aaaa111122223333")])
        #expect(second.todayCount == 1)
    }

    @Test
    func rollsOverOnNewDay() {
        let defaults = makeDefaults()
        var currentNow = noon
        let tracker = MeshSightingsTracker(defaults: defaults, now: { currentNow })
        tracker.recordSightings([PeerID(str: "aaaa111122223333")])
        #expect(tracker.todayCount == 1)

        currentNow = noon.addingTimeInterval(2 * 24 * 60 * 60)
        tracker.recordSightings([PeerID(str: "bbbb444455556666")])

        #expect(tracker.todayCount == 1)
    }

    @Test
    func clearResetsEverything() {
        let defaults = makeDefaults()
        defaults.set(noon.timeIntervalSince1970, forKey: "meshSightings.lastSeenAt")
        let tracker = MeshSightingsTracker(defaults: defaults, now: { self.noon })
        tracker.recordSightings([PeerID(str: "aaaa111122223333")])

        tracker.clear()

        #expect(tracker.todayCount == 0)
        #expect(defaults.object(forKey: "meshSightings.lastSeenAt") == nil)

        let reloaded = MeshSightingsTracker(defaults: defaults, now: { self.noon })
        #expect(reloaded.todayCount == 0)
    }

    @Test
    func recordsBatchedSightingsOnceAndDeduplicatesAcrossRepeatCalls() {
        let defaults = makeDefaults()
        let tracker = MeshSightingsTracker(defaults: defaults, now: { self.noon })

        let peerA = PeerID(str: "aaaa111122223333")
        let peerB = PeerID(str: "bbbb444455556666")
        let peerC = PeerID(str: "cccc777788889999")

        tracker.recordSightings([peerA, peerB, peerA])
        #expect(tracker.todayCount == 2)

        tracker.recordSightings([peerA, peerB, peerC])
        #expect(tracker.todayCount == 3)

        let reloaded = MeshSightingsTracker(defaults: defaults, now: { self.noon.addingTimeInterval(30) })
        #expect(reloaded.todayCount == 3)
        reloaded.recordSightings([peerA, peerB, peerC])
        #expect(reloaded.todayCount == 3)
    }
}

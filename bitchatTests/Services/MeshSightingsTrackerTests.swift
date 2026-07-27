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

        tracker.recordSighting(peerID: PeerID(str: "aaaa111122223333"))
        tracker.recordSighting(peerID: PeerID(str: "aaaa111122223333"))
        tracker.recordSighting(peerID: PeerID(str: "bbbb444455556666"))

        #expect(tracker.todayCount == 2)
        #expect(tracker.lastSightingAt == noon)
    }

    @Test
    func persistsAcrossInstances() {
        let defaults = makeDefaults()
        let first = MeshSightingsTracker(defaults: defaults, now: { self.noon })
        first.recordSighting(peerID: PeerID(str: "aaaa111122223333"))

        let second = MeshSightingsTracker(defaults: defaults, now: { self.noon.addingTimeInterval(60) })
        #expect(second.todayCount == 1)

        // Same peer again does not double count after a relaunch.
        second.recordSighting(peerID: PeerID(str: "aaaa111122223333"))
        #expect(second.todayCount == 1)
    }

    @Test
    func rollsOverOnNewDay() {
        let defaults = makeDefaults()
        var currentNow = noon
        let tracker = MeshSightingsTracker(defaults: defaults, now: { currentNow })
        tracker.recordSighting(peerID: PeerID(str: "aaaa111122223333"))
        #expect(tracker.todayCount == 1)

        currentNow = noon.addingTimeInterval(2 * 24 * 60 * 60)
        tracker.recordSighting(peerID: PeerID(str: "bbbb444455556666"))

        #expect(tracker.todayCount == 1)
    }

    @Test
    func clearResetsEverything() {
        let defaults = makeDefaults()
        let tracker = MeshSightingsTracker(defaults: defaults, now: { self.noon })
        tracker.recordSighting(peerID: PeerID(str: "aaaa111122223333"))

        tracker.clear()

        #expect(tracker.todayCount == 0)
        #expect(tracker.lastSightingAt == nil)

        let reloaded = MeshSightingsTracker(defaults: defaults, now: { self.noon })
        #expect(reloaded.todayCount == 0)
    }
}

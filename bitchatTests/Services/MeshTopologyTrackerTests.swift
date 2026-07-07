//
// MeshTopologyTrackerTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import bitchat

struct MeshTopologyTrackerTests {
    private func hex(_ value: String) throws -> Data {
        try #require(Data(hexString: value))
    }

    @Test func directLinkProducesRoute() throws {
        let tracker = MeshTopologyTracker()
        let a = try hex("0102030405060708")
        let b = try hex("1112131415161718")

        // Bidirectional announcement
        tracker.updateNeighbors(for: a, neighbors: [b])
        tracker.updateNeighbors(for: b, neighbors: [a])
        
        let route = try #require(tracker.computeRoute(from: a, to: b))
        // Direct connection returns empty route (no intermediate hops)
        #expect(route == [])
    }

    @Test func multiHopRouteComputation() throws {
        let tracker = MeshTopologyTracker()
        let a = try hex("0001020304050607")
        let b = try hex("1011121314151617")
        let c = try hex("2021222324252627")
        let d = try hex("3031323334353637")

        // Bidirectional announcements for A-B, B-C, C-D
        tracker.updateNeighbors(for: a, neighbors: [b])
        tracker.updateNeighbors(for: b, neighbors: [a, c])
        tracker.updateNeighbors(for: c, neighbors: [b, d])
        tracker.updateNeighbors(for: d, neighbors: [c])

        let route = try #require(tracker.computeRoute(from: a, to: d))
        // Route should only contain intermediate hops (b, c), excluding start (a) and end (d)
        #expect(route == [b, c])
    }

    @Test func unconfirmedEdgeDoesNotRoute() throws {
        let tracker = MeshTopologyTracker()
        let a = try hex("0101010101010101")
        let b = try hex("0202020202020202")
        let c = try hex("0303030303030303")

        // A announces B (confirmed)
        // B announces A, C (confirmed A-B, unconfirmed B-C)
        // C does NOT announce B
        tracker.updateNeighbors(for: a, neighbors: [b])
        tracker.updateNeighbors(for: b, neighbors: [a, c])
        // C is silent or announces empty

        // Should NOT find route A->C because B->C is unconfirmed (C didn't announce B)
        #expect(tracker.computeRoute(from: a, to: c) == nil)
        
        // Now C announces B
        tracker.updateNeighbors(for: c, neighbors: [b])
        // Should find route
        let route = try #require(tracker.computeRoute(from: a, to: c))
        #expect(route == [b])
    }

    @Test func removingPeerClearsEdges() throws {
        let tracker = MeshTopologyTracker()
        let a = try hex("0F0E0D0C0B0A0908")
        let b = try hex("0A0B0C0D0E0F0001")
        let c = try hex("0011223344556677")

        tracker.updateNeighbors(for: a, neighbors: [b])
        tracker.updateNeighbors(for: b, neighbors: [a, c])
        tracker.updateNeighbors(for: c, neighbors: [b])

        let initialRoute = try #require(tracker.computeRoute(from: a, to: c))
        #expect(initialRoute == [b])

        tracker.removePeer(b)
        #expect(tracker.computeRoute(from: a, to: c) == nil)
    }

    @Test func sameStartAndEndReturnsEmptyRoute() throws {
        let tracker = MeshTopologyTracker()
        let a = try hex("0102030405060708")
        let b = try hex("1112131415161718")

        tracker.updateNeighbors(for: a, neighbors: [b])
        tracker.updateNeighbors(for: b, neighbors: [a])

        // When start == end, route should be empty (no intermediate hops needed)
        let route = try #require(tracker.computeRoute(from: a, to: a))
        #expect(route == [])
    }

    @Test func noPathReturnsNil() throws {
        let tracker = MeshTopologyTracker()
        let a = try hex("0101010101010101")
        let b = try hex("0202020202020202")
        let c = try hex("0303030303030303")
        let d = try hex("0404040404040404")

        // Two disconnected islands: A-B and C-D
        tracker.updateNeighbors(for: a, neighbors: [b])
        tracker.updateNeighbors(for: b, neighbors: [a])
        tracker.updateNeighbors(for: c, neighbors: [d])
        tracker.updateNeighbors(for: d, neighbors: [c])

        #expect(tracker.computeRoute(from: a, to: d) == nil)
    }

    /// Build a confirmed line topology n0 - n1 - ... - n(count-1).
    private func makeLine(_ tracker: MeshTopologyTracker, count: Int) throws -> [Data] {
        let nodes = try (0..<count).map { try hex(String(format: "%016x", $0 + 1)) }
        for i in 0..<count {
            var neighbors: [Data] = []
            if i > 0 { neighbors.append(nodes[i - 1]) }
            if i < count - 1 { neighbors.append(nodes[i + 1]) }
            tracker.updateNeighbors(for: nodes[i], neighbors: neighbors)
        }
        return nodes
    }

    @Test func maxHopsCapsIntermediateHopCount() throws {
        let tracker = MeshTopologyTracker()
        // 7 nodes: source + 5 intermediates + target
        let nodes = try makeLine(tracker, count: 7)

        // 5 intermediates exceed a 4-hop cap
        #expect(tracker.computeRoute(from: nodes[0], to: nodes[6], maxHops: 4) == nil)
        // 4 intermediates fit exactly
        let route = try #require(tracker.computeRoute(from: nodes[0], to: nodes[5], maxHops: 4))
        #expect(route == Array(nodes[1...4]))
    }

    @Test func staleNeighborBlocksRoute() throws {
        let tracker = MeshTopologyTracker()
        let a = try hex("0101010101010101")
        let b = try hex("0202020202020202")
        let c = try hex("0303030303030303")

        let staleDate = Date().addingTimeInterval(-120) // past 60s freshness
        tracker.updateNeighbors(for: a, neighbors: [b])
        tracker.updateNeighbors(for: b, neighbors: [a, c], at: staleDate)
        tracker.updateNeighbors(for: c, neighbors: [b])

        #expect(tracker.computeRoute(from: a, to: c) == nil)

        // Refreshing B restores the route.
        tracker.updateNeighbors(for: b, neighbors: [a, c])
        let route = try #require(tracker.computeRoute(from: a, to: c))
        #expect(route == [b])
    }

    @Test func versionGateBlocksV1AndUnknownHops() throws {
        let tracker = MeshTopologyTracker()
        let a = try hex("0101010101010101")
        let b = try hex("0202020202020202")
        let c = try hex("0303030303030303")

        tracker.updateNeighbors(for: a, neighbors: [b])
        tracker.updateNeighbors(for: b, neighbors: [a, c])
        tracker.updateNeighbors(for: c, neighbors: [b])

        // Without the gate the route exists.
        #expect(tracker.computeRoute(from: a, to: c) == [b])
        // Version-unknown hops are assumed v1-only and block gated routes.
        #expect(tracker.computeRoute(from: a, to: c, requiringVersion: 2) == nil)

        // A v1 observation does not unlock the gate.
        tracker.recordObservedVersion(1, for: b)
        tracker.recordObservedVersion(2, for: c)
        #expect(tracker.computeRoute(from: a, to: c, requiringVersion: 2) == nil)

        // Once the hop is observed speaking v2 the route opens.
        tracker.recordObservedVersion(2, for: b)
        let route = try #require(tracker.computeRoute(from: a, to: c, requiringVersion: 2))
        #expect(route == [b])
    }

    @Test func versionGateRequiresV2Target() throws {
        let tracker = MeshTopologyTracker()
        let a = try hex("0101010101010101")
        let b = try hex("0202020202020202")
        let c = try hex("0303030303030303")

        tracker.updateNeighbors(for: a, neighbors: [b])
        tracker.updateNeighbors(for: b, neighbors: [a, c])
        tracker.updateNeighbors(for: c, neighbors: [b])
        tracker.recordObservedVersion(2, for: b)

        // The recipient must decode the v2 frame too.
        #expect(tracker.computeRoute(from: a, to: c, requiringVersion: 2) == nil)

        tracker.recordObservedVersion(2, for: c)
        #expect(tracker.computeRoute(from: a, to: c, requiringVersion: 2) == [b])
    }

    @Test func pruneDropsStaleObservedVersions() throws {
        let tracker = MeshTopologyTracker()
        let a = try hex("0101010101010101")
        let b = try hex("0202020202020202")
        let c = try hex("0303030303030303")

        tracker.updateNeighbors(for: a, neighbors: [b])
        tracker.updateNeighbors(for: b, neighbors: [a, c])
        tracker.updateNeighbors(for: c, neighbors: [b])
        let old = Date().addingTimeInterval(-120)
        tracker.recordObservedVersion(2, for: b, at: old)
        tracker.recordObservedVersion(2, for: c, at: old)

        #expect(tracker.computeRoute(from: a, to: c, requiringVersion: 2) == [b])
        tracker.prune(olderThan: 60)
        // Claims are fresh but the version observations aged out.
        #expect(tracker.computeRoute(from: a, to: c, requiringVersion: 2) == nil)
    }

}

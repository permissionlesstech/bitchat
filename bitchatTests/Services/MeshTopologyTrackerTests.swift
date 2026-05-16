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

}

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

        tracker.recordDirectLink(between: a, and: b)
        let route = try #require(tracker.computeRoute(from: a, to: b))
        #expect(route == [a, b])
    }

    @Test func multiHopRouteComputation() throws {
        let tracker = MeshTopologyTracker()
        let a = try hex("0001020304050607")
        let b = try hex("1011121314151617")
        let c = try hex("2021222324252627")
        let d = try hex("3031323334353637")

        tracker.recordDirectLink(between: a, and: b)
        tracker.recordDirectLink(between: b, and: c)
        tracker.recordDirectLink(between: c, and: d)

        let route = try #require(tracker.computeRoute(from: a, to: d))
        #expect(route == [a, b, c, d])
    }

    @Test func recordRouteAddsEdges() throws {
        let tracker = MeshTopologyTracker()
        var a = Data([0xAA, 0xBB, 0xCC])
        let b = try hex("4445464748494A4B")
        let c = try hex("5455565758595A5B")

        tracker.recordRoute([a, b, c])

        a.append(Data(repeating: 0, count: BinaryProtocol.senderIDSize - a.count))
        let route = try #require(tracker.computeRoute(from: a, to: c))
        #expect(route.first == a)
        #expect(route.last == c)
    }

    @Test func removingDirectLinkBreaksRoute() throws {
        let tracker = MeshTopologyTracker()
        let a = try hex("0101010101010101")
        let b = try hex("0202020202020202")
        let c = try hex("0303030303030303")

        tracker.recordDirectLink(between: a, and: b)
        tracker.recordDirectLink(between: b, and: c)
        let initialRoute = try #require(tracker.computeRoute(from: a, to: c))
        #expect(initialRoute == [a, b, c])

        tracker.removeDirectLink(between: b, and: c)
        #expect(tracker.computeRoute(from: a, to: c) == nil)
    }

    @Test func removingPeerClearsEdges() throws {
        let tracker = MeshTopologyTracker()
        let a = try hex("0F0E0D0C0B0A0908")
        let b = try hex("0A0B0C0D0E0F0001")
        let c = try hex("0011223344556677")

        tracker.recordRoute([a, b, c])
        let initialRoute = try #require(tracker.computeRoute(from: a, to: c))
        #expect(initialRoute == [a, b, c])

        tracker.removePeer(b)
        #expect(tracker.computeRoute(from: a, to: c) == nil)
    }

}

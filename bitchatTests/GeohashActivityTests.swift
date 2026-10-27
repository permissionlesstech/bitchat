//
// GeohashActivityTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CoreGraphics
import Foundation
import Testing
@testable import bitchat

struct GeohashActivityAggregatorTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func heartbeatsCountForThePresenceWindowOnly() {
        var aggregator = GeohashActivityAggregator()
        let result1 = aggregator.record(geohash: "u33d", pubkey: "a", at: now.addingTimeInterval(-200), now: now)
        #expect(result1)
        let result2 = aggregator.record(geohash: "u33d", pubkey: "b", at: now.addingTimeInterval(-400), now: now)
        #expect(!result2)
        #expect(aggregator.count(in: "u33d", now: now) == 1)
        #expect(aggregator.count(in: "u33d", now: now.addingTimeInterval(101)) == 0)
    }

    @Test func chatAuthorsCountForTheHour() throws {
        var aggregator = GeohashActivityAggregator()
        let result3 = aggregator.record(geohash: "u33d", pubkey: "a", at: now.addingTimeInterval(-1_800), chatEventID: "m1", now: now)
        #expect(result3)
        let result4 = aggregator.record(geohash: "u33d", pubkey: "b", at: now.addingTimeInterval(-3_700), chatEventID: "m2", now: now)
        #expect(!result4)

        let channel = try #require(aggregator.snapshot(now: now).channel("u33d"))
        #expect(channel.people == 1)
        #expect(channel.chatters == 1)
        #expect(channel.messages == 1)
        #expect(channel.online == 0)
        #expect(aggregator.count(in: "u33d", now: now.addingTimeInterval(1_801)) == 0)
    }

    @Test func aHeartbeatAndAMessageFromOnePersonCountOnce() throws {
        var aggregator = GeohashActivityAggregator()
        aggregator.record(geohash: "u33d", pubkey: "A", at: now, now: now)
        aggregator.record(geohash: "u33d", pubkey: "a", at: now, chatEventID: "m1", now: now)
        aggregator.record(geohash: "u33d", pubkey: "a", at: now, chatEventID: "m1", now: now)
        let channel = try #require(aggregator.snapshot(now: now).channel("u33d"))
        #expect(channel.people == 1)
        #expect(channel.online == 1)
        #expect(channel.messages == 1)
    }

    @Test func futureTimestampsAreClampedToNow() {
        var aggregator = GeohashActivityAggregator()
        aggregator.record(geohash: "u33d", pubkey: "skewed", at: now.addingTimeInterval(3_600), now: now)
        #expect(aggregator.count(in: "u33d", now: now.addingTimeInterval(301)) == 0)
    }

    @Test func excludedIdentitiesDropOutOfEveryCount() throws {
        var aggregator = GeohashActivityAggregator()
        aggregator.record(geohash: "u33d", pubkey: "blocked", at: now, chatEventID: "m1", now: now)
        aggregator.record(geohash: "u33d", pubkey: "friend", at: now, now: now)
        let snapshot = aggregator.snapshot(now: now) { $0 == "blocked" }
        let channel = try #require(snapshot.channel("u33d"))
        #expect(channel.people == 1)
        #expect(channel.messages == 0)
        #expect(snapshot.activeChats == 0)
        #expect(aggregator.count(in: "u33d", now: now) { $0 == "blocked" } == 1)
    }

    @Test func pruningKeepsChattersForTheHourThenDropsTheChannel() {
        var aggregator = GeohashActivityAggregator()
        aggregator.record(geohash: "u33d", pubkey: "a", at: now, now: now)
        aggregator.record(geohash: "u33d", pubkey: "a", at: now, chatEventID: "m1", now: now)
        aggregator.record(geohash: "u33d", pubkey: "quiet", at: now, now: now)

        let result5 = aggregator.prune(now: now.addingTimeInterval(400))
        #expect(result5)
        #expect(aggregator.activePeople(in: "u33d", now: now.addingTimeInterval(400)).keys.sorted() == ["a"])

        let result6 = aggregator.prune(now: now.addingTimeInterval(3_700))
        #expect(result6)
        #expect(aggregator.isEmpty)
    }

    @Test func snapshotOrdersByPeopleAndEstimatesWorldwideHeadcountPerLevel() {
        var aggregator = GeohashActivityAggregator()
        // The same three people heartbeat into region, province and city channels.
        for key in ["a", "b", "c"] {
            for cell in ["u3", "u33d", "u33dc"] {
                aggregator.record(geohash: cell, pubkey: key + cell, at: now, now: now)
            }
        }
        aggregator.record(geohash: "dr5r", pubkey: "d", at: now, chatEventID: "m", now: now)
        aggregator.record(geohash: "not-a-geohash", pubkey: "e", at: now, now: now)

        let snapshot = aggregator.snapshot(now: now)
        #expect(snapshot.channels.map(\.geohash) == ["u3", "u33d", "u33dc", "dr5r"])
        #expect(snapshot.totalOnline == 4)
        #expect(snapshot.activeChats == 1)
        #expect(aggregator.count(in: "not-a-geohash", now: now) == 1)
    }

    @Test func busiestInsideOffersALivelierNestedChat() {
        var aggregator = GeohashActivityAggregator()
        aggregator.record(geohash: "u33", pubkey: "a", at: now, chatEventID: "1", now: now)
        aggregator.record(geohash: "u33d", pubkey: "b", at: now, chatEventID: "2", now: now)
        aggregator.record(geohash: "u33d", pubkey: "b", at: now, chatEventID: "3", now: now)
        aggregator.record(geohash: "u33dc", pubkey: "c", at: now, now: now)
        aggregator.record(geohash: "u0", pubkey: "d", at: now, chatEventID: "4", now: now)
        aggregator.record(geohash: "u0", pubkey: "d", at: now, chatEventID: "5", now: now)
        aggregator.record(geohash: "u0", pubkey: "d", at: now, chatEventID: "6", now: now)

        let snapshot = aggregator.snapshot(now: now)
        #expect(snapshot.busiestInside("u33")?.geohash == "u33d")
        #expect(snapshot.busiestInside("u33d") == nil)
        #expect(snapshot.busiestInside("") == nil)
    }
}

@MainActor
struct GeohashActivityMonitorTests {
    private func event(_ kind: NostrProtocol.EventKind, pubkey: String, geohash: String?, content: String = "", at: Date) -> NostrEvent {
        var event = NostrEvent(
            pubkey: pubkey,
            createdAt: at,
            kind: kind,
            tags: geohash.map { [["g", $0]] } ?? [],
            content: content
        )
        event.id = UUID().uuidString
        return event
    }

    @Test func ingestCountsGeohashEventsOnly() {
        let monitor = GeohashActivityMonitor(relayManager: nil, relayDirectory: nil)
        let now = Date()
        #expect(monitor.ingest(event(.geohashPresence, pubkey: "a", geohash: "u33d", at: now), seenAt: now))
        #expect(!monitor.ingest(event(.geohashPresence, pubkey: "b", geohash: nil, at: now), seenAt: now))
        #expect(!monitor.ingest(event(.geohashPresence, pubkey: "c", geohash: "oops!", at: now), seenAt: now))
        #expect(!monitor.ingest(event(.textNote, pubkey: "d", geohash: "u33d", content: "hi", at: now), seenAt: now))
        monitor.publish()
        #expect(monitor.snapshot.channels.map(\.geohash) == ["u33d"])
        #expect(monitor.snapshot.totalOnline == 1)
    }

    /// People whose last activity is a message leave the online count when the
    /// presence window passes, even if no new events arrive.
    @Test func onlineCountsExpireWithoutNewEvents() throws {
        let monitor = GeohashActivityMonitor(relayManager: nil, relayDirectory: nil)
        let now = Date()
        monitor.ingest(event(.ephemeralEvent, pubkey: "a", geohash: "u33d", content: "hi", at: now), seenAt: now)
        monitor.publish(now: now)
        #expect(monitor.snapshot.totalOnline == 1)

        monitor.publish(now: now.addingTimeInterval(400))
        let channel = try #require(monitor.snapshot.channel("u33d"))
        #expect(channel.online == 0)
        #expect(channel.people == 1)
        #expect(monitor.snapshot.totalOnline == 0)
    }

    @Test func blockedPeopleAreHidden() {
        let monitor = GeohashActivityMonitor(relayManager: nil, relayDirectory: nil, isBlocked: { $0 == "blocked" })
        let now = Date()
        monitor.ingest(event(.ephemeralEvent, pubkey: "BLOCKED", geohash: "u33d", content: "spam", at: now), seenAt: now)
        monitor.publish(now: now)
        #expect(monitor.snapshot.channels.isEmpty)
    }

    @Test func startingAndStoppingWithoutRelaysIsSafe() {
        let monitor = GeohashActivityMonitor(relayManager: nil, relayDirectory: nil, isNetworkAvailable: { false })
        monitor.start()
        monitor.start()
        monitor.stop()
        monitor.stop()
        #expect(monitor.snapshot.channels.isEmpty)
    }
}

@MainActor
struct GeohashParticipantTrackerActivityRuleTests {
    @Test func chatAuthorsStayInTheSheetForTheHour() {
        let tracker = GeohashParticipantTracker()
        let context = MockParticipantContext()
        tracker.configure(context: context)
        tracker.setActiveGeohash("u33d")
        let halfAnHourAgo = Date().addingTimeInterval(-1_800)

        #expect(!tracker.recordParticipant(pubkeyHex: "lurker", seenAt: halfAnHourAgo))
        #expect(tracker.recordParticipant(pubkeyHex: "writer", seenAt: halfAnHourAgo, chatEventID: "m1"))
        #expect(tracker.participantCount(for: "u33d") == 1)
        #expect(tracker.getVisiblePeople().map(\.id) == ["writer"])
    }

    @Test func blockedPeopleAreLeftOutOfTheCount() {
        let tracker = GeohashParticipantTracker()
        let context = MockParticipantContext()
        context.blockedPubkeys = ["troll"]
        tracker.configure(context: context)
        tracker.recordParticipant(pubkeyHex: "troll", geohash: "u33d")
        tracker.recordParticipant(pubkeyHex: "friend", geohash: "u33d")
        #expect(tracker.participantCount(for: "u33d") == 1)
    }
}

struct GlobeActivityLayerTests {
    private func channel(_ geohash: String, people: Int = 3, messages: Int = 0) -> GeohashChannelActivity {
        let center = Geohash.decodeCenter(geohash)
        return GeohashChannelActivity(
            geohash: geohash,
            latitude: center.lat,
            longitude: center.lon,
            online: people,
            chatters: messages > 0 ? 1 : 0,
            messages: messages,
            people: people,
            lastActiveAt: Date()
        )
    }

    private let size = CGSize(width: 400, height: 800)

    @Test func nearbyChannelsClusterUntilZoomedIn() {
        let channels = [channel("u33dc", people: 9, messages: 10), channel("u33dg", people: 4)]
        let center = Geohash.decodeCenter("u33d")
        let far = GlobeMarkerLayoutEngine.layout(channels, centerLat: center.lat, centerLon: center.lon, radius: 176, size: size)
        #expect(far.count == 1)
        #expect(far[0].isCluster)
        #expect(far[0].primary.geohash == "u33dc")
        #expect(far[0].messages == 10)

        let near = GlobeMarkerLayoutEngine.layout(channels, centerLat: center.lat, centerLon: center.lon, radius: 40_000, size: size)
        #expect(near.count == 2)
    }

    @Test func farSideChannelsAreCulled() {
        let markers = GlobeMarkerLayoutEngine.layout([channel("u33d"), channel("r3gx")], centerLat: 52.5, centerLon: 13.4, radius: 176, size: size)
        #expect(markers.map(\.primary.geohash) == ["u33d"])
    }

    @Test func hitTestingPrefersTheClosestEdge() {
        let layer = GlobeMarkerLayer()
        let center = Geohash.decodeCenter("u33d")
        _ = layer.frame(channels: [channel("u33d", people: 25, messages: 5)], centerLat: center.lat, centerLon: center.lon,
                        radius: 176, size: size, now: 0, instant: true)
        #expect(layer.hitTest(CGPoint(x: 200, y: 400))?.primary.geohash == "u33d")
        #expect(layer.hitTest(CGPoint(x: 20, y: 20)) == nil)
    }

    @Test func chatMarkersOutrankHeartbeatsAndCapTheirSize() {
        #expect(GlobeMarker.radius(people: 4, chatting: true, cluster: false) > GlobeMarker.radius(people: 4, chatting: false, cluster: false))
        #expect(GlobeMarker.radius(people: 10_000, chatting: true, cluster: true) == GlobeMarker.maxRadius)
        #expect(GlobeMarker.radius(people: 1, chatting: true, cluster: true) >= 9)
    }

    @Test func heatRampsFromGreenThroughYellowToHot() {
        let colors = GlobeActivityColors(
            quiet: GlobeRGB(red: 0, green: 0, blue: 1),
            active: GlobeRGB(red: 0, green: 1, blue: 0),
            hot: GlobeRGB(red: 1, green: 0.5, blue: 0),
            quietText: .black,
            selection: .black
        )
        #expect(colors.fill(messages: 0) == colors.quiet)
        #expect(colors.fill(messages: 1_000) == colors.hot)
        let middle = colors.fill(messages: 7)
        #expect(middle.red > 0.5 && middle.green > 0.8 && middle.blue < 0.1)
    }

    @Test func compactCountsStayShort() {
        #expect(GlobeMarker.compactCount(842) == "842")
        #expect(GlobeMarker.compactCount(1_000) == "1k")
        #expect(GlobeMarker.compactCount(1_250) == "1.2k" || GlobeMarker.compactCount(1_250) == "1.3k")
        #expect(GlobeMarker.compactCount(12_400) == "12k")
    }
}

struct GlobeMarkerAnimatorTests {
    private func marker(_ geohashes: String..., x: Double = 100, radius: Double = 10) -> GlobeMarker {
        let channels = geohashes.map {
            GeohashChannelActivity(geohash: $0, latitude: 0, longitude: 0, online: 1, chatters: 1, messages: 1, people: 1, lastActiveAt: Date())
        }
        return GlobeMarker(x: x, y: 100, radius: radius, channels: channels, people: channels.count, messages: channels.count, lastActiveAt: Date(), depth: 1)
    }

    @Test func newMarkersFadeInInPlaceAndSettleAtFullSize() throws {
        let animator = GlobeMarkerAnimator()
        _ = animator.frame([marker("u0")], now: 0, instant: false)
        let appearing = try #require(animator.frame([marker("u0")], now: 0.08, instant: false).first)
        #expect(appearing.x == 100 && appearing.y == 100)
        #expect(appearing.alpha > 0.01 && appearing.alpha < 0.99)
        #expect(appearing.radius >= 6 && appearing.radius < 10)
        #expect(animator.isAnimating)

        let settled = try #require(animator.frame([marker("u0")], now: 0.25, instant: false).first)
        #expect(abs(settled.radius - 10) < 0.01)
        #expect(settled.alpha == 1)
        _ = animator.frame([marker("u0")], now: 0.266, instant: false)
        #expect(!animator.isAnimating)
    }

    @Test func appearingNeverOvershootsFullSize() {
        let animator = GlobeMarkerAnimator()
        for step in 0...31 {
            let frame = animator.frame([marker("u0")], now: Double(step) * 0.008, instant: false)
            #expect(frame[0].radius <= 10)
        }
    }

    @Test func removedMarkersFadeOutWhereTheyWereThenVanish() throws {
        let animator = GlobeMarkerAnimator()
        _ = animator.frame([marker("u0")], now: 0, instant: false)
        _ = animator.frame([marker("u0")], now: 0.3, instant: false)
        _ = animator.frame([], now: 0.3, instant: false)
        let leaving = try #require(animator.frame([], now: 0.37, instant: false).first)
        #expect(leaving.x == 100)
        #expect(leaving.radius >= 7 && leaving.radius < 10)
        #expect(leaving.alpha > 0.01 && leaving.alpha < 0.99)
        #expect(animator.frame([], now: 0.46, instant: false).isEmpty)
        #expect(!animator.isAnimating)
    }

    @Test func mergingIntoAClusterFadesInPlaceWithoutTravelling() throws {
        let animator = GlobeMarkerAnimator()
        _ = animator.frame([marker("u0"), marker("u1", x: 200)], now: 0, instant: false)
        _ = animator.frame([marker("u0"), marker("u1", x: 200)], now: 0.3, instant: false)
        let cluster = marker("u0", "u1", radius: 14)
        _ = animator.frame([cluster], now: 0.31, instant: false)
        let ghost = try #require(animator.frame([cluster], now: 0.36, instant: false).first { $0.marker.primary.geohash == "u1" })
        #expect(ghost.x == 200)
    }

    @Test func clusterGrowthEasesInsteadOfJumping() throws {
        let animator = GlobeMarkerAnimator()
        _ = animator.frame([marker("u0")], now: 0, instant: false)
        _ = animator.frame([marker("u0")], now: 0.3, instant: false)
        let grown = try #require(animator.frame([marker("u0", radius: 16)], now: 0.316, instant: false).first)
        #expect(grown.radius > 10 && grown.radius < 16)
    }

    @Test func reduceMotionShowsChangesImmediately() throws {
        let animator = GlobeMarkerAnimator()
        let frame = try #require(animator.frame([marker("u0")], now: 0, instant: true).first)
        #expect(frame.radius == 10)
        #expect(frame.alpha == 1)
        #expect(animator.frame([], now: 0.01, instant: true).isEmpty)
    }
}

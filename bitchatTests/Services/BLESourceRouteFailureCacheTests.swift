//
// BLESourceRouteFailureCacheTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

struct BLESourceRouteFailureCacheTests {
    private let recipient = PeerID(str: "0102030405060708")
    private let config = BLESourceRouteFailureCache.Config(
        confirmationWindowSeconds: 10,
        suppressionSeconds: 60
    )

    private func attempts(_ cache: inout BLESourceRouteFailureCache, at date: Date) -> Bool {
        cache.shouldAttemptRoute(to: recipient, now: date)
    }

    @Test func allowsRoutingByDefault() {
        var cache = BLESourceRouteFailureCache(config: config)
        #expect(attempts(&cache, at: Date()))
    }

    @Test func unconfirmedRoutedSendSuppressesRouting() {
        var cache = BLESourceRouteFailureCache(config: config)
        let t0 = Date()

        cache.noteRoutedSend(to: recipient, now: t0)
        // Inside the confirmation window: keep routing.
        #expect(attempts(&cache, at: t0.addingTimeInterval(5)))
        // Past the window with no inbound traffic: route failed, flood.
        #expect(!attempts(&cache, at: t0.addingTimeInterval(11)))
        // Still suppressed for the suppression TTL.
        #expect(!attempts(&cache, at: t0.addingTimeInterval(40)))
        // Suppression lapses: routing may be attempted again.
        #expect(attempts(&cache, at: t0.addingTimeInterval(11 + 61)))
    }

    @Test func inboundActivityConfirmsPendingSend() {
        var cache = BLESourceRouteFailureCache(config: config)
        let t0 = Date()

        cache.noteRoutedSend(to: recipient, now: t0)
        cache.noteInboundActivity(from: recipient)
        // Confirmed: no suppression even long after the window.
        #expect(attempts(&cache, at: t0.addingTimeInterval(30)))
    }

    @Test func inboundActivityDoesNotLiftActiveSuppression() {
        var cache = BLESourceRouteFailureCache(config: config)
        let t0 = Date()

        cache.noteRoutedSend(to: recipient, now: t0)
        // Trip the failure → suppression starts at t0+15.
        #expect(!attempts(&cache, at: t0.addingTimeInterval(15)))
        // Inbound traffic may have arrived via flood; suppression holds.
        cache.noteInboundActivity(from: recipient)
        #expect(!attempts(&cache, at: t0.addingTimeInterval(20)))
        #expect(attempts(&cache, at: t0.addingTimeInterval(15 + 61)))
    }

    @Test func backToBackSendsShareOneDeadline() {
        var cache = BLESourceRouteFailureCache(config: config)
        let t0 = Date()

        cache.noteRoutedSend(to: recipient, now: t0)
        cache.noteRoutedSend(to: recipient, now: t0.addingTimeInterval(8))
        // Deadline runs from the first unconfirmed send.
        #expect(!attempts(&cache, at: t0.addingTimeInterval(11)))
    }

    @Test func pruneDropsExpiredEntries() {
        var cache = BLESourceRouteFailureCache(config: config)
        let t0 = Date()

        cache.noteRoutedSend(to: recipient, now: t0)
        // Past confirmation + suppression: the entry can no longer matter.
        cache.prune(now: t0.addingTimeInterval(75))
        #expect(attempts(&cache, at: t0.addingTimeInterval(76)))
    }

    @Test func pruneKeepsEntriesThatStillMatter() {
        var cache = BLESourceRouteFailureCache(config: config)
        let t0 = Date()

        cache.noteRoutedSend(to: recipient, now: t0)
        cache.prune(now: t0.addingTimeInterval(30))
        // The unconverted pending entry survives pruning and still converts
        // into a suppression on the next routing decision.
        #expect(!attempts(&cache, at: t0.addingTimeInterval(31)))
    }
}

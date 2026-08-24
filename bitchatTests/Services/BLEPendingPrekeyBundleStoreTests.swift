//
// BLEPendingPrekeyBundleStoreTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BLEPendingPrekeyBundleStoreTests {
    private let config = BLEPendingPrekeyBundleStore.Config(capacity: 4, ttlSeconds: 60)
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func owner(_ index: Int) -> PeerID {
        PeerID(hexData: Data([0, 0, 0, 0, 0, 0, UInt8(index >> 8), UInt8(index & 0xFF)]))
    }

    private func packet(_ marker: UInt8) -> BitchatPacket {
        BitchatPacket(
            type: MessageType.prekeyBundle.rawValue,
            senderID: Data(repeating: marker, count: 8),
            recipientID: nil,
            timestamp: 1_000_000_000,
            payload: Data([marker]),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        )
    }

    @Test
    func stashedBundleIsReturnedOnce() {
        var store = BLEPendingPrekeyBundleStore(config: config)
        store.stash(packet(1), for: owner(1), now: t0)

        #expect(store.take(for: owner(1), now: t0.addingTimeInterval(1))?.payload == Data([1]))
        #expect(store.take(for: owner(1), now: t0.addingTimeInterval(1)) == nil)
        #expect(store.count == 0)
    }

    @Test
    func latestBundleForAnOwnerReplacesTheEarlierOne() {
        var store = BLEPendingPrekeyBundleStore(config: config)
        store.stash(packet(1), for: owner(1), now: t0)
        store.stash(packet(2), for: owner(1), now: t0.addingTimeInterval(1))

        #expect(store.count == 1)
        #expect(store.take(for: owner(1), now: t0.addingTimeInterval(2))?.payload == Data([2]))
    }

    @Test
    func expiredBundleIsNotReturned() {
        var store = BLEPendingPrekeyBundleStore(config: config)
        store.stash(packet(1), for: owner(1), now: t0)

        #expect(store.take(for: owner(1), now: t0.addingTimeInterval(61)) == nil)
    }

    /// The regression this store exists for: unattributable bundles used to
    /// occupy the cap forever, so a later genuine bundle was never stashed and
    /// never retried.
    @Test
    func burstOfUnattributableBundlesDoesNotWedgeTheStash() {
        var store = BLEPendingPrekeyBundleStore(config: config)
        for index in 0..<config.capacity {
            store.stash(packet(0xFF), for: owner(index), now: t0)
        }
        #expect(store.count == config.capacity)

        let genuineOwner = owner(500)
        store.stash(packet(7), for: genuineOwner, now: t0.addingTimeInterval(1))

        #expect(store.count == config.capacity)
        #expect(store.take(for: genuineOwner, now: t0.addingTimeInterval(2))?.payload == Data([7]))
    }

    @Test
    func evictionAtCapacityDropsTheOldestEntry() {
        var store = BLEPendingPrekeyBundleStore(config: config)
        for index in 0..<config.capacity {
            store.stash(packet(UInt8(index)), for: owner(index), now: t0.addingTimeInterval(Double(index)))
        }

        store.stash(packet(9), for: owner(99), now: t0.addingTimeInterval(10))

        // Oldest (index 0) is gone; the newer ones and the new arrival survive.
        #expect(store.take(for: owner(0), now: t0.addingTimeInterval(11)) == nil)
        #expect(store.take(for: owner(1), now: t0.addingTimeInterval(11)) != nil)
        #expect(store.take(for: owner(99), now: t0.addingTimeInterval(11))?.payload == Data([9]))
    }

    @Test
    func expiredEntriesAreSweptSoTheyDoNotCostCapacity() {
        var store = BLEPendingPrekeyBundleStore(config: config)
        for index in 0..<config.capacity {
            store.stash(packet(0xFF), for: owner(index), now: t0)
        }

        // Every stale entry goes on the next stash, leaving only the newcomer.
        store.stash(packet(3), for: owner(500), now: t0.addingTimeInterval(61))

        #expect(store.count == 1)
        #expect(store.take(for: owner(500), now: t0.addingTimeInterval(62))?.payload == Data([3]))
    }

    @Test
    func replacingAnOwnerAtCapacityEvictsNobody() {
        var store = BLEPendingPrekeyBundleStore(config: config)
        for index in 0..<config.capacity {
            store.stash(packet(UInt8(index)), for: owner(index), now: t0.addingTimeInterval(Double(index)))
        }

        store.stash(packet(8), for: owner(0), now: t0.addingTimeInterval(10))

        #expect(store.count == config.capacity)
        #expect(store.take(for: owner(1), now: t0.addingTimeInterval(11)) != nil)
        #expect(store.take(for: owner(0), now: t0.addingTimeInterval(11))?.payload == Data([8]))
    }
}

//
// BLERelayLifecycleStoreTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import CryptoKit
import Foundation
import Testing
@testable import bitchat

struct BLERelayLifecycleStoreTests {
    private func makePacket(
        payload: String = "hello",
        signature: Data? = Data(repeating: 0xAA, count: 64),
        ttl: UInt8 = 6
    ) -> BitchatPacket {
        BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data(repeating: 0x11, count: 8),
            recipientID: nil,
            timestamp: 1_000,
            payload: Data(payload.utf8),
            signature: signature,
            ttl: ttl
        )
    }

    @Test
    func stateTransitionRulesAreTerminalOnceRelayed() {
        #expect(BLERelayLifecycleStore.canTransition(from: nil, to: .suppressed))
        #expect(BLERelayLifecycleStore.canTransition(from: nil, to: .relayed))
        #expect(BLERelayLifecycleStore.canTransition(from: .suppressed, to: .suppressed))
        #expect(BLERelayLifecycleStore.canTransition(from: .suppressed, to: .relayed))
        #expect(!BLERelayLifecycleStore.canTransition(from: .relayed, to: .suppressed))
        #expect(!BLERelayLifecycleStore.canTransition(from: .relayed, to: .relayed))
    }

    @Test
    func suppressedAuthenticatedPacketCanBeReconsideredAndClaimedOnce() {
        var store = BLERelayLifecycleStore(maxCount: 16, ttl: 60)
        let now = Date(timeIntervalSince1970: 1_000)
        let firstCopy = makePacket(payload: "hello", ttl: 6)
        let secondCopyDifferentTTL = makePacket(payload: "hello", ttl: 5)
        let tamperedCopy = makePacket(payload: "tampered", ttl: 5)
        let unsignedCopy = makePacket(payload: "hello", signature: nil, ttl: 5)

        store.markSuppressed(messageID: "m1", packet: firstCopy, isAuthenticated: true, now: now)

        // Exact signed packet with mutated hop TTL matches and may proceed.
        let canReconsiderValid = store.canReconsiderSuppressed(messageID: "m1", packet: secondCopyDifferentTTL, now: now)
        let canProceedValid = store.canProceed(messageID: "m1", isDuplicateIngress: true, packet: secondCopyDifferentTTL, now: now)
        let canProceedFirstArrivalValid = store.canProceed(messageID: "m1", isDuplicateIngress: false, packet: secondCopyDifferentTTL, now: now)
        #expect(canReconsiderValid)
        #expect(canProceedValid)
        #expect(canProceedFirstArrivalValid)

        // Tampered or unsigned copies are rejected on both duplicate and
        // post-ingress-window first-arrival paths (e.g., fragments).
        let canReconsiderTampered = store.canReconsiderSuppressed(messageID: "m1", packet: tamperedCopy, now: now)
        let canReconsiderUnsigned = store.canReconsiderSuppressed(messageID: "m1", packet: unsignedCopy, now: now)
        let canProceedTampered = store.canProceed(messageID: "m1", isDuplicateIngress: false, packet: tamperedCopy, now: now)
        let canProceedUnsigned = store.canProceed(messageID: "m1", isDuplicateIngress: false, packet: unsignedCopy, now: now)
        #expect(!canReconsiderTampered)
        #expect(!canReconsiderUnsigned)
        #expect(!canProceedTampered)
        #expect(!canProceedUnsigned)

        // Claiming transitions to terminal .relayed; further claims fail.
        let firstClaim = store.tryClaimRelay(messageID: "m1", isDuplicateIngress: true, now: now)
        let canReconsiderAfterClaim = store.canReconsiderSuppressed(messageID: "m1", packet: secondCopyDifferentTTL, now: now)
        let canProceedAfterClaim = store.canProceed(messageID: "m1", isDuplicateIngress: true, now: now)
        let secondClaim = store.tryClaimRelay(messageID: "m1", isDuplicateIngress: true, now: now)
        #expect(firstClaim)
        #expect(!canReconsiderAfterClaim)
        #expect(!canProceedAfterClaim)
        #expect(!secondClaim)
    }

    @Test
    func unauthenticatedSuppressedPacketCannotBeReconsideredOnDuplicate() {
        var store = BLERelayLifecycleStore(maxCount: 16, ttl: 60)
        let now = Date(timeIntervalSince1970: 1_000)
        let packet = makePacket(payload: "hello", signature: Data(repeating: 0xAA, count: 64))

        store.markSuppressed(messageID: "m1", packet: packet, isAuthenticated: false, now: now)

        let canReconsider = store.canReconsiderSuppressed(messageID: "m1", packet: packet, now: now)
        #expect(!canReconsider)
    }

    @Test
    func expiresEntriesAfterTTLAndCapsCapacity() {
        var store = BLERelayLifecycleStore(maxCount: 2, ttl: 10)
        let t0 = Date(timeIntervalSince1970: 1_000)
        let p = makePacket()

        store.markRelayed(messageID: "m1", now: t0)
        store.markRelayed(messageID: "m2", now: t0.addingTimeInterval(1))
        store.markRelayed(messageID: "m3", now: t0.addingTimeInterval(2))

        // Capacity cap of 2 evicts oldest ("m1").
        #expect(store.count == 2)
        let m1Evicted = store.canProceed(messageID: "m1", isDuplicateIngress: false, now: t0.addingTimeInterval(2))
        let m2StillTracked = store.canProceed(messageID: "m2", isDuplicateIngress: false, now: t0.addingTimeInterval(2))
        #expect(m1Evicted)
        #expect(!m2StillTracked)

        // Expiry clears remaining entries after TTL.
        store.markSuppressed(messageID: "m4", packet: p, isAuthenticated: true, now: t0.addingTimeInterval(3))
        let expiredCanReconsider = store.canReconsiderSuppressed(messageID: "m4", packet: p, now: t0.addingTimeInterval(14))
        #expect(!expiredCanReconsider)
    }

    @Test
    func selfAuthenticatingBoardPostWithoutOuterSignatureCanReopenSuppressedRelay() throws {
        var store = BLERelayLifecycleStore(maxCount: 16, ttl: 60)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let createdAt = UInt64(now.timeIntervalSince1970 * 1000)
        let author = Curve25519.Signing.PrivateKey()
        let postID = Data(repeating: 0x42, count: 16)
        let signingBytes = BoardPostPacket.signingBytes(
            postID: postID,
            geohash: "9q8yy",
            content: "board note",
            authorSigningKey: author.publicKey.rawRepresentation,
            authorNickname: "alice",
            createdAt: createdAt,
            expiresAt: createdAt + 60_000,
            flags: 0
        )
        let post = BoardPostPacket(
            postID: postID,
            geohash: "9q8yy",
            content: "board note",
            authorSigningKey: author.publicKey.rawRepresentation,
            authorNickname: "alice",
            createdAt: createdAt,
            expiresAt: createdAt + 60_000,
            flags: 0,
            signature: try author.signature(for: signingBytes)
        )
        let boardPacket = BitchatPacket(
            type: MessageType.boardPost.rawValue,
            senderID: Data(repeating: 0x11, count: 8),
            recipientID: nil,
            timestamp: createdAt,
            payload: BoardWire.post(post).encode(),
            signature: nil,
            ttl: 6
        )
        var duplicateCopy = boardPacket
        duplicateCopy.ttl = 5

        var tamperedPayload = duplicateCopy.payload
        tamperedPayload[tamperedPayload.count - 1] ^= 0xFF
        let tamperedCopy = BitchatPacket(
            type: duplicateCopy.type,
            senderID: duplicateCopy.senderID,
            recipientID: duplicateCopy.recipientID,
            timestamp: duplicateCopy.timestamp,
            payload: tamperedPayload,
            signature: nil,
            ttl: duplicateCopy.ttl
        )

        store.markSuppressed(messageID: "bp1", packet: boardPacket, isAuthenticated: true, now: now)

        let canReconsiderValid = store.canReconsiderSuppressed(messageID: "bp1", packet: duplicateCopy, now: now)
        let canReconsiderTampered = store.canReconsiderSuppressed(messageID: "bp1", packet: tamperedCopy, now: now)
        #expect(canReconsiderValid)
        #expect(!canReconsiderTampered)
    }

    @Test
    func repeatedSuppressedRefreshesKeepOrderLogBounded() {
        var store = BLERelayLifecycleStore(maxCount: 8, ttl: 60)
        let t0 = Date(timeIntervalSince1970: 1_000)
        let packet = makePacket(payload: "refresh-bound")

        // Refresh the same suppressed entry with advancing timestamps far more
        // than maxCount times within TTL.
        for i in 0..<100 {
            store.markSuppressed(
                messageID: "m1",
                packet: packet,
                isAuthenticated: true,
                now: t0.addingTimeInterval(Double(i) * 0.1)
            )
        }

        #expect(store.count == 1)
        #expect(store.orderLogCount <= store.maxCount * 2)

        // Repeat with a fixed timestamp (tied timestamps must not accumulate
        // duplicate order records across compaction passes).
        let fixedNow = t0.addingTimeInterval(20)
        for _ in 0..<100 {
            store.markSuppressed(
                messageID: "m1",
                packet: packet,
                isAuthenticated: true,
                now: fixedNow
            )
        }

        #expect(store.count == 1)
        #expect(store.orderLogCount <= store.maxCount * 2)
    }
}

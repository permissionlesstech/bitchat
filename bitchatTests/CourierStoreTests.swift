//
// CourierStoreTests.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

struct CourierStoreTests {

    private static let baseDate = Date(timeIntervalSince1970: 1_750_000_000)

    private func makeStore(now: Date = baseDate) -> CourierStore {
        CourierStore(persistsToDisk: false, now: { now })
    }

    /// Store whose clock can be advanced by tests.
    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private func makeEnvelope(
        recipientKey: Data = Data(repeating: 0xB0, count: 32),
        sealedAt: Date = baseDate,
        lifetime: TimeInterval = 60 * 60,
        ciphertext: Data = Data((0..<96).map { _ in UInt8.random(in: 0...255) })
    ) -> CourierEnvelope {
        CourierEnvelope(
            recipientTag: CourierEnvelope.recipientTag(
                noiseStaticKey: recipientKey,
                epochDay: CourierEnvelope.epochDay(for: sealedAt)
            ),
            expiry: UInt64((sealedAt.timeIntervalSince1970 + lifetime) * 1000),
            ciphertext: ciphertext
        )
    }

    private let depositorA = Data(repeating: 0xA1, count: 32)
    private let depositorB = Data(repeating: 0xA2, count: 32)

    // MARK: - Deposit and handover

    @Test func depositThenTakeForRecipient() {
        let store = makeStore()
        let recipientKey = Data(repeating: 0xB0, count: 32)
        let envelope = makeEnvelope(recipientKey: recipientKey)

        #expect(store.deposit(envelope, from: depositorA))
        let taken = store.takeEnvelopes(for: recipientKey)
        #expect(taken == [envelope])
        // Handover removes the envelope.
        #expect(store.takeEnvelopes(for: recipientKey).isEmpty)
    }

    @Test func takeIgnoresOtherRecipients() {
        let store = makeStore()
        let envelope = makeEnvelope(recipientKey: Data(repeating: 0xB0, count: 32))
        store.deposit(envelope, from: depositorA)
        #expect(store.takeEnvelopes(for: Data(repeating: 0xCC, count: 32)).isEmpty)
        #expect(store.takeEnvelopes(for: Data(repeating: 0xB0, count: 32)).count == 1)
    }

    @Test func duplicateDepositIsIdempotent() {
        let store = makeStore()
        let recipientKey = Data(repeating: 0xB0, count: 32)
        let envelope = makeEnvelope(recipientKey: recipientKey)
        #expect(store.deposit(envelope, from: depositorA))
        #expect(store.deposit(envelope, from: depositorA))
        #expect(store.takeEnvelopes(for: recipientKey).count == 1)
    }

    // MARK: - Validity

    @Test func rejectsExpiredAndOversizedAndMalformed() {
        let store = makeStore()
        let expired = makeEnvelope(sealedAt: Self.baseDate.addingTimeInterval(-7200), lifetime: 3600)
        #expect(!store.deposit(expired, from: depositorA))

        let oversized = makeEnvelope(ciphertext: Data(repeating: 0, count: CourierEnvelope.maxCiphertextBytes + 1))
        #expect(!store.deposit(oversized, from: depositorA))

        let badTag = CourierEnvelope(
            recipientTag: Data(repeating: 0, count: 4),
            expiry: UInt64((Self.baseDate.timeIntervalSince1970 + 3600) * 1000),
            ciphertext: Data(repeating: 1, count: 16)
        )
        #expect(!store.deposit(badTag, from: depositorA))
    }

    @Test func rejectsExpiryBeyondPolicyLifetime() {
        let store = makeStore()
        let pinned = makeEnvelope(lifetime: 7 * 24 * 60 * 60)
        #expect(!store.deposit(pinned, from: depositorA))
    }

    // MARK: - Quotas

    @Test func perDepositorQuota() {
        let store = makeStore()
        for _ in 0..<CourierStore.Limits.maxPerDepositor {
            #expect(store.deposit(makeEnvelope(), from: depositorA))
        }
        #expect(!store.deposit(makeEnvelope(), from: depositorA))
        // A different depositor still has room.
        #expect(store.deposit(makeEnvelope(), from: depositorB))
    }

    @Test func totalQuotaEvictsOldestFirst() {
        let store = makeStore()
        let firstRecipient = Data(repeating: 0xD0, count: 32)
        let first = makeEnvelope(recipientKey: firstRecipient)
        store.deposit(first, from: depositorA)

        // Fill to the cap using distinct depositors to dodge the per-depositor quota.
        var deposited = 1
        var depositorByte: UInt8 = 1
        while deposited < CourierStore.Limits.maxEnvelopes + 1 {
            let depositor = Data(repeating: depositorByte, count: 32)
            for _ in 0..<CourierStore.Limits.maxPerDepositor where deposited < CourierStore.Limits.maxEnvelopes + 1 {
                #expect(store.deposit(makeEnvelope(), from: depositor))
                deposited += 1
            }
            depositorByte += 1
        }

        // The first envelope was evicted to make room.
        #expect(store.takeEnvelopes(for: firstRecipient).isEmpty)
    }

    // MARK: - Expiry over time

    @Test func expiredEnvelopesAreNotHandedOver() {
        let clock = Clock(Self.baseDate)
        let store = CourierStore(persistsToDisk: false, now: { clock.now })
        let recipientKey = Data(repeating: 0xB0, count: 32)
        store.deposit(makeEnvelope(recipientKey: recipientKey, lifetime: 3600), from: depositorA)

        clock.now = Self.baseDate.addingTimeInterval(7200)
        #expect(store.takeEnvelopes(for: recipientKey).isEmpty)
    }

    // MARK: - Panic wipe

    @Test func wipeDropsEverything() {
        let store = makeStore()
        let recipientKey = Data(repeating: 0xB0, count: 32)
        store.deposit(makeEnvelope(recipientKey: recipientKey), from: depositorA)
        store.wipe()
        #expect(store.takeEnvelopes(for: recipientKey).isEmpty)
    }

    // MARK: - Persistence

    @Test func persistsAndReloadsAcrossInstances() throws {
        // Uses the real on-disk location; clean up around the test.
        let first = CourierStore(persistsToDisk: true, now: { Self.baseDate })
        defer { first.wipe() }
        first.wipe()

        let recipientKey = Data(repeating: 0xE0, count: 32)
        let envelope = makeEnvelope(recipientKey: recipientKey)
        #expect(first.deposit(envelope, from: depositorA))

        let second = CourierStore(persistsToDisk: true, now: { Self.baseDate })
        #expect(second.takeEnvelopes(for: recipientKey) == [envelope])
    }
}

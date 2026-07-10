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

    @Test func rejectedPhysicalHandoverRetainsEnvelopeUntilAcceptedRetry() {
        let store = makeStore()
        let recipientKey = Data(repeating: 0xB0, count: 32)
        let envelope = makeEnvelope(recipientKey: recipientKey)
        #expect(store.deposit(envelope, from: depositorA))

        var rejectedOffers: [CourierEnvelope] = []
        let rejected = store.handoverEnvelopes(for: recipientKey) { offered in
            rejectedOffers.append(offered)
            return false
        }

        #expect(rejected == 0)
        #expect(rejectedOffers == [envelope])
        #expect(!store.isEmpty)

        var acceptedOffers: [CourierEnvelope] = []
        let accepted = store.handoverEnvelopes(for: recipientKey) { offered in
            acceptedOffers.append(offered)
            return true
        }
        #expect(accepted == 1)
        #expect(acceptedOffers == [envelope])
        #expect(store.isEmpty)
    }

    @Test func midTrainFragmentRejectionRetainsDurableEnvelope() {
        let store = makeStore()
        let recipientKey = Data(repeating: 0xB0, count: 32)
        let envelope = makeEnvelope(recipientKey: recipientKey)
        #expect(store.deposit(envelope, from: depositorA))

        var attemptedFragments: [Int] = []
        let accepted = store.handoverEnvelopes(for: recipientKey) { _ in
            BLEStrictFragmentAdmission.admitAll([0, 1, 2]) { fragment in
                attemptedFragments.append(fragment)
                return fragment != 1
            }
        }

        #expect(accepted == 0)
        #expect(attemptedFragments == [0, 1])
        #expect(!store.isEmpty)
        #expect(store.takeEnvelopes(for: recipientKey) == [envelope])
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
        for _ in 0..<CourierStore.Limits.maxPerFavoriteDepositor {
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
            for _ in 0..<CourierStore.Limits.maxPerFavoriteDepositor where deposited < CourierStore.Limits.maxEnvelopes + 1 {
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
        // Isolated on-disk location so the test never touches the real store.
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("courier-store-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("envelopes.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let first = CourierStore(persistsToDisk: true, fileURL: fileURL, now: { Self.baseDate })

        let recipientKey = Data(repeating: 0xE0, count: 32)
        let envelope = makeEnvelope(recipientKey: recipientKey)
        #expect(first.deposit(envelope, from: depositorA))

        let second = CourierStore(persistsToDisk: true, fileURL: fileURL, now: { Self.baseDate })
        #expect(second.takeEnvelopes(for: recipientKey) == [envelope])
    }

    @Test func protectedDataReadFailureDoesNotOverwriteDurableMailAndMergesOnRecovery() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("courier-protected-data-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("envelopes.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let durableRecipient = Data(repeating: 0xE1, count: 32)
        let wakeRecipient = Data(repeating: 0xE2, count: 32)
        let durableEnvelope = makeEnvelope(recipientKey: durableRecipient)
        let wakeEnvelope = makeEnvelope(recipientKey: wakeRecipient)
        let seed = CourierStore(persistsToDisk: true, fileURL: fileURL, now: { Self.baseDate })
        #expect(seed.deposit(durableEnvelope, from: depositorA))
        let durableBytes = try? Data(contentsOf: fileURL)

        var protectedDataUnavailable = true
        let restored = CourierStore(
            persistsToDisk: true,
            fileURL: fileURL,
            now: { Self.baseDate },
            readData: { url in
                if protectedDataUnavailable {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
                }
                return try Data(contentsOf: url)
            }
        )
        #expect(restored.deposit(wakeEnvelope, from: depositorB))

        // The locked wake accepted new work in memory but did not replace the
        // unreadable file with that partial view.
        #expect((try? Data(contentsOf: fileURL)) == durableBytes)

        protectedDataUnavailable = false
        restored.retryDeferredPersistence()

        let afterUnlock = CourierStore(persistsToDisk: true, fileURL: fileURL, now: { Self.baseDate })
        #expect(afterUnlock.takeEnvelopes(for: durableRecipient) == [durableEnvelope])
        #expect(afterUnlock.takeEnvelopes(for: wakeRecipient) == [wakeEnvelope])
    }

    // MARK: - Tiers (open couriering)

    @Test func verifiedTierGetsSmallerPerDepositorQuota() {
        let store = makeStore()
        for _ in 0..<CourierStore.Limits.maxPerVerifiedDepositor {
            #expect(store.deposit(makeEnvelope(), from: depositorA, tier: .verified))
        }
        #expect(!store.deposit(makeEnvelope(), from: depositorA, tier: .verified))
        // The same depositor promoted to favorite gets the larger quota.
        #expect(store.deposit(makeEnvelope(), from: depositorB, tier: .favorite))
    }

    @Test func verifiedPoolIsCappedIndependentlyOfFavorites() {
        let store = makeStore()
        var depositorByte: UInt8 = 1
        var accepted = 0
        while accepted < CourierStore.Limits.maxVerifiedEnvelopes {
            let depositor = Data(repeating: depositorByte, count: 32)
            for _ in 0..<CourierStore.Limits.maxPerVerifiedDepositor where accepted < CourierStore.Limits.maxVerifiedEnvelopes {
                #expect(store.deposit(makeEnvelope(), from: depositor, tier: .verified))
                accepted += 1
            }
            depositorByte += 1
        }
        // Verified pool full: another verified deposit is rejected...
        #expect(!store.deposit(makeEnvelope(), from: Data(repeating: 0xEE, count: 32), tier: .verified))
        // ...but favorites still have their share.
        #expect(store.deposit(makeEnvelope(), from: depositorA, tier: .favorite))
    }

    @Test func overflowEvictsVerifiedTierBeforeFavorites() {
        let store = makeStore()
        let favoriteRecipient = Data(repeating: 0xD0, count: 32)
        let verifiedRecipient = Data(repeating: 0xD1, count: 32)
        // Oldest envelope is a favorite deposit; a verified one follows.
        #expect(store.deposit(makeEnvelope(recipientKey: favoriteRecipient), from: depositorA, tier: .favorite))
        #expect(store.deposit(makeEnvelope(recipientKey: verifiedRecipient), from: depositorB, tier: .verified))

        // Fill to the total cap with favorite deposits from distinct depositors.
        var depositorByte: UInt8 = 10
        var count = 2
        while count < CourierStore.Limits.maxEnvelopes {
            let depositor = Data(repeating: depositorByte, count: 32)
            for _ in 0..<CourierStore.Limits.maxPerFavoriteDepositor where count < CourierStore.Limits.maxEnvelopes {
                #expect(store.deposit(makeEnvelope(), from: depositor, tier: .favorite))
                count += 1
            }
            depositorByte += 1
        }

        // The next favorite deposit evicts the verified envelope, not the
        // older favorite one.
        #expect(store.deposit(makeEnvelope(), from: Data(repeating: 0xEF, count: 32), tier: .favorite))
        #expect(store.takeEnvelopes(for: verifiedRecipient).isEmpty)
        #expect(store.takeEnvelopes(for: favoriteRecipient).count == 1)
    }

    @Test func verifiedDepositIsRejectedWhenStoreIsFullOfFavorites() {
        let store = makeStore()
        var depositorByte: UInt8 = 10
        var count = 0
        while count < CourierStore.Limits.maxEnvelopes {
            let depositor = Data(repeating: depositorByte, count: 32)
            for _ in 0..<CourierStore.Limits.maxPerFavoriteDepositor where count < CourierStore.Limits.maxEnvelopes {
                #expect(store.deposit(makeEnvelope(), from: depositor, tier: .favorite))
                count += 1
            }
            depositorByte += 1
        }
        // A verified deposit must not displace favorite-tier mail.
        #expect(!store.deposit(makeEnvelope(), from: Data(repeating: 0xEE, count: 32), tier: .verified))
        // A favorite deposit still can (oldest-favorite eviction).
        #expect(store.deposit(makeEnvelope(), from: Data(repeating: 0xEF, count: 32), tier: .favorite))
    }

    // MARK: - Spray-and-wait

    @Test func sprayHalvesBudgetAndSkipsIneligibleCouriers() {
        let store = makeStore()
        let recipientKey = Data(repeating: 0xB0, count: 32)
        let envelope = makeEnvelope(recipientKey: recipientKey).withCopies(4)
        #expect(store.deposit(envelope, from: depositorA))

        // The recipient themselves never gets a spray copy (handover path).
        #expect(store.takeSprayCopies(for: recipientKey).isEmpty)
        // Neither does the depositor.
        #expect(store.takeSprayCopies(for: depositorA).isEmpty)

        // A fresh courier gets half the budget.
        let courierX = Data(repeating: 0xC1, count: 32)
        let sprayedToX = store.takeSprayCopies(for: courierX)
        #expect(sprayedToX.count == 1)
        #expect(sprayedToX.first?.copies == 2)
        // Same courier again: no double spend.
        #expect(store.takeSprayCopies(for: courierX).isEmpty)

        // Next courier gets half the remainder (2 -> give 1, keep 1).
        let courierY = Data(repeating: 0xC2, count: 32)
        let sprayedToY = store.takeSprayCopies(for: courierY)
        #expect(sprayedToY.count == 1)
        #expect(sprayedToY.first?.copies == 1)

        // Budget exhausted (carry-only): nothing left to spray.
        #expect(store.takeSprayCopies(for: Data(repeating: 0xC3, count: 32)).isEmpty)
        // The carried original is still deliverable.
        #expect(store.takeEnvelopes(for: recipientKey).count == 1)
    }

    @Test func rejectedSprayTransferPreservesBudgetAndCourierEligibility() {
        let store = makeStore()
        let recipientKey = Data(repeating: 0xB0, count: 32)
        let courier = Data(repeating: 0xC1, count: 32)
        #expect(store.deposit(makeEnvelope(recipientKey: recipientKey).withCopies(4), from: depositorA))

        var rejectedOffers: [CourierEnvelope] = []
        let rejected = store.transferSprayCopies(to: courier) { offered in
            rejectedOffers.append(offered)
            return false
        }

        #expect(rejected == 0)
        #expect(rejectedOffers.map(\.copies) == [2])

        // The same courier remains eligible and receives the original half
        // budget, proving neither `copies` nor `sprayedTo` changed on failure.
        let acceptedRetry = store.takeSprayCopies(for: courier)
        #expect(acceptedRetry.map(\.copies) == [2])
        let nextCourier = store.takeSprayCopies(for: Data(repeating: 0xC2, count: 32))
        #expect(nextCourier.map(\.copies) == [1])
    }

    @Test func carryOnlyEnvelopesAreNeverSprayed() {
        let store = makeStore()
        #expect(store.deposit(makeEnvelope(), from: depositorA))
        #expect(store.takeSprayCopies(for: Data(repeating: 0xC1, count: 32)).isEmpty)
    }

    @Test func duplicateDepositKeepsLargerSprayBudget() {
        let store = makeStore()
        let recipientKey = Data(repeating: 0xB0, count: 32)
        let ciphertext = Data(repeating: 0x42, count: 96)
        let carryOnly = makeEnvelope(recipientKey: recipientKey, ciphertext: ciphertext)
        #expect(store.deposit(carryOnly, from: depositorA))
        #expect(store.deposit(carryOnly.withCopies(4), from: depositorB))

        let sprayed = store.takeSprayCopies(for: Data(repeating: 0xC1, count: 32))
        #expect(sprayed.first?.copies == 2)
    }

    @Test func duplicateReplayCannotReplenishSpentSprayBudget() {
        let store = makeStore()
        let recipientKey = Data(repeating: 0xB0, count: 32)
        let original = makeEnvelope(recipientKey: recipientKey).withCopies(8)
        #expect(store.deposit(original, from: depositorA))

        let courierX = Data(repeating: 0xC1, count: 32)
        let courierY = Data(repeating: 0xC2, count: 32)
        let courierZ = Data(repeating: 0xC3, count: 32)
        let courierW = Data(repeating: 0xC4, count: 32)
        #expect(store.takeSprayCopies(for: courierX).map(\.copies) == [4])

        // Replaying the original signed deposit still accepts idempotently,
        // but it cannot reset the local branch from 4 copies back to 8.
        #expect(store.deposit(original, from: depositorA))
        #expect(store.takeSprayCopies(for: courierY).map(\.copies) == [2])
        #expect(store.deposit(original, from: depositorA))
        #expect(store.takeSprayCopies(for: courierZ).map(\.copies) == [1])
        #expect(store.deposit(original, from: depositorA))
        #expect(store.takeSprayCopies(for: courierW).isEmpty)
    }

    // MARK: - Remote handover (relayed announces)

    @Test func remoteHandoverIsNonDestructiveAndCooledDown() {
        let store = makeStore()
        let recipientKey = Data(repeating: 0xB0, count: 32)
        let envelope = makeEnvelope(recipientKey: recipientKey).withCopies(4)
        #expect(store.deposit(envelope, from: depositorA))

        let first = store.envelopesForRemoteHandover(recipientNoiseKey: recipientKey, cooldown: 600)
        #expect(first.count == 1)
        // The flooded copy carries no spray budget.
        #expect(first.first?.copies == 1)
        // Non-destructive: the envelope is still carried...
        #expect(!store.isEmpty)
        // ...and inside the cooldown it is not re-flooded.
        #expect(store.envelopesForRemoteHandover(recipientNoiseKey: recipientKey, cooldown: 600).isEmpty)
        // A direct encounter still hands it over destructively.
        #expect(store.takeEnvelopes(for: recipientKey).count == 1)
        #expect(store.isEmpty)
    }

    // MARK: - Legacy persistence

    @Test func legacyPersistedFileLoadsAsFavoriteCarryOnly() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("courier-legacy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        // Envelope persisted by a pre-tier/pre-spray build: no tier, copies,
        // or spray bookkeeping fields.
        let recipientKey = Data(repeating: 0xB0, count: 32)
        let envelope = makeEnvelope(recipientKey: recipientKey)
        let legacy: [[String: Any]] = [[
            "recipientTag": envelope.recipientTag.base64EncodedString(),
            "expiry": envelope.expiry,
            "ciphertext": envelope.ciphertext.base64EncodedString(),
            "depositorNoiseKey": depositorA.base64EncodedString(),
            "storedAt": Self.baseDate.timeIntervalSinceReferenceDate
        ]]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        try data.write(to: fileURL)

        let store = CourierStore(persistsToDisk: true, fileURL: fileURL, now: { Self.baseDate })
        // Carry-only, so never sprayed...
        #expect(store.takeSprayCopies(for: Data(repeating: 0xC1, count: 32)).isEmpty)
        // ...but still delivered on encounter.
        #expect(store.takeEnvelopes(for: recipientKey).count == 1)
    }
}

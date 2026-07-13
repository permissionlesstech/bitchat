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

    // MARK: - Deferred spray offers (courier-ack path)

    /// Commits the offered copy (the directed transport always accepts) and
    /// returns the number of copies handed to `courier` for the single sprayable
    /// envelope these tests deposit — i.e. the value the old
    /// `offerSprayCopies(for:).first?.copies` exposed, or 0 if nothing was
    /// offered. Note `offerSprayCopies` itself returns the *count of envelopes*
    /// committed (like `transferSprayCopies`); the per-envelope copy split lives
    /// in the `CourierEnvelope` passed to the accept closure, which is what we
    /// capture here. This drives the send gate with a send that never drops, so
    /// the committed budget matches the optimistic split — these cases exercise
    /// the pending-offer bookkeeping (confirm/cancel), while the send gate itself
    /// is exercised by `offerWithRefusedSendCommitsNothing`.
    private func offerAll(_ store: CourierStore, to courier: Data) -> Int {
        var given = 0
        let committedEnvelopes = store.offerSprayCopies(to: courier) { copy in
            given = Int(copy.copies)
            return true
        }
        // These tests deposit exactly one sprayable envelope, so a commit means
        // `given` holds its split; a no-op (nothing eligible, or commit-time
        // revalidation refused) means zero copies actually left the giver.
        return committedEnvelopes == 0 ? 0 : given
    }

    /// The ack-capable path is send-gated exactly like `transferSprayCopies`: a
    /// copy whose directed send the transport refuses (e.g. the link dropped
    /// before the write landed) is never charged — no budget spent, no
    /// `sprayedTo` marker, no pending restore entry. This is the link-drop
    /// protection an ack-capable taker inherits from the send gate, on top of the
    /// decline recovery below.
    @Test func offerWithRefusedSendCommitsNothing() {
        let store = makeStore()
        let recipientKey = Data(repeating: 0xB0, count: 32)
        let envelope = makeEnvelope(recipientKey: recipientKey).withCopies(4)
        #expect(store.deposit(envelope, from: depositorA))
        let hash = CourierStore.ciphertextHash(envelope.ciphertext)
        let courierA = Data(repeating: 0xC1, count: 32)

        // Transport refuses the send: nothing commits.
        #expect(store.offerSprayCopies(to: courierA) { _ in false } == 0)

        // A receipt referencing the never-committed offer is a no-op — there is
        // no pending entry to restore or clear, so the budget cannot inflate.
        store.cancelSpray(ciphertextHash: hash, courierNoiseKey: courierA)
        store.confirmSpray(courierNoiseKey: courierA, ciphertextHash: hash)

        // Budget untouched: A was never marked sprayed, so a subsequent accepted
        // offer still gets the full half-split (2) of the intact 4.
        #expect(offerAll(store, to: courierA) == 2)
    }

    @Test func committedOfferSpendsOnceAndConfirmIsANoOp() {
        let store = makeStore()
        let recipientKey = Data(repeating: 0xB0, count: 32)
        let envelope = makeEnvelope(recipientKey: recipientKey).withCopies(4)
        #expect(store.deposit(envelope, from: depositorA))
        let hash = CourierStore.ciphertextHash(envelope.ciphertext)
        let courierA = Data(repeating: 0xC1, count: 32)

        // A committed offer spends half the budget (same split as the optimistic
        // path) and records a pending restore entry.
        #expect(offerAll(store, to: courierA) == 2) // half of 4

        // The spend is durable at commit time: `confirmSpray` (ack or the
        // assume-delivered timeout) only clears the pending restore entry — it
        // must not decrement again.
        store.confirmSpray(courierNoiseKey: courierA, ciphertextHash: hash)

        // A is recorded as sprayed, so a repeat offer to A is refused.
        #expect(offerAll(store, to: courierA) == 0)

        // A fresh courier gets half of the post-offer remainder (2 → 1), not
        // half of the original 4 — the decrement landed exactly once, and the
        // confirm added nothing.
        let courierC = Data(repeating: 0xC3, count: 32)
        let sprayedToC = store.takeSprayCopies(for: courierC)
        #expect(sprayedToC.count == 1)
        #expect(sprayedToC.first?.copies == 1)
    }

    @Test func offerThenDeclineRestoresBudgetForOtherCouriers() {
        let store = makeStore()
        let recipientKey = Data(repeating: 0xB0, count: 32)
        let envelope = makeEnvelope(recipientKey: recipientKey).withCopies(4)
        #expect(store.deposit(envelope, from: depositorA))
        let hash = CourierStore.ciphertextHash(envelope.ciphertext)
        let courierA = Data(repeating: 0xC1, count: 32)

        #expect(offerAll(store, to: courierA) == 2) // committed: budget is now 2

        // A signed decline (the giver's `cancelSpray`) re-adds the offered
        // copies — this is the whole fix: a courier that deterministically
        // refuses the copy no longer costs the giver its budget.
        store.cancelSpray(ciphertextHash: hash, courierNoiseKey: courierA)

        // A is deliberately kept in `sprayedTo`, so the giver will NOT re-offer
        // the same envelope to the courier that just declined it (this is what
        // closes the receipt-replay hole — see replayedDeclineAfterReoffer...).
        #expect(offerAll(store, to: courierA) == 0)

        // But the budget really was restored: a *different* courier now gets
        // half of the full 4 (2), proving the declined copies went back into
        // the pool rather than being destroyed.
        let courierB = Data(repeating: 0xC2, count: 32)
        #expect(offerAll(store, to: courierB) == 2)
    }

    /// Regression for Codex's send/commit-race finding. Over `.withoutResponse`
    /// the sprayed copy is put on the wire *inside* the accept closure, before
    /// `offerSprayCopies` commits the pending entry. A taker that deterministically
    /// refuses can therefore have its signed decline handled *before* the commit.
    /// This reproduces that exact interleaving by calling `cancelSpray` from
    /// inside the accept closure — a decline that races ahead of the commit — and
    /// pins the safe outcome: the racing decline finds no pending entry (returns
    /// false, so it can neither falsely restore nor inflate), the spend still
    /// commits (degrading to the send-gated baseline, never worse), and the
    /// committed entry is NOT orphaned — a later `confirmSpray` (the armed
    /// timeout, which BLEService deliberately leaves alive when `cancelSpray`
    /// returns false) still reaps it. Restoring in that window is impossible
    /// without committing before the send, which would trade this benign
    /// degrade-to-baseline for a crash-before-send loss *below* the baseline.
    @Test func declineRacingAheadOfCommitDegradesToBaselineWithoutOrphaning() {
        let store = makeStore()
        let recipientKey = Data(repeating: 0xB0, count: 32)
        let envelope = makeEnvelope(recipientKey: recipientKey).withCopies(4)
        #expect(store.deposit(envelope, from: depositorA))
        let hash = CourierStore.ciphertextHash(envelope.ciphertext)
        let courierA = Data(repeating: 0xC1, count: 32)

        var racedRestore: Bool?
        var given = 0
        let committed = store.offerSprayCopies(to: courierA) { copy in
            given = Int(copy.copies)
            // The copy is now "on the wire"; a fast decline is handled before the
            // commit block inserts the pending entry.
            racedRestore = store.cancelSpray(ciphertextHash: hash, courierNoiseKey: courierA)
            return true
        }

        // The racing decline saw no pending entry: it must not restore (which
        // would inflate once the commit then spends).
        #expect(racedRestore == false)
        // The offer still committed the send-gated spend of half the budget.
        #expect(committed == 1)
        #expect(given == 2)

        // The committed entry was NOT orphaned by the racing decline: the armed
        // timeout's `confirmSpray` still finds and clears it (returns true) —
        // exactly what BLEService relies on when it leaves the timeout alive on
        // the decline's false return.
        #expect(store.confirmSpray(courierNoiseKey: courierA, ciphertextHash: hash) == true)

        // Spend stands (baseline): courierA is in `sprayedTo` and the budget
        // dropped to 2, so a fresh courier gets half of 2, not half of 4.
        #expect(offerAll(store, to: courierA) == 0)
        let courierC = Data(repeating: 0xC3, count: 32)
        #expect(store.takeSprayCopies(for: courierC).first?.copies == 1)
    }

    /// The load-bearing regression for Codex's copy-inflation finding: when a
    /// taker stores the copy but its ack is lost, the spend was already
    /// committed durably at send-accept time, and the taker is already recorded
    /// in `sprayedTo`. The assume-delivered timeout (`confirmSpray`) merely
    /// clears the pending restore entry — it does not restore. The giver can
    /// therefore never re-spray the copy the taker already carries, so total
    /// copies stay bounded by the original budget — no inflation over a lossy
    /// one-way link.
    @Test func ackLossTimeoutCommitsAndCannotReinflate() {
        let store = makeStore()
        let recipientKey = Data(repeating: 0xB0, count: 32)
        let envelope = makeEnvelope(recipientKey: recipientKey).withCopies(4)
        #expect(store.deposit(envelope, from: depositorA))
        let hash = CourierStore.ciphertextHash(envelope.ciphertext)
        let courierA = Data(repeating: 0xC1, count: 32)

        #expect(offerAll(store, to: courierA) == 2) // taker physically stores these 2

        // Ack is lost; the timeout fires. In BLEService the timeout invokes
        // exactly this call — it drops the ability to restore, leaving the
        // durable send-accept-time spend in place.
        store.confirmSpray(courierNoiseKey: courierA, ciphertextHash: hash)

        // Cannot re-offer to the taker that already holds the copy.
        #expect(offerAll(store, to: courierA) == 0)

        // Total handed out is conserved: taker holds 2, remaining budget is
        // 4 - 2 = 2, so a fresh courier gets exactly 1 (half of 2), never a
        // second half of the undiminished 4.
        let courierC = Data(repeating: 0xC3, count: 32)
        let sprayedToC = store.takeSprayCopies(for: courierC)
        #expect(sprayedToC.first?.copies == 1)
        // Drain to prove no underflow / no phantom copies: 4 - 2 - 1 = 1 left
        // (carry-only), so nothing more can be sprayed.
        let courierD = Data(repeating: 0xC4, count: 32)
        #expect(store.takeSprayCopies(for: courierD).isEmpty)
    }

    @Test func repeatOfferBeforeAckIsBlockedBySprayedTo() {
        let store = makeStore()
        let recipientKey = Data(repeating: 0xB0, count: 32)
        let envelope = makeEnvelope(recipientKey: recipientKey).withCopies(4)
        #expect(store.deposit(envelope, from: depositorA))
        let hash = CourierStore.ciphertextHash(envelope.ciphertext)
        let courierA = Data(repeating: 0xC1, count: 32)

        #expect(offerAll(store, to: courierA) == 2)

        // The first offer committed A into `sprayedTo`, so a second announce
        // from the same courier before its ack lands wins no second offer for
        // this envelope (the announce-repeat race, closed by commit-time
        // revalidation).
        #expect(offerAll(store, to: courierA) == 0)

        store.confirmSpray(courierNoiseKey: courierA, ciphertextHash: hash)

        let courierC = Data(repeating: 0xC3, count: 32)
        let before = store.takeSprayCopies(for: courierC)
        #expect(before.count == 1)
        #expect(before.first?.copies == 1) // half of the post-offer remainder (2)

        // A duplicate/late ack (second confirm) is a harmless no-op.
        store.confirmSpray(courierNoiseKey: courierA, ciphertextHash: hash)

        // If the duplicate confirm had decremented again, budget would be
        // exhausted and a fresh courier would see nothing left to spray.
        let courierD = Data(repeating: 0xC4, count: 32)
        #expect(store.takeSprayCopies(for: courierD).isEmpty)
    }

    @Test func lateAckAfterDeclineIsANoOp() {
        let store = makeStore()
        let recipientKey = Data(repeating: 0xB0, count: 32)
        let envelope = makeEnvelope(recipientKey: recipientKey).withCopies(4)
        #expect(store.deposit(envelope, from: depositorA))
        let hash = CourierStore.ciphertextHash(envelope.ciphertext)
        let courierA = Data(repeating: 0xC1, count: 32)

        #expect(offerAll(store, to: courierA) == 2)
        // The taker declined; the giver restored the budget.
        store.cancelSpray(ciphertextHash: hash, courierNoiseKey: courierA)

        // A stray/forged ack arrives after the decline already consumed the
        // offer; it must not resurrect and spend it (a forged ack cannot
        // override a decline). The pending entry is gone, so it's a no-op.
        store.confirmSpray(courierNoiseKey: courierA, ciphertextHash: hash)

        // Budget is fully intact: a different courier still sees the original
        // split (A itself stays in `sprayedTo`, so it isn't re-offered).
        let courierB = Data(repeating: 0xC2, count: 32)
        #expect(offerAll(store, to: courierB) == 2)
    }

    @Test func concurrentOffersToDifferentCouriersConserveCopies() {
        let store = makeStore()
        let recipientKey = Data(repeating: 0xB0, count: 32)
        let envelope = makeEnvelope(recipientKey: recipientKey).withCopies(8)
        #expect(store.deposit(envelope, from: depositorA))
        let hash = CourierStore.ciphertextHash(envelope.ciphertext)
        let courierA = Data(repeating: 0xC1, count: 32)
        let courierB = Data(repeating: 0xC2, count: 32)

        #expect(offerAll(store, to: courierA) == 4) // half of 8, budget now 4

        // B halves the *live* budget, which A's offer already decremented to 4,
        // so B gets 2 — offers can never jointly overcommit because each spends
        // synchronously in turn (no reservation arithmetic needed).
        #expect(offerAll(store, to: courierB) == 2)

        store.confirmSpray(courierNoiseKey: courierA, ciphertextHash: hash)
        store.confirmSpray(courierNoiseKey: courierB, ciphertextHash: hash)

        // Both are now recorded as sprayed.
        #expect(offerAll(store, to: courierA) == 0)
        #expect(offerAll(store, to: courierB) == 0)

        // Drain the remainder to prove copies never underflowed: 8 - 4 - 2 =
        // 2 remaining, half of that is 1.
        let courierD = Data(repeating: 0xC4, count: 32)
        let drained = store.takeSprayCopies(for: courierD)
        #expect(drained.count == 1)
        #expect(drained.first?.copies == 1)
    }

    @Test func oldAndNewPathsShareOneLiveBudgetAndConserveCopies() {
        let store = makeStore()
        let recipientKey = Data(repeating: 0xB0, count: 32)
        let envelope = makeEnvelope(recipientKey: recipientKey).withCopies(8)
        #expect(store.deposit(envelope, from: depositorA))
        let hash = CourierStore.ciphertextHash(envelope.ciphertext)
        let courierA = Data(repeating: 0xC1, count: 32)
        let courierB = Data(repeating: 0xC2, count: 32)
        let courierC = Data(repeating: 0xC3, count: 32)

        #expect(offerAll(store, to: courierA) == 4) // given 4, budget now 4
        #expect(offerAll(store, to: courierB) == 2) // half of live 4, budget now 2

        // The old (non-ack) path halves the SAME live budget the offers already
        // decremented — copies is 2, so C gets 1, not half of the raw 8. Both
        // paths spend one shared, synchronously-decremented budget.
        let takenByC = store.takeSprayCopies(for: courierC)
        #expect(takenByC.count == 1)
        let givenC = takenByC.first!.copies
        #expect(givenC == 1)

        store.confirmSpray(courierNoiseKey: courierA, ciphertextHash: hash)
        store.confirmSpray(courierNoiseKey: courierB, ciphertextHash: hash)

        // Conservation: A(4) + B(2) + C(1) all spent, leaving 1 carry-only copy;
        // nothing more can be sprayed -- no inflation, no underflow.
        let courierD = Data(repeating: 0xC4, count: 32)
        let remainder = store.takeSprayCopies(for: courierD)
        #expect(remainder.isEmpty) // nothing left: 8 - 4 - 2 - 1 = 1 (carry-only)
        #expect(givenC + 4 + 2 + 1 == 8)
    }

    @Test func wipeClearsPendingSoStaleReceiptsCannotInflate() {
        let store = makeStore()
        let recipientKey = Data(repeating: 0xB0, count: 32)
        let ciphertext = Data(repeating: 0x77, count: 96)
        let envelope = makeEnvelope(recipientKey: recipientKey, ciphertext: ciphertext).withCopies(4)
        #expect(store.deposit(envelope, from: depositorA))
        let hash = CourierStore.ciphertextHash(envelope.ciphertext)
        let courierA = Data(repeating: 0xC1, count: 32)

        #expect(offerAll(store, to: courierA) == 2) // committed; pending{A:2}

        store.wipe()

        // Re-deposit an identical-copies envelope (same ciphertext/budget) so
        // the stale receipts below have a matching envelope to (not) act on.
        #expect(store.deposit(envelope, from: depositorA))

        // The dangerous stale receipt is a DECLINE: if `cancelSpray` didn't guard
        // on the (wiped) pending entry it would re-add 2 copies to the freshly
        // re-deposited envelope → 4 + 2 = 6 = inflation, and clear a `sprayedTo`
        // it never set. It must be a no-op.
        store.cancelSpray(ciphertextHash: hash, courierNoiseKey: courierA)
        // A stale confirm is likewise a no-op (no pending to clear).
        store.confirmSpray(courierNoiseKey: courierA, ciphertextHash: hash)

        // Budget is exactly the re-deposited 4: A gets the same fresh half-split
        // (2) a brand-new envelope would — not half of an inflated 6 (3).
        #expect(offerAll(store, to: courierA) == 2)
    }

    @Test func copyConservationHoldsAcrossOffersConfirmsAndCancels() {
        let store = makeStore()
        let recipientKey = Data(repeating: 0xB0, count: 32)
        let originalCopies: UInt8 = 8
        let envelope = makeEnvelope(recipientKey: recipientKey).withCopies(originalCopies)
        #expect(store.deposit(envelope, from: depositorA))
        let hash = CourierStore.ciphertextHash(envelope.ciphertext)

        var confirmedTotal: UInt8 = 0
        var courierByte: UInt8 = 0xC1
        func nextCourier() -> Data {
            let key = Data(repeating: courierByte, count: 32)
            courierByte += 1
            return key
        }

        // Offer + confirm.
        let courierA = nextCourier()
        let offeredA = offerAll(store, to: courierA)
        #expect(offeredA > 0)
        confirmedTotal += UInt8(offeredA)
        store.confirmSpray(courierNoiseKey: courierA, ciphertextHash: hash)

        // Offer + cancel: contributes nothing to the confirmed total.
        let courierB = nextCourier()
        #expect(offerAll(store, to: courierB) > 0)
        store.cancelSpray(ciphertextHash: hash, courierNoiseKey: courierB)

        // Offer + confirm again.
        let courierC = nextCourier()
        let offeredC = offerAll(store, to: courierC)
        #expect(offeredC > 0)
        confirmedTotal += UInt8(offeredC)
        store.confirmSpray(courierNoiseKey: courierC, ciphertextHash: hash)

        // Drain whatever spray budget remains via the old optimistic path
        // so the final carried copy count is exposed as exactly 1.
        while true {
            let courier = nextCourier()
            let taken = store.takeSprayCopies(for: courier)
            guard let copy = taken.first else { break }
            confirmedTotal += copy.copies
        }

        // Conservation: everything actually confirmed/taken, plus the
        // single carry-only copy left behind, equals the original budget.
        #expect(confirmedTotal + 1 == originalCopies)
    }

    /// The load-bearing regression for Codex's *second* finding (restart
    /// inflation): the spend is durable at send-accept time, so a process
    /// restart between offer-delivery and ack/timeout can NOT resurrect the
    /// budget the taker already carries. On reload the giver sees the decremented
    /// `copies` and the persisted `sprayedTo`, so it can neither re-offer the
    /// taker nor hand a fresh courier half of the pre-offer budget. A decline
    /// that arrives after the restart (pending map is memory-only, so it's empty)
    /// simply fails to restore — degrading to the optimistic path, never
    /// inflating.
    @Test func restartBetweenOfferAndAckCannotReinflate() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("courier-spray-restart-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("store.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let recipientKey = Data(repeating: 0xB0, count: 32)
        let envelope = makeEnvelope(recipientKey: recipientKey).withCopies(4)
        let hash = CourierStore.ciphertextHash(envelope.ciphertext)
        let courierA = Data(repeating: 0xC1, count: 32)

        let giver = CourierStore(persistsToDisk: true, fileURL: fileURL, now: { Self.baseDate })
        #expect(giver.deposit(envelope, from: depositorA))
        #expect(offerAll(giver, to: courierA) == 2) // durably spent + persisted; taker holds these 2

        // Process dies before the ack or the 10s timeout — reload from disk.
        let afterRestart = CourierStore(persistsToDisk: true, fileURL: fileURL, now: { Self.baseDate })

        // The taker A is still in the persisted `sprayedTo`, so the giver cannot
        // re-offer A the copy it already carries.
        #expect(offerAll(afterRestart, to: courierA) == 0)

        // A fresh courier gets half of the persisted remainder (2 → 1), never a
        // second half of the pre-offer 4 — the restart did not inflate copies.
        let courierC = Data(repeating: 0xC3, count: 32)
        let sprayedToC = afterRestart.takeSprayCopies(for: courierC)
        #expect(sprayedToC.first?.copies == 1)

        // A decline that arrives after the restart finds no pending entry (the
        // map didn't survive), so it cannot restore — the durable spend stands.
        afterRestart.cancelSpray(ciphertextHash: hash, courierNoiseKey: courierA)
        let courierD = Data(repeating: 0xC4, count: 32)
        #expect(afterRestart.takeSprayCopies(for: courierD).isEmpty) // 4-2-1 = 1, carry-only
    }

    /// The load-bearing regression for Codex's *third* finding (receipt replay
    /// across re-offer): a stale/replayed signed decline from an earlier offer
    /// must not restore budget against a later state. Because a declined courier
    /// is kept in `sprayedTo`, the giver never re-offers it the same envelope, so
    /// there is never a second pending offer for the same (envelope, courier)
    /// pair for a stale receipt to cross-attribute to — the replay window the
    /// finding needs is never reopened.
    @Test func replayedDeclineAfterReofferCannotInflate() {
        let store = makeStore()
        let recipientKey = Data(repeating: 0xB0, count: 32)
        let envelope = makeEnvelope(recipientKey: recipientKey).withCopies(4)
        #expect(store.deposit(envelope, from: depositorA))
        let hash = CourierStore.ciphertextHash(envelope.ciphertext)
        let courierA = Data(repeating: 0xC1, count: 32)

        // Offer #1 to A, then A deterministically declines: budget restored to 4.
        #expect(offerAll(store, to: courierA) == 2)
        store.cancelSpray(ciphertextHash: hash, courierNoiseKey: courierA)

        // The giver will NOT re-offer A the same envelope — the window a stale
        // decline needs (a fresh pending entry for the same pair) never opens.
        #expect(offerAll(store, to: courierA) == 0)

        // A replayed/delayed decline from offer #1 (past packet-dedup expiry or
        // after a restart) now finds no matching pending entry and cannot
        // inflate: budget is still exactly 4, so a different courier gets half
        // of 4 (2), never half of an inflated 6 (3).
        store.cancelSpray(ciphertextHash: hash, courierNoiseKey: courierA)
        let courierB = Data(repeating: 0xC2, count: 32)
        #expect(offerAll(store, to: courierB) == 2)

        // Drive the mirror too: a replayed/late ack after the decline is also a
        // no-op — it can neither spend nor destroy the restored budget.
        store.confirmSpray(courierNoiseKey: courierA, ciphertextHash: hash)
        let courierC = Data(repeating: 0xC3, count: 32)
        // Budget after B's offer is 4 - 2 = 2, so C gets 1; if the stale ack had
        // corrupted state, this split would differ.
        #expect(store.takeSprayCopies(for: courierC).first?.copies == 1)
    }

    /// Regression for Codex's redeposit cross-attribution finding. `cancelSpray`
    /// locates the record to restore by the receipt's ciphertext hash, but a hash
    /// is not identity across a remove+redeposit. Delivering the sprayed record
    /// (handover removes it — likewise prune/eviction) drops it while its pending
    /// offer is still outstanding; re-depositing the same ciphertext then appends
    /// a *fresh* record with an empty `sprayedTo` (deposit dedups only against
    /// carried envelopes). A stale decline from the deleted generation must not
    /// restore its copies onto that brand-new deposit. The `sprayedTo.contains`
    /// gate in `cancelSpray` pins the restore to the exact generation the courier
    /// was sprayed from, so this cross-generation replay is a consumed no-op.
    @Test func staleDeclineAfterRedepositCannotInflateFreshRecord() {
        let store = makeStore()
        let recipientKey = Data(repeating: 0xB0, count: 32)
        let envelope = makeEnvelope(recipientKey: recipientKey).withCopies(4)
        #expect(store.deposit(envelope, from: depositorA))
        let hash = CourierStore.ciphertextHash(envelope.ciphertext)
        let courierA = Data(repeating: 0xC1, count: 32)

        // Offer to A: budget 4 → 2, A recorded in `sprayedTo`, pending(A, hash)
        // still outstanding.
        #expect(offerAll(store, to: courierA) == 2)

        // The remaining copies are handed to the actual recipient, which REMOVES
        // the carried record — but nothing clears A's outstanding pending offer.
        #expect(store.takeEnvelopes(for: recipientKey).count == 1)
        #expect(store.isEmpty)

        // The depositor re-sends the same envelope. Dedup matches only carried
        // envelopes, so this appends a brand-new record: full budget 4, empty
        // `sprayedTo` (A was never sprayed from *this* generation).
        #expect(store.deposit(envelope, from: depositorA))

        // A's late/replayed decline from the deleted generation arrives. It
        // consumes the stale pending entry but must NOT restore onto the fresh
        // record — A isn't in its `sprayedTo`, so the hash match is rejected.
        store.cancelSpray(ciphertextHash: hash, courierNoiseKey: courierA)

        // No inflation: the fresh record still holds exactly its deposited 4, so a
        // courier gets half of 4 (2). Pre-fix the stale decline restored 4 + 2 = 6
        // and this split would be 3.
        let courierB = Data(repeating: 0xC2, count: 32)
        #expect(offerAll(store, to: courierB) == 2)
    }

    /// Regression for Codex's round-3 finding: the `sprayedTo` gate alone does not
    /// close the redeposit replay if the SAME courier is re-offered from the fresh
    /// generation. After handover removes the record, a same-ciphertext redeposit
    /// appends a fresh record with empty `sprayedTo`; re-offering A would insert it
    /// into the fresh `sprayedTo`, and then a stale decline from the deleted
    /// generation passes `sprayedTo.contains(A)` and inflates a copy A already
    /// holds. The offer-time pending-existence guard closes this: A's pending offer
    /// outlives its removed record (pending is memory-only, cleared only by
    /// ack/decline/timeout), so A is INELIGIBLE for a fresh offer while it is live —
    /// A is never sprayed from the new generation, and the stale decline consumes
    /// its pending entry as a no-op.
    @Test func staleDeclineAfterRedepositAndSameCourierReofferCannotInflate() {
        let store = makeStore()
        let recipientKey = Data(repeating: 0xB0, count: 32)
        let envelope = makeEnvelope(recipientKey: recipientKey).withCopies(4)
        #expect(store.deposit(envelope, from: depositorA))
        let hash = CourierStore.ciphertextHash(envelope.ciphertext)
        let courierA = Data(repeating: 0xC1, count: 32)

        // Offer to A: budget 4 → 2, A in `sprayedTo`, pending(A, hash) outstanding.
        #expect(offerAll(store, to: courierA) == 2)

        // Deliver the remainder to the recipient — REMOVES the carried record,
        // leaving A's pending offer outstanding (nothing clears it).
        #expect(store.takeEnvelopes(for: recipientKey).count == 1)
        #expect(store.isEmpty)

        // Same ciphertext redeposited: a brand-new record, full budget 4, empty
        // `sprayedTo`.
        #expect(store.deposit(envelope, from: depositorA))

        // Re-offering A from the fresh generation is REFUSED by the pending guard
        // (A's offer from the deleted generation is still outstanding), so A is
        // never inserted into the fresh record's `sprayedTo`. This is the step that
        // the round-2 `sprayedTo` gate alone left open.
        #expect(offerAll(store, to: courierA) == 0)

        // A's late/replayed decline from the deleted generation now finds the fresh
        // record without A in `sprayedTo`: it consumes the stale pending entry but
        // restores nothing.
        store.cancelSpray(ciphertextHash: hash, courierNoiseKey: courierA)

        // No inflation: the fresh record still holds exactly 4, so B gets half (2).
        // Pre-fix, A's re-offer would have taken 2 and the stale decline restored to
        // 4 while A held the fresh 2 (total 6), making this split 2 off an inflated
        // budget.
        let courierB = Data(repeating: 0xC2, count: 32)
        #expect(offerAll(store, to: courierB) == 2)
    }
}

import Foundation
import Testing

@testable import bitchat

/// Vouch storage, accept-policy gates, derived trust levels, and persistence
/// compatibility for `SecureIdentityStateManager`.
///
/// Ordering note: mutations use barrier blocks on the manager's concurrent
/// queue and reads use `queue.sync`, so a read submitted after a mutation
/// always observes it — no polling needed.
///
/// `@MainActor` matches production (the manager's vouch API is driven by the
/// main-actor `ChatVouchCoordinator`) and keeps the blocking `queue.sync`
/// reads off the Swift Concurrency cooperative pool. Left nonisolated, Swift
/// Testing runs these tests in parallel on that pool, and on CI's few-core
/// runners every pool thread ended up parked in `queue.sync` behind a pending
/// `queue.async(.barrier)` write that never got a dispatch worker — a
/// process-wide deadlock (watchdog SIGKILL, exit 137).
@MainActor
struct SecureIdentityStateManagerVouchTests {
    private let voucher = String(repeating: "0a", count: 32)
    private let vouchee = String(repeating: "0b", count: 32)

    private func makeManager() -> SecureIdentityStateManager {
        SecureIdentityStateManager(MockKeychain())
    }

    // MARK: - Accept-policy gates

    @Test
    func recordVouch_rejectsUnverifiedVoucher() {
        let manager = makeManager()

        #expect(!manager.recordVouch(voucheeFingerprint: vouchee, voucherFingerprint: voucher, timestamp: Date()))
        #expect(manager.validVouchers(for: vouchee).isEmpty)

        manager.setVerified(fingerprint: voucher, verified: true)
        #expect(manager.recordVouch(voucheeFingerprint: vouchee, voucherFingerprint: voucher, timestamp: Date()))
        #expect(manager.validVouchers(for: vouchee).count == 1)
    }

    @Test
    func recordVouch_ignoresSelfVouch() {
        let manager = makeManager()
        manager.setVerified(fingerprint: voucher, verified: true)

        #expect(!manager.recordVouch(voucheeFingerprint: voucher, voucherFingerprint: voucher, timestamp: Date()))
        #expect(manager.validVouchers(for: voucher).isEmpty)
    }

    @Test
    func recordVouch_ignoresAlreadyVerifiedVouchee() {
        let manager = makeManager()
        manager.setVerified(fingerprint: voucher, verified: true)
        manager.setVerified(fingerprint: vouchee, verified: true)

        #expect(!manager.recordVouch(voucheeFingerprint: vouchee, voucherFingerprint: voucher, timestamp: Date()))
        #expect(!manager.isVouched(fingerprint: vouchee))
    }

    @Test
    func recordVouch_rejectsStaleAndFarFutureTimestamps() {
        let manager = makeManager()
        manager.setVerified(fingerprint: voucher, verified: true)

        let stale = Date().addingTimeInterval(-31 * 24 * 60 * 60)
        #expect(!manager.recordVouch(voucheeFingerprint: vouchee, voucherFingerprint: voucher, timestamp: stale))

        let farFuture = Date().addingTimeInterval(2 * 60 * 60)
        #expect(!manager.recordVouch(voucheeFingerprint: vouchee, voucherFingerprint: voucher, timestamp: farFuture))

        #expect(manager.validVouchers(for: vouchee).isEmpty)
    }

    @Test
    func recordVouch_capsVouchersPerVoucheeKeepingMostRecent() {
        let manager = makeManager()
        let base = Date()

        // 9 verified vouchers vouch with strictly increasing timestamps.
        let vouchers = (0..<9).map { String(format: "%02x", $0 + 0x10) + String(repeating: "00", count: 31) }
        for (index, voucherFingerprint) in vouchers.enumerated() {
            manager.setVerified(fingerprint: voucherFingerprint, verified: true)
            let stored = manager.recordVouch(
                voucheeFingerprint: vouchee,
                voucherFingerprint: voucherFingerprint,
                timestamp: base.addingTimeInterval(TimeInterval(index)),
                now: base.addingTimeInterval(TimeInterval(index))
            )
            #expect(stored)
        }

        let records = manager.validVouchers(for: vouchee)
        #expect(records.count == SecureIdentityStateManager.maxVouchersPerVouchee)
        // The oldest voucher fell off the end.
        #expect(!records.contains { $0.voucherFingerprint == vouchers[0] })
        #expect(records.contains { $0.voucherFingerprint == vouchers[8] })

        // An attestation older than everything retained is not stored.
        let older = String(repeating: "0c", count: 32)
        manager.setVerified(fingerprint: older, verified: true)
        #expect(!manager.recordVouch(
            voucheeFingerprint: vouchee,
            voucherFingerprint: older,
            timestamp: base.addingTimeInterval(-1),
            now: base
        ))

        // A repeat vouch from a retained voucher refreshes, not duplicates.
        #expect(manager.recordVouch(
            voucheeFingerprint: vouchee,
            voucherFingerprint: vouchers[8],
            timestamp: base.addingTimeInterval(100),
            now: base.addingTimeInterval(100)
        ))
        #expect(manager.validVouchers(for: vouchee).count == SecureIdentityStateManager.maxVouchersPerVouchee)
    }

    // MARK: - Derived trust & invalidation

    @Test
    func unverifyingVoucher_invalidatesTheirVouchesWithoutDeletingThem() {
        let manager = makeManager()
        manager.setVerified(fingerprint: voucher, verified: true)
        manager.recordVouch(voucheeFingerprint: vouchee, voucherFingerprint: voucher, timestamp: Date())
        #expect(manager.isVouched(fingerprint: vouchee))

        // Removing my verification of the voucher retires their vouches…
        manager.setVerified(fingerprint: voucher, verified: false)
        #expect(!manager.isVouched(fingerprint: vouchee))
        #expect(manager.validVouchers(for: vouchee).isEmpty)

        // …but the records survive: re-verifying the voucher restores them
        // (recompute on read, no cascade delete).
        manager.setVerified(fingerprint: voucher, verified: true)
        #expect(manager.isVouched(fingerprint: vouchee))
    }

    @Test
    func validVouchers_expireAtReadTime() {
        let manager = makeManager()
        manager.setVerified(fingerprint: voucher, verified: true)

        let now = Date()
        let timestamp = now.addingTimeInterval(-29 * 24 * 60 * 60)
        #expect(manager.recordVouch(voucheeFingerprint: vouchee, voucherFingerprint: voucher, timestamp: timestamp, now: now))
        #expect(manager.isVouched(fingerprint: vouchee, now: now))

        let twoDaysLater = now.addingTimeInterval(2 * 24 * 60 * 60)
        #expect(manager.validVouchers(for: vouchee, now: twoDaysLater).isEmpty)
        #expect(!manager.isVouched(fingerprint: vouchee, now: twoDaysLater))
    }

    @Test
    func effectiveTrustLevel_slotsVouchedBetweenCasualAndTrusted() {
        let manager = makeManager()
        manager.setVerified(fingerprint: voucher, verified: true)

        // Unknown peer with a valid vouch reads as vouched.
        #expect(manager.effectiveTrustLevel(for: vouchee) == .unknown)
        manager.recordVouch(voucheeFingerprint: vouchee, voucherFingerprint: voucher, timestamp: Date())
        #expect(manager.effectiveTrustLevel(for: vouchee) == .vouched)

        // Explicit trust outranks a vouch.
        manager.updateSocialIdentity(SocialIdentity(
            fingerprint: vouchee,
            localPetname: nil,
            claimedNickname: "bob",
            trustLevel: .trusted,
            isFavorite: false,
            isBlocked: false,
            notes: nil
        ))
        #expect(manager.effectiveTrustLevel(for: vouchee) == .trusted)

        // Explicit verification outranks everything.
        manager.setVerified(fingerprint: vouchee, verified: true)
        #expect(manager.effectiveTrustLevel(for: vouchee) == .verified)
        #expect(!manager.isVouched(fingerprint: vouchee))

        // Losing the voucher downgrades vouched back to the stored level.
        manager.setVerified(fingerprint: vouchee, verified: false)
        manager.setVerified(fingerprint: voucher, verified: false)
        #expect(manager.effectiveTrustLevel(for: vouchee) == .casual)
    }

    // MARK: - Exchange-policy state

    @Test
    func mostRecentlyVerifiedFingerprints_ordersAndExcludes() {
        let manager = makeManager()
        let first = String(repeating: "01", count: 32)
        let second = String(repeating: "02", count: 32)
        let third = String(repeating: "03", count: 32)
        manager.setVerified(fingerprint: first, verified: true)
        manager.setVerified(fingerprint: second, verified: true)
        manager.setVerified(fingerprint: third, verified: true)

        let ordered = manager.mostRecentlyVerifiedFingerprints(limit: 16, excluding: third)
        #expect(ordered == [second, first])

        let limited = manager.mostRecentlyVerifiedFingerprints(limit: 1, excluding: third)
        #expect(limited == [second])
    }

    @Test
    func vouchBatchSentAt_roundTrips() {
        let manager = makeManager()
        #expect(manager.lastVouchBatchSent(to: voucher) == nil)

        let sentAt = Date(timeIntervalSince1970: 1_700_000_000)
        manager.markVouchBatchSent(to: voucher, at: sentAt)
        #expect(manager.lastVouchBatchSent(to: voucher) == sentAt)
    }

    @Test
    func signingPublicKey_returnsAnnounceBoundKeyByFingerprint() async {
        let manager = makeManager()
        let signingKey = Data(repeating: 0x22, count: 32)
        manager.upsertCryptographicIdentity(
            fingerprint: voucher,
            noisePublicKey: Data(repeating: 0x11, count: 32),
            signingPublicKey: signingKey,
            claimedNickname: nil
        )

        let stored = await waitUntil { manager.signingPublicKey(forFingerprint: voucher) == signingKey }
        #expect(stored)
        #expect(manager.signingPublicKey(forFingerprint: vouchee) == nil)
    }

    // MARK: - Panic wipe

    @Test
    func clearAllIdentityData_wipesVouchState() async {
        let manager = makeManager()
        manager.setVerified(fingerprint: voucher, verified: true)
        manager.recordVouch(voucheeFingerprint: vouchee, voucherFingerprint: voucher, timestamp: Date())
        manager.markVouchBatchSent(to: voucher, at: Date())
        #expect(manager.isVouched(fingerprint: vouchee))

        manager.clearAllIdentityData()

        let wiped = await waitUntil { !manager.isVouched(fingerprint: vouchee) }
        #expect(wiped)
        #expect(manager.validVouchers(for: vouchee).isEmpty)
        #expect(manager.lastVouchBatchSent(to: voucher) == nil)
        #expect(manager.mostRecentlyVerifiedFingerprints(limit: 16, excluding: "").isEmpty)
    }

    // MARK: - Persistence compatibility

    @Test
    func trustLevelRawValuesAreStable() throws {
        // Raw values are what's persisted; they must never change when cases
        // are added mid-ladder.
        #expect(TrustLevel.unknown.rawValue == "unknown")
        #expect(TrustLevel.casual.rawValue == "casual")
        #expect(TrustLevel.vouched.rawValue == "vouched")
        #expect(TrustLevel.trusted.rawValue == "trusted")
        #expect(TrustLevel.verified.rawValue == "verified")

        let legacy = Data(#"["unknown","casual","trusted","verified"]"#.utf8)
        let decoded = try JSONDecoder().decode([TrustLevel].self, from: legacy)
        #expect(decoded == [.unknown, .casual, .trusted, .verified])
    }

    @Test
    func identityCachePersistedBeforeVouchingDecodesCleanly() throws {
        // A cache captured before the vouch fields existed must decode without
        // tripping the "unreadable cache" recovery path.
        let legacyJSON = Data("""
        {
          "socialIdentities": {},
          "nicknameIndex": {},
          "verifiedFingerprints": ["\(voucher)"],
          "lastInteractions": {},
          "blockedNostrPubkeys": [],
          "version": 1
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(IdentityCache.self, from: legacyJSON)
        #expect(decoded.vouchesByVouchee == nil)
        #expect(decoded.vouchBatchSentAt == nil)
        #expect(decoded.verifiedAt == nil)
        #expect(decoded.verifiedFingerprints == [voucher])
    }

    @Test
    func identityCacheRoundTripsVouchState() throws {
        var cache = IdentityCache()
        cache.verifiedFingerprints = [voucher]
        cache.vouchesByVouchee = [vouchee: [VouchRecord(voucherFingerprint: voucher, timestamp: Date(timeIntervalSince1970: 1_700_000_000))]]
        cache.vouchBatchSentAt = [voucher: Date(timeIntervalSince1970: 1_700_000_001)]
        cache.verifiedAt = [voucher: Date(timeIntervalSince1970: 1_700_000_002)]

        let decoded = try JSONDecoder().decode(IdentityCache.self, from: JSONEncoder().encode(cache))
        #expect(decoded.vouchesByVouchee == cache.vouchesByVouchee)
        #expect(decoded.vouchBatchSentAt == cache.vouchBatchSentAt)
        #expect(decoded.verifiedAt == cache.verifiedAt)
    }

    @Test
    func vouchStateSurvivesReload() async {
        let keychain = MockKeychain()
        let manager = SecureIdentityStateManager(keychain)
        manager.setVerified(fingerprint: voucher, verified: true)
        manager.recordVouch(voucheeFingerprint: vouchee, voucherFingerprint: voucher, timestamp: Date())
        let saved = await waitUntil { manager.isVouched(fingerprint: self.vouchee) }
        #expect(saved)
        manager.forceSave()

        let reloaded = SecureIdentityStateManager(keychain)
        #expect(reloaded.isVouched(fingerprint: vouchee))
        #expect(reloaded.validVouchers(for: vouchee).count == 1)
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: TimeInterval = 1.0,
        condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}

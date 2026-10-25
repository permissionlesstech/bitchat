//
// SecureIdentityStateManagerRetentionTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import XCTest
import BitFoundation
@testable import bitchat

/// Identity-cache retention: which identities a pass forgets, which it keeps,
/// and what it writes. Every test injects the clock and a small cap (high
/// water 10, low water 6), and runs synchronously.
final class SecureIdentityStateManagerRetentionTests: XCTestCase {
    private static let day: TimeInterval = 24 * 60 * 60
    /// A UTC midnight, and midday that day: day arithmetic never straddles
    /// midnight.
    private let today = Date(timeIntervalSince1970: 1_760_054_400)
    private var now: Date { today.addingTimeInterval(Self.day / 2) }
    private let policy = SecureIdentityStateManager.RetentionPolicy(strangerHighWater: 10, strangerLowWater: 6)

    func test_retention_evictsStrangersUnseenForThirtyDaysPlusTheRefreshInterval() throws {
        let ages: [Double] = [38, 37, 36, 1]
        let fixture = try IdentityCacheFixture(count: ages.count) { cache, strangers in
            for (stranger, age) in zip(strangers, ages) {
                cache.cryptographicIdentities[stranger.fingerprint]?.lastSeen = daysAgo(age)
            }
        }
        let strangers = fixture.strangers
        let manager = SecureIdentityStateManager(fixture.keychain, retentionPolicy: policy)
        manager.setRetentionProtectedFingerprints([])
        let writes = fixture.cacheSaveCount

        announce(Data(repeating: 0x81, count: 32), to: manager, at: now)

        XCTAssertFalse(knows(strangers[0], manager), "unseen for 38 days")
        XCTAssertNil(manager.getSocialIdentity(for: strangers[0].fingerprint))
        XCTAssertTrue(knows(strangers[1], manager), "unseen for 37 days: 30 + 7 is a lower bound")
        XCTAssertTrue(knows(strangers[2], manager))
        XCTAssertTrue(knows(strangers[3], manager))
        XCTAssertEqual(fixture.cacheSaveCount, writes + 1, "the newcomer and the eviction share one write")

        let reloaded = SecureIdentityStateManager(fixture.keychain, retentionPolicy: policy)
        XCTAssertFalse(knows(strangers[0], reloaded))
        XCTAssertTrue(knows(strangers[1], reloaded))

        // Seen again, the stranger is a first contact, found exactly once.
        announce(strangers[0], to: manager, at: now.addingTimeInterval(60))
        XCTAssertEqual(manager.getCryptoIdentitiesByPeerIDPrefix(PeerID(publicKey: strangers[0].noisePublicKey)).count, 1)
    }

    func test_retention_keepsEveryProtectedRelationship() throws {
        let names = [
            "favorite", "verified", "verifiedAt", "socialFavorite", "blocked", "petname", "notes",
            "casual", "trusted", "vouchee", "voucher", "vouchedTo",
            "stranger", "noiseAuthenticatedStranger", "lastInteraction"
        ]
        func fingerprint(_ name: String, in strangers: [IdentityCacheFixture.Stranger]) -> String {
            strangers[names.firstIndex(of: name) ?? 0].fingerprint
        }
        // Everyone unseen for 60 days.
        let fixture = try IdentityCacheFixture(count: names.count, lastSeen: daysAgo(60)) { cache, strangers in
            func fp(_ name: String) -> String { fingerprint(name, in: strangers) }
            cache.verifiedFingerprints.insert(fp("verified"))
            cache.verifiedAt = [fp("verifiedAt"): daysAgo(90)]
            cache.socialIdentities[fp("socialFavorite")]?.isFavorite = true
            cache.socialIdentities[fp("blocked")]?.isBlocked = true
            cache.socialIdentities[fp("petname")]?.localPetname = "pal"
            cache.socialIdentities[fp("notes")]?.notes = "met at the station"
            cache.socialIdentities[fp("casual")]?.trustLevel = .casual
            cache.socialIdentities[fp("trusted")]?.trustLevel = .trusted
            cache.vouchesByVouchee = [fp("vouchee"): [VouchRecord(voucherFingerprint: fp("voucher"), timestamp: daysAgo(90))]]
            cache.vouchBatchSentAt = [fp("vouchedTo"): daysAgo(90)]
            // A Noise session alone is no relationship: every nearby iOS
            // peer completes one.
            cache.authenticatedSigningKeysByFingerprint = [fp("noiseAuthenticatedStranger"): Data(repeating: 0x91, count: 32)]
            cache.privateMediaCapableFingerprints = [fp("noiseAuthenticatedStranger")]
            cache.nicknameIndex["stranger"] = [fp("stranger")]
            // Nor is an entry an older build left in `lastInteractions`: a
            // peer this device only met or messaged is a stranger.
            cache.lastInteractions = [fp("lastInteraction"): daysAgo(90)]
        }
        let strangers = fixture.strangers
        let manager = SecureIdentityStateManager(fixture.keychain, retentionPolicy: policy)
        manager.setRetentionProtectedFingerprints([fingerprint("favorite", in: strangers)])

        announce(Data(repeating: 0x82, count: 32), to: manager, at: now)

        let evicted = ["stranger", "noiseAuthenticatedStranger", "lastInteraction"]
        for loaded in [manager, SecureIdentityStateManager(fixture.keychain, retentionPolicy: policy)] {
            for name in names where !evicted.contains(name) {
                let protected = fingerprint(name, in: strangers)
                XCTAssertTrue(loaded.signingPublicKey(forFingerprint: protected) != nil, "\(name) must be kept")
                // Kept identities need no stamp, so none is stored.
                XCTAssertNil(lastSeen(of: protected, in: loaded), "\(name) keeps a lastSeen stamp")
            }
            for name in evicted {
                XCTAssertNil(loaded.signingPublicKey(forFingerprint: fingerprint(name, in: strangers)), "\(name) must be evicted")
            }
            // Everything pinned for an evicted stranger goes with it.
            let noiseAuthenticated = fingerprint("noiseAuthenticatedStranger", in: strangers)
            XCTAssertNil(loaded.authenticatedSigningPublicKey(forFingerprint: noiseAuthenticated))
            XCTAssertFalse(loaded.hasObservedPrivateMediaCapability(fingerprint: noiseAuthenticated))
            XCTAssertNil(loaded.debugNicknameIndex["stranger"])
        }
    }

    func test_retention_capTrimsTheLeastRecentlySeenStrangersToLowWater() throws {
        // Eleven strangers, one over high water. The first one announces,
        // which refreshes its stale stamp.
        let ages: [Double] = [20, 13, 13, 12, 6, 6, 5, 2, 1, 0, 0]
        let fixture = try IdentityCacheFixture(count: ages.count) { cache, strangers in
            for (stranger, age) in zip(strangers, ages) {
                cache.cryptographicIdentities[stranger.fingerprint]?.lastSeen = daysAgo(age)
            }
        }
        let strangers = fixture.strangers
        let manager = SecureIdentityStateManager(fixture.keychain, retentionPolicy: policy)
        manager.setRetentionProtectedFingerprints([])

        announce(strangers[0], to: manager, at: now)

        // Strangers stamped over a week ago go first, oldest stamp first: 1
        // and 2 (the newer arrival first), then 3. Stamps are
        // refreshed weekly, so everyone stamped within the week may have been
        // seen today: they rank equal, and the newest arrivals (later
        // firstSeen) go first, 10 and then 9.
        let kept = strangers.indices.filter { knows(strangers[$0], manager) }
        XCTAssertEqual(kept, [0, 4, 5, 6, 7, 8])
    }

    func test_retention_capKeepsStrangersSeenThisWeekOverABurstOfNewIdentities() {
        let manager = SecureIdentityStateManager(MockKeychain(), retentionPolicy: policy)
        manager.setRetentionProtectedFingerprints([])
        // Five strangers announce every day for two weeks. Their stamps are
        // refreshed weekly, so on the last day they read six days old.
        let regulars = (0..<5).map { Data(repeating: UInt8(0x30 + $0), count: 32) }
        for day in 0...13 {
            for regular in regulars {
                announce(regular, to: manager, at: now.addingTimeInterval(Double(day) * Self.day))
            }
        }

        // An hour after their last announces, six new identities arrive:
        // eleven strangers, one over high water.
        let burst = (0..<6).map { Data(repeating: UInt8(0x40 + $0), count: 32) }
        for (index, identity) in burst.enumerated() {
            announce(identity, to: manager, at: now.addingTimeInterval(13 * Self.day + 3_600 + Double(index) * 60))
        }

        XCTAssertEqual(regulars.filter { knows($0, manager) }.count, 5, "strangers seen today make way for newer arrivals")
        // The last arrival is the announcer, which its own announce never
        // evicts.
        XCTAssertEqual(burst.map { knows($0, manager) }, [false, false, false, false, false, true])
    }

    func test_retention_capCountsOnlyStrangers() throws {
        // Eight verified peers and seven strangers, all seen today: fifteen
        // identities, above high water, but only seven strangers.
        let fixture = try IdentityCacheFixture(count: 15, lastSeen: today) { cache, strangers in
            for stranger in strangers.prefix(8) {
                cache.verifiedFingerprints.insert(stranger.fingerprint)
            }
        }
        let strangers = fixture.strangers
        let manager = SecureIdentityStateManager(fixture.keychain, retentionPolicy: policy)
        manager.setRetentionProtectedFingerprints([])
        announce(strangers[14], to: manager, at: now)
        XCTAssertTrue(strangers.allSatisfy { knows($0, manager) })

        // Four newcomers make eleven strangers, which trims them to six:
        // first the newest of today's arrivals, then the most recently met.
        let newcomers = (0..<4).map { Data(repeating: UInt8(0xA0 + $0), count: 32) }
        for (index, newcomer) in newcomers.enumerated() {
            announce(newcomer, to: manager, at: now.addingTimeInterval(TimeInterval(60 * (index + 1))))
        }

        XCTAssertTrue(strangers.prefix(8).allSatisfy { knows($0, manager) }, "protected identities do not count")
        XCTAssertEqual(strangers.indices.filter { knows(strangers[$0], manager) }, Array(0...12))
        XCTAssertEqual(newcomers.map { knows($0, manager) }, [false, false, false, true])
    }

    func test_retention_passRunsDailyOrOnceStrangersPassTheCap() throws {
        // Eight verified peers and four strangers: more identities than high
        // water, but not more strangers.
        let fixture = try IdentityCacheFixture(count: 12, lastSeen: today) { cache, strangers in
            for stranger in strangers.prefix(8) {
                cache.verifiedFingerprints.insert(stranger.fingerprint)
                cache.cryptographicIdentities[stranger.fingerprint]?.lastSeen = nil
            }
        }
        let strangers = fixture.strangers
        let manager = SecureIdentityStateManager(fixture.keychain, retentionPolicy: policy)
        manager.setRetentionProtectedFingerprints([])
        announce(strangers[11], to: manager, at: now)

        // A peer known only from authenticated peer state has no stamp until
        // a pass gives it one, which shows whether a pass ran.
        let peer = Data(repeating: 0x99, count: 32)
        manager.upsertAuthenticatedPeerIdentity(
            fingerprint: peer.sha256Fingerprint(),
            noisePublicKey: peer,
            signingPublicKey: Data(repeating: 0x9A, count: 32)
        )

        // The same day, with strangers under the cap, an announce runs none:
        // the per-announce check is O(1), not a pass.
        announce(strangers[10], to: manager, at: now.addingTimeInterval(60 * 60))
        XCTAssertNil(lastSeen(of: peer.sha256Fingerprint(), in: manager))

        // A day later one runs.
        announce(strangers[10], to: manager, at: now.addingTimeInterval(Self.day))
        XCTAssertEqual(lastSeen(of: peer.sha256Fingerprint(), in: manager), today.addingTimeInterval(Self.day))
    }

    func test_retention_isDisabledUntilTheFavoritesSnapshotArrives() throws {
        let fixture = try IdentityCacheFixture(count: 2, lastSeen: daysAgo(60))
        let manager = SecureIdentityStateManager(fixture.keychain, retentionPolicy: policy)

        announce(Data(repeating: 0x83, count: 32), to: manager, at: now)
        XCTAssertTrue(fixture.strangers.allSatisfy { knows($0, manager) })

        manager.setRetentionProtectedFingerprints([])
        announce(Data(repeating: 0x84, count: 32), to: manager, at: now.addingTimeInterval(60))
        XCTAssertFalse(fixture.strangers.contains { knows($0, manager) })
    }

    func test_retention_givesEntriesWithoutLastSeenAFullGracePeriod() throws {
        // A cache written before `lastSeen` existed: strangers first seen a
        // year earlier, never stamped.
        let fixture = try IdentityCacheFixture(count: 3)
        let strangers = fixture.strangers
        let manager = SecureIdentityStateManager(fixture.keychain, retentionPolicy: policy)
        manager.setRetentionProtectedFingerprints([])
        let writes = fixture.cacheSaveCount

        announce(Data(repeating: 0x85, count: 32), to: manager, at: now)
        XCTAssertTrue(strangers.allSatisfy { knows($0, manager) })
        XCTAssertTrue(strangers.allSatisfy { lastSeen(of: $0.fingerprint, in: manager) == today })
        XCTAssertEqual(fixture.cacheSaveCount, writes + 1, "the newcomer and every grace stamp share one write")

        announce(Data(repeating: 0x86, count: 32), to: manager, at: now.addingTimeInterval(36 * Self.day))
        XCTAssertTrue(strangers.allSatisfy { knows($0, manager) })

        announce(Data(repeating: 0x87, count: 32), to: manager, at: now.addingTimeInterval(38 * Self.day))
        XCTAssertFalse(strangers.contains { knows($0, manager) })
    }

    func test_retention_givesAFullPeriodWhenProtectionLapses() throws {
        // A favorite seen yesterday. The pass drops its stamp.
        let fixture = try IdentityCacheFixture(count: 1, lastSeen: daysAgo(1))
        let friend = fixture.strangers[0]
        let manager = SecureIdentityStateManager(fixture.keychain, retentionPolicy: policy)
        manager.setRetentionProtectedFingerprints([friend.fingerprint])
        announce(Data(repeating: 0x8D, count: 32), to: manager, at: now)
        XCTAssertNil(lastSeen(of: friend.fingerprint, in: manager))

        // Unfavorited 100 days later, unseen all that time: the next pass
        // stamps it with its own day, and it is kept 37 days from then.
        manager.setRetentionProtectedFingerprints([])
        let lapsed = now.addingTimeInterval(100 * Self.day)
        announce(Data(repeating: 0x8E, count: 32), to: manager, at: lapsed)
        XCTAssertEqual(lastSeen(of: friend.fingerprint, in: manager), today.addingTimeInterval(100 * Self.day))
        announce(Data(repeating: 0x8F, count: 32), to: manager, at: lapsed.addingTimeInterval(36 * Self.day))
        announce(Data(repeating: 0x9B, count: 32), to: manager, at: lapsed.addingTimeInterval(37 * Self.day))
        XCTAssertTrue(knows(friend, manager))
        announce(Data(repeating: 0x9C, count: 32), to: manager, at: lapsed.addingTimeInterval(38 * Self.day))
        XCTAssertFalse(knows(friend, manager))
    }

    // MARK: - Clock steps

    func test_retention_aClockSteppedBackMovesNoStampBackwards() throws {
        // Five strangers seen yesterday, by the pass that ran then.
        let fixture = try IdentityCacheFixture(count: 5, lastSeen: daysAgo(1)) { cache, _ in
            cache.retentionPassDay = daysAgo(1)
        }
        let strangers = fixture.strangers
        let manager = SecureIdentityStateManager(fixture.keychain, retentionPolicy: policy)
        manager.setRetentionProtectedFingerprints([])

        // The clock is stepped back 60 days. Neither the pass nor a
        // stranger's own announce moves a stamp back to that day.
        let steppedBack = now.addingTimeInterval(-60 * Self.day)
        announce(Data(repeating: 0x90, count: 32), to: manager, at: steppedBack)
        announce(strangers[0], to: manager, at: steppedBack.addingTimeInterval(60))
        XCTAssertTrue(strangers.allSatisfy { lastSeen(of: $0.fingerprint, in: manager) == daysAgo(1) })

        // Once the clock is restored, they age from the day they were really
        // seen: kept 37 days after it, forgotten at 38.
        announce(Data(repeating: 0x91, count: 32), to: manager, at: now.addingTimeInterval(120))
        let reloaded = SecureIdentityStateManager(fixture.keychain, retentionPolicy: policy)
        reloaded.setRetentionProtectedFingerprints([])
        announce(Data(repeating: 0x92, count: 32), to: reloaded, at: now.addingTimeInterval(36 * Self.day))
        XCTAssertTrue(strangers.allSatisfy { knows($0, reloaded) })
        announce(Data(repeating: 0x93, count: 32), to: reloaded, at: now.addingTimeInterval(37 * Self.day))
        XCTAssertFalse(strangers.contains { knows($0, reloaded) })
    }

    func test_retention_aStampAheadOfTheClockAgesFromItsOwnDay() throws {
        // Stamped while the clock ran ten days fast.
        let ahead = today.addingTimeInterval(10 * Self.day)
        let fixture = try IdentityCacheFixture(count: 1, lastSeen: ahead)
        let stranger = fixture.strangers[0]
        let manager = SecureIdentityStateManager(fixture.keychain, retentionPolicy: policy)
        manager.setRetentionProtectedFingerprints([])

        announce(Data(repeating: 0x94, count: 32), to: manager, at: now)
        XCTAssertEqual(lastSeen(of: stranger.fingerprint, in: manager), ahead, "the pass keeps a stamp ahead of the clock")

        announce(Data(repeating: 0x95, count: 32), to: manager, at: now.addingTimeInterval(46 * Self.day))
        announce(Data(repeating: 0x96, count: 32), to: manager, at: now.addingTimeInterval(47 * Self.day))
        XCTAssertTrue(knows(stranger, manager), "unseen for 37 days counted from its stamp")
        announce(Data(repeating: 0x97, count: 32), to: manager, at: now.addingTimeInterval(48 * Self.day))
        XCTAssertFalse(knows(stranger, manager))
    }

    func test_retention_aPassStillRunsAfterTheClockStepsBack() throws {
        let fixture = try IdentityCacheFixture(count: 2, lastSeen: today)
        let strangers = fixture.strangers
        let manager = SecureIdentityStateManager(fixture.keychain, retentionPolicy: policy)
        manager.setRetentionProtectedFingerprints([])
        announce(strangers[0], to: manager, at: now)

        // Verifying a stranger protects it; the next pass clears its stamp.
        manager.setVerified(fingerprint: strangers[1].fingerprint, verified: true)
        XCTAssertEqual(lastSeen(of: strangers[1].fingerprint, in: manager), today)

        // Two days back is a day of clock movement too: the pass runs.
        announce(strangers[0], to: manager, at: now.addingTimeInterval(-2 * Self.day))
        XCTAssertNil(lastSeen(of: strangers[1].fingerprint, in: manager))
    }

    func test_retention_aClockSteppedForwardForgetsNothingUntilTwoPassesAgree() throws {
        // Five strangers seen yesterday, by the pass that ran then.
        let fixture = try IdentityCacheFixture(count: 5, lastSeen: daysAgo(1)) { cache, _ in
            cache.retentionPassDay = daysAgo(1)
        }
        let strangers = fixture.strangers
        let manager = SecureIdentityStateManager(fixture.keychain, retentionPolicy: policy)
        manager.setRetentionProtectedFingerprints([])
        func keptEveryone(_ manager: SecureIdentityStateManager) -> Bool {
            strangers.allSatisfy { knows($0, manager) }
        }

        // The clock jumps 40 days ahead: a date set forward, or a spoofed
        // network time.
        let ahead = now.addingTimeInterval(40 * Self.day)
        announce(Data(repeating: 0xA0, count: 32), to: manager, at: ahead)
        XCTAssertTrue(keptEveryone(manager))

        // A relaunch with the clock still ahead brings no second day to
        // agree with.
        let relaunched = SecureIdentityStateManager(fixture.keychain, retentionPolicy: policy)
        relaunched.setRetentionProtectedFingerprints([])
        announce(Data(repeating: 0xA1, count: 32), to: relaunched, at: ahead.addingTimeInterval(60 * 60))
        XCTAssertTrue(keptEveryone(relaunched))

        // The clock is corrected, and the days that follow forget no one.
        announce(Data(repeating: 0xA2, count: 32), to: relaunched, at: now.addingTimeInterval(2 * 60 * 60))
        announce(Data(repeating: 0xA3, count: 32), to: relaunched, at: now.addingTimeInterval(Self.day + 2 * 60 * 60))
        XCTAssertTrue(keptEveryone(SecureIdentityStateManager(fixture.keychain, retentionPolicy: policy)))
    }

    func test_retention_forgetsAfterAnAbsenceOnePassLater() throws {
        // Strangers last seen 38 days ago; the last pass ran ten days ago.
        // A verified friend announces, which writes nothing of its own.
        let fixture = try IdentityCacheFixture(count: 4, lastSeen: daysAgo(38)) { cache, strangers in
            cache.retentionPassDay = daysAgo(10)
            cache.verifiedFingerprints.insert(strangers[3].fingerprint)
            cache.cryptographicIdentities[strangers[3].fingerprint]?.lastSeen = nil
        }
        let strangers = Array(fixture.strangers.prefix(3))
        let friend = fixture.strangers[3]
        let manager = SecureIdentityStateManager(fixture.keychain, retentionPolicy: policy)
        manager.setRetentionProtectedFingerprints([])
        let writes = fixture.cacheSaveCount

        // Ten days without a pass look like a clock jumped ahead, so the
        // first pass back forgets no one and writes its day...
        announce(friend, to: manager, at: now)
        XCTAssertTrue(strangers.allSatisfy { knows($0, manager) })
        XCTAssertEqual(fixture.cacheSaveCount, writes + 1)

        // ...which lets a pass the next day, even after a relaunch, agree.
        // Two passes on different days are believed, including a clock
        // that stays wrong for that long.
        let relaunched = SecureIdentityStateManager(fixture.keychain, retentionPolicy: policy)
        relaunched.setRetentionProtectedFingerprints([])
        announce(friend, to: relaunched, at: now.addingTimeInterval(Self.day))
        XCTAssertFalse(strangers.contains { knows($0, relaunched) })
    }

    func test_lastSeen_isRefreshedWeeklyAndNeverForProtectedIdentities() throws {
        let fixture = try IdentityCacheFixture(count: 3, lastSeen: today) { cache, strangers in
            cache.verifiedFingerprints.insert(strangers[1].fingerprint)
            cache.cryptographicIdentities[strangers[1].fingerprint]?.lastSeen = nil
            cache.cryptographicIdentities[strangers[2].fingerprint]?.lastSeen = nil
        }
        let stranger = fixture.strangers[0]
        let verified = fixture.strangers[1]
        let legacy = fixture.strangers[2]
        let manager = SecureIdentityStateManager(fixture.keychain, retentionPolicy: policy)
        let writes = fixture.cacheSaveCount

        // An entry from before `lastSeen` is left to the pass's one grace
        // write, not stamped by each of its announces.
        announce(legacy, to: manager, at: now)
        XCTAssertNil(lastSeen(of: legacy.fingerprint, in: manager))
        XCTAssertEqual(fixture.cacheSaveCount, writes)

        announce(stranger, to: manager, at: now.addingTimeInterval(6 * Self.day))
        XCTAssertEqual(lastSeen(of: stranger.fingerprint, in: manager), today)
        XCTAssertEqual(fixture.cacheSaveCount, writes, "a stamp under a week old is not rewritten")

        announce(stranger, to: manager, at: now.addingTimeInterval(7 * Self.day))
        XCTAssertEqual(lastSeen(of: stranger.fingerprint, in: manager), today.addingTimeInterval(7 * Self.day))
        XCTAssertEqual(fixture.cacheSaveCount, writes + 1)

        announce(verified, to: manager, at: now.addingTimeInterval(30 * Self.day))
        XCTAssertNil(lastSeen(of: verified.fingerprint, in: manager))
        XCTAssertEqual(fixture.cacheSaveCount, writes + 1, "a protected identity keeps no stamp")

        let newcomer = Data(repeating: 0x88, count: 32)
        announce(newcomer, to: manager, at: now)
        XCTAssertEqual(lastSeen(of: newcomer.sha256Fingerprint(), in: manager), today)

        // Verified before its first announce: protected from the start.
        let verifiedNewcomer = Data(repeating: 0x8C, count: 32)
        manager.setVerified(fingerprint: verifiedNewcomer.sha256Fingerprint(), verified: true)
        announce(verifiedNewcomer, to: manager, at: now)
        XCTAssertNil(lastSeen(of: verifiedNewcomer.sha256Fingerprint(), in: manager))
    }

    func test_authenticatedPeerStatePath_neverStampsOrRunsRetention() throws {
        // This path takes the real clock, so the strangers are aged from it.
        let fixture = try IdentityCacheFixture(count: 2, lastSeen: Date().addingTimeInterval(-60 * Self.day))
        let manager = SecureIdentityStateManager(fixture.keychain, retentionPolicy: policy)
        manager.setRetentionProtectedFingerprints([])
        let peer = Data(repeating: 0x89, count: 32)

        // Runs inside the Noise session lock: no pass, no stamp.
        manager.upsertAuthenticatedPeerIdentity(
            fingerprint: peer.sha256Fingerprint(),
            noisePublicKey: peer,
            signingPublicKey: Data(repeating: 0x8A, count: 32)
        )
        XCTAssertTrue(fixture.strangers.allSatisfy { knows($0, manager) })
        XCTAssertNil(lastSeen(of: peer.sha256Fingerprint(), in: manager))
        // The new identity and its signing-key pin are written at once.
        let reloaded = SecureIdentityStateManager(fixture.keychain, retentionPolicy: policy)
        XCTAssertEqual(reloaded.signingPublicKey(forFingerprint: peer.sha256Fingerprint()), Data(repeating: 0x8A, count: 32))

        // The peer's next verified announce runs the pass.
        manager.upsertCryptographicIdentity(
            fingerprint: peer.sha256Fingerprint(),
            noisePublicKey: peer,
            signingPublicKey: Data(repeating: 0x8A, count: 32),
            claimedNickname: "peer"
        )
        XCTAssertFalse(fixture.strangers.contains { knows($0, manager) })
    }

    // MARK: - Legacy lastInteractions

    func test_load_purgesLegacyLastInteractionsAndKeepsTheKeyOlderBuildsRequire() throws {
        // Builds from mid-2025 wrote an exact time here for every peer whose
        // key they registered: a record of whom this device met.
        let gone = String(repeating: "e5", count: 32)
        let fixture = try IdentityCacheFixture(count: 2, lastSeen: today) { cache, strangers in
            cache.lastInteractions = [
                strangers[0].fingerprint: daysAgo(400).addingTimeInterval(12_345),
                gone: daysAgo(380)
            ]
        }
        let strangers = fixture.strangers
        let manager = SecureIdentityStateManager(fixture.keychain, retentionPolicy: policy)
        XCTAssertNil(manager.debugLastInteraction(for: strangers[0].fingerprint))
        XCTAssertNil(manager.debugLastInteraction(for: gone))
        let writes = fixture.cacheSaveCount

        // The keychain still holds them, so the next upsert writes even
        // though it changes nothing (a peer stamped today, and no favorites
        // snapshot, so no pass), and only that one does.
        announce(strangers[1], to: manager, at: now)
        XCTAssertEqual(fixture.cacheSaveCount, writes + 1)
        announce(strangers[1], to: manager, at: now.addingTimeInterval(60))
        XCTAssertEqual(fixture.cacheSaveCount, writes + 1)

        // What is stored now has no entries, and keeps the key: v1.7.0 and
        // earlier decode the cache with a synthesized decoder, which requires
        // every non-optional field and discards a cache it cannot decode.
        let stored = try JSONDecoder().decode(SynthesizedIdentityCache.self, from: fixture.storedCacheJSON())
        XCTAssertTrue(stored.lastInteractions.isEmpty)
        XCTAssertEqual(Set(stored.socialIdentities.keys), Set(strangers.map(\.fingerprint)))

        // The purge drops nothing else.
        let reloaded = SecureIdentityStateManager(fixture.keychain, retentionPolicy: policy)
        XCTAssertTrue(strangers.allSatisfy { knows($0, reloaded) })
    }

    func test_identityCacheWithLastSeen_decodesWithThePreviousEntryShape() throws {
        // What a build from before `lastSeen` and `retentionPassDay` decodes:
        // a downgrade keeps the cache (and drops both on its next write).
        struct PreviousCryptographicIdentity: Decodable {
            let fingerprint: String
            let publicKey: Data
            var signingPublicKey: Data?
            let firstSeen: Date
        }
        struct PreviousIdentityCache: Decodable {
            let cryptographicIdentities: [String: PreviousCryptographicIdentity]
        }
        var cache = IdentityCache()
        cache.cryptographicIdentities["ab"] = CryptographicIdentity(
            fingerprint: "ab",
            publicKey: Data([0x01]),
            signingPublicKey: Data([0x02]),
            firstSeen: daysAgo(10),
            lastSeen: today
        )
        cache.retentionPassDay = today

        let decoded = try JSONDecoder().decode(PreviousIdentityCache.self, from: JSONEncoder().encode(cache))

        XCTAssertEqual(decoded.cryptographicIdentities["ab"]?.signingPublicKey, Data([0x02]))
    }

    // MARK: - Helpers

    /// The identity cache as v1.7.0 and earlier decode it: synthesized
    /// `Decodable`, so every non-optional field must be present.
    private struct SynthesizedIdentityCache: Decodable {
        let socialIdentities: [String: SocialIdentity]
        let nicknameIndex: [String: Set<String>]
        let verifiedFingerprints: Set<String>
        let lastInteractions: [String: Date]
        let blockedNostrPubkeys: Set<String>
        let vouchesByVouchee: [String: [VouchRecord]]?
        let vouchBatchSentAt: [String: Date]?
        let verifiedAt: [String: Date]?
    }

    private func daysAgo(_ days: Double) -> Date {
        today.addingTimeInterval(-days * Self.day)
    }

    /// A verified announce, as BLEService's persistIdentity sends it.
    private func announce(_ stranger: IdentityCacheFixture.Stranger, to manager: SecureIdentityStateManager, at time: Date) {
        manager.upsertCryptographicIdentity(
            fingerprint: stranger.fingerprint,
            noisePublicKey: stranger.noisePublicKey,
            signingPublicKey: stranger.signingPublicKey,
            claimedNickname: stranger.nickname,
            now: time
        )
    }

    private func announce(_ noisePublicKey: Data, to manager: SecureIdentityStateManager, at time: Date) {
        manager.upsertCryptographicIdentity(
            fingerprint: noisePublicKey.sha256Fingerprint(),
            noisePublicKey: noisePublicKey,
            signingPublicKey: Data(noisePublicKey.reversed()),
            claimedNickname: "newcomer",
            now: time
        )
    }

    private func knows(_ stranger: IdentityCacheFixture.Stranger, _ manager: SecureIdentityStateManager) -> Bool {
        manager.signingPublicKey(forFingerprint: stranger.fingerprint) != nil
    }

    private func knows(_ noisePublicKey: Data, _ manager: SecureIdentityStateManager) -> Bool {
        manager.signingPublicKey(forFingerprint: noisePublicKey.sha256Fingerprint()) != nil
    }

    private func lastSeen(of fingerprint: String, in manager: SecureIdentityStateManager) -> Date? {
        manager.getCryptoIdentitiesByPeerIDPrefix(PeerID(str: fingerprint.prefix(16)))
            .first { $0.fingerprint == fingerprint }?
            .lastSeen
    }
}

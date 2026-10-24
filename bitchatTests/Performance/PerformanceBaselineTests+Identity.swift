//
// PerformanceBaselineTests+Identity.swift
// bitchatTests
//
// Identity-cache benchmarks at 2,000 known identities. Each guards a cost
// that used to grow with the number of identities C:
//
// - every verified announce rewrote the whole encrypted cache (JSON encode,
//   AES-GCM seal, keychain delete and add), even when nothing had changed;
// - every vouch batch rewrote it once per vouch, up to 16 times, on main;
// - every short peer ID lookup scanned every identity.
//
// The write-count assertions are the real gate. perf-floors.json keeps
// loose floors that still sit far above the regression values.
//

import XCTest
import BitFoundation
@testable import bitchat

extension PerformanceBaselineTests {
    private static let identityCount = 2_000

    // MARK: - Identity: known-peer upsert

    /// Verified re-announces of known, unchanged peers: most announces.
    func testIdentityUpsertKnownPeer() throws {
        let fixture = try IdentityCacheFixture(count: Self.identityCount)
        let manager = SecureIdentityStateManager(fixture.keychain)
        let strangers = fixture.strangers
        let upserts = 25_000
        func upsert(_ index: Int) {
            let stranger = strangers[index % strangers.count]
            manager.upsertCryptographicIdentity(
                fingerprint: stranger.fingerprint,
                noisePublicKey: stranger.noisePublicKey,
                signingPublicKey: stranger.signingPublicKey,
                claimedNickname: stranger.nickname
            )
        }
        for index in strangers.indices {
            upsert(index)
        }
        let writesBefore = fixture.cacheSaveCount
        var samples: [TimeInterval] = []

        measure {
            let start = Date()
            for index in 0..<upserts {
                upsert(index)
            }
            samples.append(Date().timeIntervalSince(start))
        }

        XCTAssertEqual(fixture.cacheSaveCount, writesBefore, "unchanged re-announces must not rewrite the identity cache")
        reportThroughput("identity.upsertKnownPeer", samples: samples, operations: upserts, unit: "upserts")
    }

    // MARK: - Identity: vouch batch

    /// One full vouch batch from a verified voucher. Every pass carries
    /// strictly newer timestamps, so every vouch is a real change: the same
    /// voucher's next batch, a day later.
    func testIdentityVouchBatch() throws {
        let fixture = try IdentityCacheFixture(count: Self.identityCount)
        let manager = SecureIdentityStateManager(fixture.keychain)
        let voucher = fixture.strangers[0].fingerprint
        manager.setVerified(fingerprint: voucher, verified: true)
        let vouchees = fixture.strangers[1...VouchAttestation.maxBatchCount].map(\.fingerprint)
        let firstBatch = Date()
        var pass = 0
        let writesBefore = fixture.cacheSaveCount
        var samples: [TimeInterval] = []

        measure {
            pass += 1
            let timestamp = firstBatch.addingTimeInterval(TimeInterval(pass))
            let batch = vouchees.map { (voucheeFingerprint: $0, timestamp: timestamp) }
            let start = Date()
            let stored = manager.recordVouches(batch, voucherFingerprint: voucher, now: timestamp)
            samples.append(Date().timeIntervalSince(start))
            XCTAssertEqual(stored, vouchees.count)
        }

        XCTAssertEqual(fixture.cacheSaveCount - writesBefore, samples.count, "a vouch batch must cost one identity-cache write")
        reportThroughput("identity.vouchBatch", samples: samples, operations: 1, unit: "batches")
    }

    // MARK: - Identity: lookup by short peer ID

    /// Short peer ID lookups: DM headers, signed-sender attribution and the
    /// persisted signing-key pin consulted by announce handling.
    func testIdentityLookupByPeerIDPrefix() throws {
        let fixture = try IdentityCacheFixture(count: Self.identityCount)
        let manager = SecureIdentityStateManager(fixture.keychain)
        let peerIDs = fixture.strangers.map { PeerID(publicKey: $0.noisePublicKey) }
        let lookups = 20_000
        var samples: [TimeInterval] = []

        measure {
            var found = 0
            let start = Date()
            for index in 0..<lookups {
                found += manager.getCryptoIdentitiesByPeerIDPrefix(peerIDs[index % peerIDs.count]).count
            }
            samples.append(Date().timeIntervalSince(start))
            XCTAssertEqual(found, lookups)
        }

        reportThroughput("identity.lookupByPeerIDPrefix", samples: samples, operations: lookups, unit: "lookups")
    }
}

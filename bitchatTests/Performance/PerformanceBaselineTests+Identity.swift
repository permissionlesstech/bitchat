//
// PerformanceBaselineTests+Identity.swift
// bitchatTests
//
// Identity-cache benchmarks at 2,000 known identities. Each guards a cost
// that used to grow with the number of identities C:
//
// - every verified announce rewrote the whole encrypted cache (JSON encode,
//   AES-GCM seal, keychain delete and add), even when nothing had changed.
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
}

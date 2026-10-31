//
// PrekeyBundleStoreTests.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
import CryptoKit
import BitFoundation
@testable import bitchat

/// Sender-side cache of peers' verified prekey bundles: latest-wins ingest,
/// per-message prekey assignment (never reused across messages), expiry, and
/// the peer cap.
struct PrekeyBundleStoreTests {

    private func makeBundle(
        noiseKey: Data = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
        ids: [UInt32] = [0, 1, 2],
        generatedAt: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)
    ) -> PrekeyBundle {
        PrekeyBundle(
            noiseStaticPublicKey: noiseKey,
            prekeys: ids.map { PrekeyBundle.Prekey(id: $0, publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation) },
            generatedAt: generatedAt,
            signature: Data(count: PrekeyBundle.signatureLength)
        )
    }

    @Test func ingestKeepsLatestByGeneratedAt() {
        let store = PrekeyBundleStore(persistsToDisk: false)
        let noiseKey = Data(repeating: 0xB0, count: 32)
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)

        let old = makeBundle(noiseKey: noiseKey, ids: [0, 1], generatedAt: nowMs - 1000)
        let new = makeBundle(noiseKey: noiseKey, ids: [2, 3], generatedAt: nowMs)

        #expect(store.ingest(new))
        // Older (and equal) bundles never displace a newer one.
        #expect(!store.ingest(old))
        #expect(!store.ingest(new))

        let assigned = store.assignPrekey(messageID: "m1", recipientNoiseKey: noiseKey)
        #expect(assigned?.id == 2)
    }

    @Test func assignmentsConsumeDistinctPrekeysPerMessage() {
        let store = PrekeyBundleStore(persistsToDisk: false)
        let noiseKey = Data(repeating: 0xB1, count: 32)
        #expect(store.ingest(makeBundle(noiseKey: noiseKey, ids: [10, 11])))

        let first = store.assignPrekey(messageID: "m1", recipientNoiseKey: noiseKey)
        let second = store.assignPrekey(messageID: "m2", recipientNoiseKey: noiseKey)
        #expect(first?.id == 10)
        #expect(second?.id == 11)
        // Exhausted: fall back to static sealing.
        #expect(store.assignPrekey(messageID: "m3", recipientNoiseKey: noiseKey) == nil)
        #expect(!store.hasUsableBundle(for: noiseKey))
    }

    @Test func redepositOfSameMessageReusesItsPrekey() {
        let store = PrekeyBundleStore(persistsToDisk: false)
        let noiseKey = Data(repeating: 0xB2, count: 32)
        #expect(store.ingest(makeBundle(noiseKey: noiseKey, ids: [5, 6, 7])))

        let first = store.assignPrekey(messageID: "m1", recipientNoiseKey: noiseKey)
        let retry = store.assignPrekey(messageID: "m1", recipientNoiseKey: noiseKey)
        #expect(first?.id == retry?.id)
        #expect(first?.publicKey == retry?.publicKey)
        // Only one prekey was burned.
        let next = store.assignPrekey(messageID: "m2", recipientNoiseKey: noiseKey)
        #expect(next?.id == 6)
    }

    @Test func topUpBundleKeepsConsumptionStateForSurvivingIDs() {
        let store = PrekeyBundleStore(persistsToDisk: false)
        let noiseKey = Data(repeating: 0xB3, count: 32)
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        #expect(store.ingest(makeBundle(noiseKey: noiseKey, ids: [0, 1], generatedAt: nowMs - 1000)))
        #expect(store.assignPrekey(messageID: "m1", recipientNoiseKey: noiseKey)?.id == 0)

        // The owner topped up: ID 1 survives (still unconsumed on their side),
        // ID 0 rotated out, new IDs appear.
        #expect(store.ingest(makeBundle(noiseKey: noiseKey, ids: [1, 8, 9], generatedAt: nowMs)))
        // m1's assignment referenced a rotated-out ID; a re-deposit picks a
        // fresh one rather than sealing to a dead key.
        #expect(store.assignPrekey(messageID: "m1", recipientNoiseKey: noiseKey)?.id == 1)
        #expect(store.assignPrekey(messageID: "m2", recipientNoiseKey: noiseKey)?.id == 8)
    }

    @Test func expiredBundleIsNeverUsed() {
        var current = Date()
        let store = PrekeyBundleStore(persistsToDisk: false, now: { current })
        let noiseKey = Data(repeating: 0xB4, count: 32)
        #expect(store.ingest(makeBundle(noiseKey: noiseKey, generatedAt: UInt64(current.timeIntervalSince1970 * 1000))))
        #expect(store.hasUsableBundle(for: noiseKey))

        current = current.addingTimeInterval(PrekeyBundleStore.Limits.maxBundleAgeForSealingSeconds + 60)
        #expect(!store.hasUsableBundle(for: noiseKey))
        #expect(store.assignPrekey(messageID: "m1", recipientNoiseKey: noiseKey) == nil)
    }

    @Test func peerCapEvictsLeastRecentlyUpdated() {
        var current = Date()
        let store = PrekeyBundleStore(persistsToDisk: false, maxPeers: 2, now: { current })
        let keys = (0..<3).map { Data(repeating: UInt8(0xC0 + $0), count: 32) }

        for key in keys {
            #expect(store.ingest(makeBundle(noiseKey: key, generatedAt: UInt64(current.timeIntervalSince1970 * 1000))))
            current = current.addingTimeInterval(1)
        }
        // Oldest entry evicted; the two most recent survive.
        #expect(!store.hasUsableBundle(for: keys[0]))
        #expect(store.hasUsableBundle(for: keys[1]))
        #expect(store.hasUsableBundle(for: keys[2]))
    }

    private func panicBundle(noiseKey: Data, generatedAt: UInt64) -> PrekeyBundle {
        PrekeyBundle(
            noiseStaticPublicKey: noiseKey,
            prekeys: [.init(id: 1, publicKey: Data(repeating: 0x41, count: 32))],
            generatedAt: generatedAt,
            signature: Data(count: PrekeyBundle.signatureLength)
        )
    }

    @Test func deniedPanicDeletionClearsMemoryAndRetriesWithoutRemovingSibling() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("prekey-panic-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? fm.removeItem(at: root)
        }
        let file = root.appendingPathComponent("bundles.json")
        let sibling = root.appendingPathComponent("keep.txt")
        let siblingBytes = Data("SYNTHETIC_UNRELATED_FILE".utf8)
        try siblingBytes.write(to: sibling)
        let current = Date(timeIntervalSince1970: 1_800_000_000)
        let noiseKey = Data(repeating: 0xD1, count: 32)
        let store = PrekeyBundleStore(fileURL: file, now: { current })
        #expect(store.ingest(panicBundle(noiseKey: noiseKey, generatedAt: 1_800_000_000_000)))
        let original = try Data(contentsOf: file)
        #expect(PrekeyBundleStore(fileURL: file, now: { current }).hasUsableBundle(for: noiseKey))

        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        #expect(!store.wipe(), "Denied prekey file removal must be reported")
        #expect(!store.hasUsableBundle(for: noiseKey), "Prekey memory must clear even when file removal fails")
        #expect(store.assignPrekey(messageID: "synthetic-after-wipe", recipientNoiseKey: noiseKey) == nil)
        #expect(try Data(contentsOf: file) == original)
        #expect(PrekeyBundleStore(fileURL: file, now: { current }).hasUsableBundle(for: noiseKey))
        #expect(try Data(contentsOf: sibling) == siblingBytes)

        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        #expect(store.wipe(), "Prekey deletion must succeed after access is restored")
        #expect(!fm.fileExists(atPath: file.path))
        #expect(store.wipe(), "An absent prekey file must count as successful cleanup")
        #expect(try Data(contentsOf: sibling) == siblingBytes)
    }

    @Test func unresolvedPanicLocationRetriesAndRetainsRecoveredPersistenceLocation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("prekey-location-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("bundles.json")
        let current = Date(timeIntervalSince1970: 1_800_000_000)
        let oldKey = Data(repeating: 0xD2, count: 32)
        let freshKey = Data(repeating: 0xD3, count: 32)
        let seed = PrekeyBundleStore(fileURL: file, now: { current })
        #expect(seed.ingest(panicBundle(noiseKey: oldKey, generatedAt: 1_800_000_000_000)))
        let original = try Data(contentsOf: file)
        var available = false
        var lookups = 0
        let store = PrekeyBundleStore(now: { current }, resolveDefaultFileURL: {
            lookups += 1
            return available ? file : nil
        })
        #expect(lookups == 1)
        #expect(store.ingest(panicBundle(noiseKey: oldKey, generatedAt: 1_800_000_000_000)))
        #expect(!store.wipe(), "An unresolved persistent prekey location must fail cleanup")
        #expect(lookups == 2, "Panic must retry the unresolved prekey location")
        #expect(!store.hasUsableBundle(for: oldKey))
        #expect(try Data(contentsOf: file) == original)

        available = true
        #expect(store.wipe(), "A later panic attempt must resolve and remove the prekey file")
        #expect(lookups == 3)
        #expect(!fm.fileExists(atPath: file.path))
        available = false
        #expect(store.ingest(panicBundle(noiseKey: freshKey, generatedAt: 1_800_000_000_000)))
        #expect(lookups == 3)
        let reopened = PrekeyBundleStore(fileURL: file, now: { current })
        #expect(reopened.hasUsableBundle(for: freshKey), "Fresh bundles must persist at the recovered location")
        #expect(!reopened.hasUsableBundle(for: oldKey))
        #expect(store.wipe())
        #expect(lookups == 3, "The recovered prekey location must remain cached")
        #expect(!fm.fileExists(atPath: file.path))
    }

    @Test func memoryOnlyPanicIgnoresOverrideAndDefaultResolver() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("prekey-memory-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let override = root.appendingPathComponent("override.json")
        let resolved = root.appendingPathComponent("resolved.json")
        let sentinel = Data("SYNTHETIC_UNRELATED_FILE".utf8)
        try sentinel.write(to: override)
        try sentinel.write(to: resolved)
        var lookups = 0
        let current = Date(timeIntervalSince1970: 1_800_000_000)
        let noiseKey = Data(repeating: 0xD4, count: 32)
        let store = PrekeyBundleStore(persistsToDisk: false, fileURL: override, now: { current },
                                     resolveDefaultFileURL: { lookups += 1; return resolved })
        #expect(store.ingest(panicBundle(noiseKey: noiseKey, generatedAt: 1_800_000_000_000)))
        #expect(store.hasUsableBundle(for: noiseKey))
        #expect(store.wipe(), "Intentional memory-only prekeys need no disk cleanup")
        #expect(!store.hasUsableBundle(for: noiseKey))
        #expect(store.wipe())
        #expect(lookups == 0, "Memory-only prekeys must not resolve a disk location")
        #expect(try Data(contentsOf: override) == sentinel)
        #expect(try Data(contentsOf: resolved) == sentinel)
    }

    @Test func persistsAcrossInstancesAndWipes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prekey-bundle-store-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = dir.appendingPathComponent("bundles.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        let noiseKey = Data(repeating: 0xB5, count: 32)
        let first = PrekeyBundleStore(fileURL: fileURL)
        #expect(first.ingest(makeBundle(noiseKey: noiseKey, ids: [1, 2])))
        #expect(first.assignPrekey(messageID: "m1", recipientNoiseKey: noiseKey)?.id == 1)

        // Consumption state survives a relaunch, so a restart can't reuse a prekey.
        let second = PrekeyBundleStore(fileURL: fileURL)
        #expect(second.assignPrekey(messageID: "m2", recipientNoiseKey: noiseKey)?.id == 2)

        #expect(second.wipe())
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        let third = PrekeyBundleStore(fileURL: fileURL)
        #expect(!third.hasUsableBundle(for: noiseKey))
    }
}

/// Envelope v2 wire compatibility: the prekey ID rides an optional TLV that
/// v1 decoders skip as unknown.
struct CourierEnvelopeV2Tests {

    @Test func prekeyIDRoundTrips() throws {
        let envelope = CourierEnvelope(
            recipientTag: Data(repeating: 0x11, count: CourierEnvelope.tagLength),
            expiry: UInt64(Date().timeIntervalSince1970 * 1000) + 60_000,
            ciphertext: Data("ciphertext".utf8),
            copies: 4,
            prekeyID: 0xAABB_CCDD
        )
        let encoded = try #require(envelope.encode())
        let decoded = try #require(CourierEnvelope.decode(encoded))
        #expect(decoded == envelope)
        #expect(decoded.prekeyID == 0xAABB_CCDD)
    }

    @Test func v1EnvelopeDecodesWithNilPrekeyID() throws {
        let envelope = CourierEnvelope(
            recipientTag: Data(repeating: 0x22, count: CourierEnvelope.tagLength),
            expiry: UInt64(Date().timeIntervalSince1970 * 1000) + 60_000,
            ciphertext: Data("legacy".utf8)
        )
        let encoded = try #require(envelope.encode())
        let decoded = try #require(CourierEnvelope.decode(encoded))
        #expect(decoded.prekeyID == nil)
    }

    @Test func v1EncodingIsByteIdenticalWithoutPrekeyID() throws {
        // Static-sealed envelopes must stay on the pre-prekey wire format.
        let tag = Data(repeating: 0x33, count: CourierEnvelope.tagLength)
        let expiry: UInt64 = 1_800_000_000_000
        let ciphertext = Data("same".utf8)
        let v1 = try #require(CourierEnvelope(recipientTag: tag, expiry: expiry, ciphertext: ciphertext).encode())
        let v1Explicit = try #require(CourierEnvelope(recipientTag: tag, expiry: expiry, ciphertext: ciphertext, prekeyID: nil).encode())
        #expect(v1 == v1Explicit)
        // And a v2 envelope is the v1 bytes plus one trailing TLV a v1
        // decoder skips as unknown.
        let v2 = try #require(CourierEnvelope(recipientTag: tag, expiry: expiry, ciphertext: ciphertext, prekeyID: 7).encode())
        #expect(v2.prefix(v1.count) == v1)
        #expect(v2.count == v1.count + 3 + 4)
    }

    @Test func withCopiesPreservesPrekeyID() {
        let envelope = CourierEnvelope(
            recipientTag: Data(repeating: 0x44, count: CourierEnvelope.tagLength),
            expiry: 1,
            ciphertext: Data([0x01]),
            copies: 4,
            prekeyID: 9
        )
        #expect(envelope.withCopies(2).prekeyID == 9)
    }
}

//
// NoisePrekeyTests.swift
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

/// Forward-secret one-way Noise X envelopes sealed to one-time prekeys
/// instead of the recipient's identity static key.
struct NoisePrekeyTests {

    @Test func sealAndOpenRoundTrip() throws {
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bob = NoiseEncryptionService(keychain: MockKeychain())
        let bundle = try #require(bob.currentPrekeyBundle())
        let prekey = try #require(bundle.prekeys.first)

        let payload = Data("meet at the north gate".utf8)
        let sealed = try alice.sealPrekeyPayload(payload, recipientPrekey: prekey)

        let opened = try bob.openPrekeyPayload(sealed, prekeyID: prekey.id)
        #expect(opened.payload == payload)
        // The X pattern authenticates the sender: Bob learns Alice's real static key.
        #expect(opened.senderStaticKey == alice.getStaticPublicKeyData())
    }

    @Test func wrongPrekeyIDCannotOpen() throws {
        // The prologue binds the ciphertext to a specific prekey ID; opening
        // with a different (existing) prekey must fail.
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bob = NoiseEncryptionService(keychain: MockKeychain())
        let bundle = try #require(bob.currentPrekeyBundle())
        #expect(bundle.prekeys.count >= 2)

        let sealed = try alice.sealPrekeyPayload(Data("secret".utf8), recipientPrekey: bundle.prekeys[0])
        #expect(throws: (any Error).self) {
            _ = try bob.openPrekeyPayload(sealed, prekeyID: bundle.prekeys[1].id)
        }
    }

    @Test func unknownPrekeyIDThrows() throws {
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bob = NoiseEncryptionService(keychain: MockKeychain())
        let bundle = try #require(bob.currentPrekeyBundle())
        let prekey = try #require(bundle.prekeys.first)

        let sealed = try alice.sealPrekeyPayload(Data("secret".utf8), recipientPrekey: prekey)
        #expect(throws: NoiseEncryptionError.unknownPrekey) {
            _ = try bob.openPrekeyPayload(sealed, prekeyID: 0xDEAD_BEEF)
        }
    }

    @Test func wrongRecipientCannotOpen() throws {
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bob = NoiseEncryptionService(keychain: MockKeychain())
        let carol = NoiseEncryptionService(keychain: MockKeychain())
        let bobBundle = try #require(bob.currentPrekeyBundle())
        // Ensure Carol holds a prekey under the same ID as Bob's.
        _ = try #require(carol.currentPrekeyBundle())
        let prekey = try #require(bobBundle.prekeys.first)

        let sealed = try alice.sealPrekeyPayload(Data("secret".utf8), recipientPrekey: prekey)
        #expect(throws: (any Error).self) {
            _ = try carol.openPrekeyPayload(sealed, prekeyID: prekey.id)
        }
    }

    @Test func tamperedCiphertextFailsToOpen() throws {
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bob = NoiseEncryptionService(keychain: MockKeychain())
        let bundle = try #require(bob.currentPrekeyBundle())
        let prekey = try #require(bundle.prekeys.first)

        var sealed = try alice.sealPrekeyPayload(Data("secret".utf8), recipientPrekey: prekey)
        sealed[sealed.count - 1] ^= 0x01
        #expect(throws: (any Error).self) {
            _ = try bob.openPrekeyPayload(sealed, prekeyID: prekey.id)
        }
    }

    @Test func consumedPrekeyStillOpensRedeliveredCiphertext() throws {
        // Spray-and-wait can deliver the same ciphertext via several couriers
        // days apart; the consumed private survives a grace window for that.
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bob = NoiseEncryptionService(keychain: MockKeychain())
        let bundle = try #require(bob.currentPrekeyBundle())
        let prekey = try #require(bundle.prekeys.first)

        let sealed = try alice.sealPrekeyPayload(Data("hello".utf8), recipientPrekey: prekey)
        let first = try bob.openPrekeyPayload(sealed, prekeyID: prekey.id)
        let second = try bob.openPrekeyPayload(sealed, prekeyID: prekey.id)
        #expect(first.payload == second.payload)
    }

    @Test func prekeyAndStaticSealsAreNotInterchangeable() throws {
        // Domain-separated prologues: a static-sealed envelope must not open
        // via the prekey path and vice versa, even with matching key material.
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bob = NoiseEncryptionService(keychain: MockKeychain())
        let bundle = try #require(bob.currentPrekeyBundle())
        let prekey = try #require(bundle.prekeys.first)

        let staticSealed = try alice.sealCourierPayload(Data("x".utf8), recipientStaticKey: bob.getStaticPublicKeyData())
        #expect(throws: (any Error).self) {
            _ = try bob.openPrekeyPayload(staticSealed, prekeyID: prekey.id)
        }

        let prekeySealed = try alice.sealPrekeyPayload(Data("x".utf8), recipientPrekey: prekey)
        #expect(throws: (any Error).self) {
            _ = try bob.openCourierPayload(prekeySealed)
        }
    }

    @Test func sealRejectsInvalidPrekeyPublicKey() {
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        #expect(throws: (any Error).self) {
            _ = try alice.sealPrekeyPayload(Data("x".utf8), recipientPrekey: PrekeyBundle.Prekey(id: 1, publicKey: Data(repeating: 0, count: 32)))
        }
        #expect(throws: (any Error).self) {
            _ = try alice.sealPrekeyPayload(Data("x".utf8), recipientPrekey: PrekeyBundle.Prekey(id: 1, publicKey: Data(repeating: 1, count: 8)))
        }
    }

    @Test func sealsAreNotLinkableAcrossSends() throws {
        // Fresh ephemeral per seal even to the same prekey.
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bob = NoiseEncryptionService(keychain: MockKeychain())
        let bundle = try #require(bob.currentPrekeyBundle())
        let prekey = try #require(bundle.prekeys.first)
        let payload = Data("same message".utf8)

        let a = try alice.sealPrekeyPayload(payload, recipientPrekey: prekey)
        let b = try alice.sealPrekeyPayload(payload, recipientPrekey: prekey)
        #expect(a != b)
        #expect(a.prefix(32) != b.prefix(32))
    }
}

/// Local one-time prekey lifecycle: batch generation, consumption, the 48h
/// redelivery grace window, replenishment, and the panic wipe.
struct LocalPrekeyStoreTests {

    private final class Clock {
        var now: Date
        init(_ now: Date = Date()) { self.now = now }
    }

    private func makeStore(clock: Clock, keychain: MockKeychain = MockKeychain()) -> LocalPrekeyStore {
        LocalPrekeyStore(keychain: keychain, now: { clock.now })
    }

    private func bundle(noiseKey: Data, prekeys: [PrekeyBundle.Prekey], generatedAt: UInt64) -> PrekeyBundle {
        PrekeyBundle(
            noiseStaticPublicKey: noiseKey,
            prekeys: prekeys,
            generatedAt: generatedAt,
            signature: Data(count: PrekeyBundle.signatureLength)
        )
    }

    @Test func mintsFullBatchOnFirstUse() {
        let store = makeStore(clock: Clock())
        let (prekeys, generatedAt) = store.currentBundlePrekeys()
        #expect(prekeys.count == LocalPrekeyStore.Policy.batchSize)
        #expect(generatedAt > 0)
        #expect(Set(prekeys.map(\.id)).count == prekeys.count)
    }

    @Test func consumptionBelowThresholdTriggersReplenishAndBumpsGeneration() {
        let clock = Clock()
        let store = makeStore(clock: clock)
        let (initial, firstGeneratedAt) = store.currentBundlePrekeys()

        // Consuming down to the threshold does not regenerate...
        let keepUnconsumed = LocalPrekeyStore.Policy.replenishThreshold
        for prekey in initial.dropLast(keepUnconsumed) {
            store.markConsumed(prekey.id)
        }
        #expect(!store.replenishIfNeeded())
        #expect(store.unconsumedCount == keepUnconsumed)

        // ...one more consumption does, topping back up to a full batch with
        // a newer generation stamp.
        clock.now = clock.now.addingTimeInterval(60)
        store.markConsumed(initial[initial.count - keepUnconsumed].id)
        #expect(store.replenishIfNeeded())
        let (replenished, secondGeneratedAt) = store.currentBundlePrekeys()
        #expect(replenished.count == LocalPrekeyStore.Policy.batchSize)
        #expect(secondGeneratedAt > firstGeneratedAt)
        // Surviving unconsumed prekeys stay in the fresh bundle.
        let survivorIDs = Set(initial.suffix(keepUnconsumed - 1).map(\.id))
        #expect(survivorIDs.isSubset(of: Set(replenished.map(\.id))))
    }

    @Test func consumingAPrekeyRepublishesANewerBundlePeersAccept() {
        // Codex P1: consuming a prekey (even above the replenish threshold)
        // must republish a strictly newer bundle so a peer that cached the old
        // one replaces it and stops assigning the consumed ID before its 48h
        // grace lapses.
        let clock = Clock()
        let store = makeStore(clock: clock)
        let noiseKey = Data(repeating: 0xC0, count: 32)

        // Owner publishes; a peer caches it and would assign the first prekey.
        let (initial, firstGeneratedAt) = store.currentBundlePrekeys()
        let peerCache = PrekeyBundleStore(persistsToDisk: false)
        #expect(peerCache.ingest(bundle(noiseKey: noiseKey, prekeys: initial, generatedAt: firstGeneratedAt)))
        let consumedID = initial[0].id
        #expect(peerCache.assignPrekey(messageID: "m1", recipientNoiseKey: noiseKey)?.id == consumedID)

        // The owner opens mail sealed to that prekey: it's retired and the
        // republished bundle is strictly newer and no longer offers the ID.
        #expect(store.markConsumed(consumedID))
        let (afterConsume, secondGeneratedAt) = store.currentBundlePrekeys()
        #expect(secondGeneratedAt > firstGeneratedAt)
        #expect(!afterConsume.contains { $0.id == consumedID })

        // The peer accepts the replacement (a same-generatedAt copy would be
        // rejected) and stops assigning the consumed ID for new mail.
        #expect(peerCache.ingest(bundle(noiseKey: noiseKey, prekeys: afterConsume, generatedAt: secondGeneratedAt)))
        #expect(peerCache.assignPrekey(messageID: "m2", recipientNoiseKey: noiseKey)?.id != consumedID)

        // 48h grace: the owner can still open a redelivery of the in-flight
        // ciphertext sealed to the consumed ID until the window lapses.
        clock.now = clock.now.addingTimeInterval(LocalPrekeyStore.Policy.consumedGraceSeconds - 60)
        #expect(store.privateKey(for: consumedID) != nil)
        clock.now = clock.now.addingTimeInterval(120)
        #expect(store.privateKey(for: consumedID) == nil)
    }

    @Test func consumedPrivateSurvivesGraceWindowThenDies() {
        let clock = Clock()
        let store = makeStore(clock: clock)
        let (prekeys, _) = store.currentBundlePrekeys()
        let id = prekeys[0].id

        store.markConsumed(id)
        // Within the grace window: still retrievable for redeliveries.
        clock.now = clock.now.addingTimeInterval(LocalPrekeyStore.Policy.consumedGraceSeconds - 60)
        #expect(store.privateKey(for: id) != nil)

        // Past the grace window: gone (even before replenish prunes it).
        clock.now = clock.now.addingTimeInterval(120)
        #expect(store.privateKey(for: id) == nil)
        store.replenishIfNeeded()
        #expect(store.privateKey(for: id) == nil)
    }

    @Test func persistsAcrossInstances() {
        let keychain = MockKeychain()
        let clock = Clock()
        let first = LocalPrekeyStore(keychain: keychain, now: { clock.now })
        let (prekeys, generatedAt) = first.currentBundlePrekeys()
        first.markConsumed(prekeys[0].id)

        let second = LocalPrekeyStore(keychain: keychain, now: { clock.now })
        let (reloaded, reloadedGeneratedAt) = second.currentBundlePrekeys()
        // Consuming a prekey shrinks the published bundle, so its generation
        // stamp advances strictly (even without the clock moving) — peers must
        // see a newer bundle to replace the one that still offered the
        // consumed ID.
        #expect(reloadedGeneratedAt > generatedAt)
        #expect(Set(reloaded.map(\.id)) == Set(prekeys.dropFirst().map(\.id)))
        // The consumed key is still openable within grace after a relaunch.
        #expect(second.privateKey(for: prekeys[0].id) != nil)
    }

    @Test func wipeRemovesEverything() {
        let keychain = MockKeychain()
        let store = LocalPrekeyStore(keychain: keychain)
        let (prekeys, _) = store.currentBundlePrekeys()
        store.wipe()
        #expect(store.privateKey(for: prekeys[0].id) == nil)
        #expect(keychain.getIdentityKey(forKey: "prekeysV1") == nil)
    }
}

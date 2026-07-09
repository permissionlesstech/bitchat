//
// BridgeCourierServiceTests.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import CryptoKit
import Foundation
import Testing
@testable import bitchat

@Suite("Courier over the bridge")
@MainActor
struct BridgeCourierServiceTests {
    /// Closure-injected harness around `BridgeCourierService`.
    @MainActor
    private final class Fixture {
        var bridgeOn = true
        var relaysConnected = true
        var myKey: Data? = Fixture.randomKey()
        var localPeers: [(peerID: PeerID, noiseKey: Data)] = []
        var held: [CourierEnvelope] = []
        var sealResult: CourierEnvelope?

        private(set) var publishedEvents: [NostrEvent] = []
        private(set) var openedSubscriptions: [[String]] = []
        private(set) var closedSubscriptions = 0
        private(set) var openedEnvelopes: [CourierEnvelope] = []
        private(set) var delivered: [(envelope: CourierEnvelope, peer: PeerID)] = []
        private(set) var sealRequests: [(content: String, messageID: String, key: Data)] = []
        private(set) var heldCooldowns: [TimeInterval] = []

        let service: BridgeCourierService

        init(dedupStore: BridgeDropDedupStore? = nil) {
            service = BridgeCourierService(dedupStore: dedupStore)
            service.bridgeEnabled = { [weak self] in self?.bridgeOn ?? false }
            service.relaysConnected = { [weak self] in self?.relaysConnected ?? false }
            service.publishEvent = { [weak self] event in self?.publishedEvents.append(event) }
            service.openSubscription = { [weak self] tags in self?.openedSubscriptions.append(tags) }
            service.closeSubscription = { [weak self] in self?.closedSubscriptions += 1 }
            service.myNoiseKey = { [weak self] in self?.myKey }
            service.localVerifiedPeers = { [weak self] in self?.localPeers ?? [] }
            service.sealEnvelope = { [weak self] content, messageID, key in
                self?.sealRequests.append((content, messageID, key))
                return self?.sealResult
            }
            service.openEnvelope = { [weak self] envelope in self?.openedEnvelopes.append(envelope) }
            service.deliverToPeer = { [weak self] envelope, peer in self?.delivered.append((envelope, peer)) }
            service.heldEnvelopes = { [weak self] cooldown in
                self?.heldCooldowns.append(cooldown)
                return self?.held ?? []
            }
            service.scheduleTimer = { _, _ in } // timers driven manually
        }

        static func randomKey() -> Data {
            Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        }
    }

    private func makeEnvelope(recipientKey: Data, ciphertext: Data = Data(repeating: 7, count: 64)) -> CourierEnvelope {
        CourierEnvelope(
            recipientTag: CourierEnvelope.recipientTag(
                noiseStaticKey: recipientKey,
                epochDay: CourierEnvelope.epochDay(for: Date())
            ),
            expiry: UInt64((Date().timeIntervalSince1970 + 3600) * 1000),
            ciphertext: ciphertext,
            copies: 1
        )
    }

    private func makeDropEvent(for envelope: CourierEnvelope) throws -> NostrEvent {
        let encoded = try #require(envelope.encode())
        let identity = try #require(BridgeCourierService.makeThrowawayIdentity())
        return try NostrProtocol.createCourierDropEvent(
            envelope: encoded,
            recipientTagHex: envelope.recipientTag.hexEncodedString(),
            expiresAt: Date(timeIntervalSince1970: TimeInterval(envelope.expiry) / 1000),
            senderIdentity: identity
        )
    }

    // MARK: - Sender role

    @Test func depositSealsAndPublishesOnce() throws {
        let fixture = Fixture()
        let recipientKey = Fixture.randomKey()
        fixture.sealResult = makeEnvelope(recipientKey: recipientKey)
        let messageID = UUID().uuidString

        fixture.service.depositDrop(content: "hello", messageID: messageID, recipientNoiseKey: recipientKey)
        fixture.service.depositDrop(content: "hello", messageID: messageID, recipientNoiseKey: recipientKey)

        #expect(fixture.sealRequests.count == 1)
        #expect(fixture.publishedEvents.count == 1)
        let event = try #require(fixture.publishedEvents.first)
        #expect(event.kind == NostrProtocol.EventKind.courierDrop.rawValue)
        #expect(event.isValidSignature())
        #expect(event.tags.contains { $0.count >= 2 && $0[0] == "x" && $0[1] == fixture.sealResult?.recipientTag.hexEncodedString() })
        #expect(event.tags.contains { $0.count >= 2 && $0[0] == "expiration" })
    }

    @Test func depositRequiresBridgeToggle() {
        let fixture = Fixture()
        fixture.bridgeOn = false
        let key = Fixture.randomKey()
        fixture.sealResult = makeEnvelope(recipientKey: key)

        fixture.service.depositDrop(content: "hi", messageID: UUID().uuidString, recipientNoiseKey: key)

        #expect(fixture.publishedEvents.isEmpty)
        #expect(fixture.sealRequests.isEmpty)
    }

    @Test func depositQueuesWithoutRelaysAndFlushesOnReconnect() {
        let fixture = Fixture()
        fixture.relaysConnected = false
        let key = Fixture.randomKey()
        fixture.sealResult = makeEnvelope(recipientKey: key)

        fixture.service.depositDrop(content: "later", messageID: UUID().uuidString, recipientNoiseKey: key)
        #expect(fixture.publishedEvents.isEmpty)
        #expect(fixture.service.pendingDrops.count == 1)

        fixture.relaysConnected = true
        fixture.service.flushPendingDrops()
        #expect(fixture.publishedEvents.count == 1)
        #expect(fixture.service.pendingDrops.isEmpty)
    }

    @Test func evictedPendingDropStaysRetryable() {
        // Regression: a drop queued while relays are down but then evicted
        // (oldest-out at capacity) before it ever published must release its
        // sender-side dedup slot, or the router marks it "carried" and can
        // never re-deposit it.
        let fixture = Fixture()
        fixture.relaysConnected = false
        let key = Fixture.randomKey()
        fixture.sealResult = makeEnvelope(recipientKey: key)

        let firstID = UUID().uuidString
        #expect(fixture.service.depositDrop(content: "0", messageID: firstID, recipientNoiseKey: key))
        // Fill past capacity so the first drop is evicted.
        for i in 1...BridgeCourierService.Limits.maxPendingDrops {
            fixture.service.depositDrop(content: "\(i)", messageID: UUID().uuidString, recipientNoiseKey: key)
        }
        #expect(fixture.service.pendingDrops.count == BridgeCourierService.Limits.maxPendingDrops)

        // The evicted first drop is deposit-able again (slot released).
        #expect(fixture.service.depositDrop(content: "0-retry", messageID: firstID, recipientNoiseKey: key))
    }

    @Test func oversizeDropConsumesSlotInsteadOfChurning() {
        // An envelope that encodes over the size cap fails identically on
        // every attempt; the dedup slot must be consumed so the retry sweep
        // doesn't re-run Noise sealing forever.
        let fixture = Fixture()
        let key = Fixture.randomKey()
        fixture.sealResult = makeEnvelope(
            recipientKey: key,
            ciphertext: Data(repeating: 7, count: BridgeCourierService.Limits.maxDropEnvelopeBytes + 1)
        )
        let messageID = UUID().uuidString

        #expect(!fixture.service.depositDrop(content: "big", messageID: messageID, recipientNoiseKey: key))
        #expect(fixture.publishedEvents.isEmpty)

        // The retry sweep must not seal the same payload again.
        #expect(!fixture.service.depositDrop(content: "big", messageID: messageID, recipientNoiseKey: key))
        #expect(fixture.sealRequests.count == 1)
    }

    @Test func publishedDropDedupSurvivesRelaunch() throws {
        // Regression (field-verified amplification storm): the outbox that
        // drives re-deposits is persisted, but the sender-side drop dedup was
        // in-memory only — every relaunch republished the same undelivered
        // message as a fresh drop, and relays hold each for 24h.
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-dedup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let recipientKey = Fixture.randomKey()
        let messageID = UUID().uuidString

        let fixture = Fixture(dedupStore: BridgeDropDedupStore(fileURL: fileURL))
        fixture.sealResult = makeEnvelope(recipientKey: recipientKey)
        #expect(fixture.service.depositDrop(content: "hello", messageID: messageID, recipientNoiseKey: recipientKey))
        #expect(fixture.publishedEvents.count == 1)

        // "Relaunch": a fresh service over the same store must refuse to
        // publish the same message ID again (before even re-sealing it).
        let relaunched = Fixture(dedupStore: BridgeDropDedupStore(fileURL: fileURL))
        relaunched.sealResult = makeEnvelope(recipientKey: recipientKey)
        #expect(!relaunched.service.depositDrop(content: "hello", messageID: messageID, recipientNoiseKey: recipientKey))
        #expect(relaunched.publishedEvents.isEmpty)
        #expect(relaunched.sealRequests.isEmpty)
    }

    @Test func seenDropEventDedupSurvivesRelaunch() throws {
        // Same storm, gateway side: relays redeliver the whole 24h drop
        // backlog on every launch; a relaunch must not re-open (and re-ack)
        // events it already handled.
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-dedup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let fixture = Fixture(dedupStore: BridgeDropDedupStore(fileURL: fileURL))
        let myKey = try #require(fixture.myKey)
        fixture.service.refresh()
        let event = try makeDropEvent(for: makeEnvelope(recipientKey: myKey))
        fixture.service.handleDropEvent(event)
        #expect(fixture.openedEnvelopes.count == 1)

        let relaunched = Fixture(dedupStore: BridgeDropDedupStore(fileURL: fileURL))
        relaunched.myKey = myKey
        relaunched.service.refresh()
        relaunched.service.handleDropEvent(event)
        #expect(relaunched.openedEnvelopes.isEmpty)
    }

    @Test func distinctDropsUseDistinctThrowawayKeys() {
        let fixture = Fixture()
        let keyA = Fixture.randomKey()
        let keyB = Fixture.randomKey()
        fixture.sealResult = makeEnvelope(recipientKey: keyA)
        fixture.service.depositDrop(content: "a", messageID: UUID().uuidString, recipientNoiseKey: keyA)
        fixture.sealResult = makeEnvelope(recipientKey: keyB)
        fixture.service.depositDrop(content: "b", messageID: UUID().uuidString, recipientNoiseKey: keyB)

        #expect(fixture.publishedEvents.count == 2)
        #expect(fixture.publishedEvents[0].pubkey != fixture.publishedEvents[1].pubkey)
    }

    @Test func bridgingPublishesHeldEnvelopesWithCooldown() {
        let fixture = Fixture()
        fixture.held = [makeEnvelope(recipientKey: Fixture.randomKey())]

        fixture.service.publishHeldEnvelopes()

        #expect(fixture.publishedEvents.count == 1)
        #expect(fixture.heldCooldowns == [BridgeCourierService.Limits.heldEnvelopePublishCooldown])
    }

    // MARK: - Subscription management

    @Test func refreshSubscribesOwnCandidateTags() throws {
        let fixture = Fixture()
        fixture.service.refresh()

        let tags = try #require(fixture.openedSubscriptions.last)
        let myKey = try #require(fixture.myKey)
        let expected = Set(CourierEnvelope.candidateTags(noiseStaticKey: myKey, around: Date()).map { $0.hexEncodedString() })
        #expect(Set(tags) == expected)
        #expect(tags.count == 3) // adjacent UTC days
    }

    @Test func refreshAlsoWatchesLocalVerifiedPeers() throws {
        let fixture = Fixture()
        let peerKey = Fixture.randomKey()
        fixture.localPeers = [(PeerID(str: "aabbccdd00112233"), peerKey)]

        fixture.service.refresh()

        let tags = try #require(fixture.openedSubscriptions.last)
        #expect(tags.count == 6) // 3 own + 3 watched
    }

    @Test func refreshClosesSubscriptionWhenBridgeOff() {
        let fixture = Fixture()
        fixture.service.refresh()
        #expect(fixture.openedSubscriptions.count == 1)

        fixture.bridgeOn = false
        fixture.service.refresh()
        #expect(fixture.closedSubscriptions == 1)
    }

    // MARK: - Inbound drops

    @Test func dropForUsIsOpened() throws {
        let fixture = Fixture()
        let myKey = try #require(fixture.myKey)
        fixture.service.refresh()
        let envelope = makeEnvelope(recipientKey: myKey)

        fixture.service.handleDropEvent(try makeDropEvent(for: envelope))

        #expect(fixture.openedEnvelopes.count == 1)
        #expect(fixture.delivered.isEmpty)
    }

    @Test func duplicateDropEventOpensOnce() throws {
        let fixture = Fixture()
        let myKey = try #require(fixture.myKey)
        fixture.service.refresh()
        let event = try makeDropEvent(for: makeEnvelope(recipientKey: myKey))

        fixture.service.handleDropEvent(event)
        fixture.service.handleDropEvent(event)

        #expect(fixture.openedEnvelopes.count == 1)
    }

    @Test func dropForWatchedLocalPeerIsDelivered() throws {
        let fixture = Fixture()
        let peerKey = Fixture.randomKey()
        let peer = PeerID(str: "aabbccdd00112233")
        fixture.localPeers = [(peer, peerKey)]
        fixture.service.refresh()
        let envelope = makeEnvelope(recipientKey: peerKey)

        fixture.service.handleDropEvent(try makeDropEvent(for: envelope))

        #expect(fixture.delivered.count == 1)
        #expect(fixture.delivered.first?.peer == peer)
        #expect(fixture.openedEnvelopes.isEmpty)
    }

    @Test func dropForStrangerIsIgnored() throws {
        let fixture = Fixture()
        fixture.service.refresh()
        let envelope = makeEnvelope(recipientKey: Fixture.randomKey())

        fixture.service.handleDropEvent(try makeDropEvent(for: envelope))

        #expect(fixture.openedEnvelopes.isEmpty)
        #expect(fixture.delivered.isEmpty)
    }

    @Test func mislabeledDropTagIsRejected() throws {
        // The event's filterable #x tag must match the envelope's own tag.
        let fixture = Fixture()
        let myKey = try #require(fixture.myKey)
        fixture.service.refresh()
        let envelope = makeEnvelope(recipientKey: Fixture.randomKey())
        let encoded = try #require(envelope.encode())
        let identity = try #require(BridgeCourierService.makeThrowawayIdentity())
        let mislabeled = try NostrProtocol.createCourierDropEvent(
            envelope: encoded,
            recipientTagHex: CourierEnvelope.recipientTag(
                noiseStaticKey: myKey,
                epochDay: CourierEnvelope.epochDay(for: Date())
            ).hexEncodedString(), // labeled for us, addressed to a stranger
            expiresAt: Date().addingTimeInterval(3600),
            senderIdentity: identity
        )

        fixture.service.handleDropEvent(mislabeled)

        #expect(fixture.openedEnvelopes.isEmpty)
        #expect(fixture.delivered.isEmpty)
    }

    @Test func expiredDropIsIgnored() throws {
        let fixture = Fixture()
        let myKey = try #require(fixture.myKey)
        fixture.service.refresh()
        let expired = CourierEnvelope(
            recipientTag: CourierEnvelope.recipientTag(noiseStaticKey: myKey, epochDay: CourierEnvelope.epochDay(for: Date())),
            expiry: UInt64((Date().timeIntervalSince1970 - 60) * 1000),
            ciphertext: Data(repeating: 1, count: 32),
            copies: 1
        )

        fixture.service.handleDropEvent(try makeDropEvent(for: expired))

        #expect(fixture.openedEnvelopes.isEmpty)
    }
}

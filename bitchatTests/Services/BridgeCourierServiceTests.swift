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
        var deliverResult = true
        var openResult = true
        /// nil leaves the simulated relay confirmation in flight.
        var automaticPublishResult: Bool? = true

        private(set) var publishedEvents: [NostrEvent] = []
        private(set) var openedSubscriptions: [[String]] = []
        private(set) var closedSubscriptions = 0
        private(set) var openedEnvelopes: [CourierEnvelope] = []
        private(set) var delivered: [(envelope: CourierEnvelope, peer: PeerID)] = []
        private(set) var sealRequests: [(content: String, messageID: String, key: Data)] = []
        private(set) var heldCooldowns: [TimeInterval] = []
        private(set) var markedHeldEnvelopes: [CourierEnvelope] = []
        private(set) var scheduledTimers: [(delay: TimeInterval, fire: @MainActor () -> Void)] = []
        private(set) var pendingPublishCompletions: [@MainActor (Bool) -> Void] = []

        let service: BridgeCourierService

        init(now: @escaping () -> Date = Date.init, dedupStore: BridgeDropDedupStore? = nil) {
            service = BridgeCourierService(now: now, dedupStore: dedupStore)
            service.bridgeEnabled = { [weak self] in self?.bridgeOn ?? false }
            service.relaysConnected = { [weak self] in self?.relaysConnected ?? false }
            service.publishEvent = { [weak self] event, completion in
                guard let self else {
                    completion(false)
                    return
                }
                self.publishedEvents.append(event)
                if let result = self.automaticPublishResult {
                    completion(result)
                } else {
                    self.pendingPublishCompletions.append(completion)
                }
            }
            service.openSubscription = { [weak self] tags in self?.openedSubscriptions.append(tags) }
            service.closeSubscription = { [weak self] in self?.closedSubscriptions += 1 }
            service.myNoiseKey = { [weak self] in self?.myKey }
            service.localVerifiedPeers = { [weak self] in self?.localPeers ?? [] }
            service.sealEnvelope = { [weak self] content, messageID, key in
                self?.sealRequests.append((content, messageID, key))
                return self?.sealResult
            }
            service.openEnvelope = { [weak self] envelope in
                self?.openedEnvelopes.append(envelope)
                return self?.openResult ?? false
            }
            service.deliverToPeer = { [weak self] envelope, peer in
                self?.delivered.append((envelope, peer))
                return self?.deliverResult ?? false
            }
            service.heldEnvelopes = { [weak self] cooldown in
                self?.heldCooldowns.append(cooldown)
                return self?.held ?? []
            }
            service.markHeldEnvelopePublished = { [weak self] envelope in
                self?.markedHeldEnvelopes.append(envelope)
            }
            service.scheduleTimer = { [weak self] delay, fire in
                self?.scheduledTimers.append((delay, fire))
            }
        }

        func resolveNextPublish(_ succeeded: Bool) {
            guard !pendingPublishCompletions.isEmpty else { return }
            pendingPublishCompletions.removeFirst()(succeeded)
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

    @Test func missingRelayPublisherDoesNotConsumeDurableDedupSlot() {
        let fixture = Fixture()
        let key = Fixture.randomKey()
        fixture.sealResult = makeEnvelope(recipientKey: key)
        fixture.service.publishEvent = nil
        let messageID = UUID().uuidString
        var results: [Bool] = []

        fixture.service.depositDrop(content: "retry", messageID: messageID, recipientNoiseKey: key) { results.append($0) }
        fixture.service.depositDrop(content: "retry", messageID: messageID, recipientNoiseKey: key) { results.append($0) }
        #expect(fixture.sealRequests.count == 2)
        #expect(fixture.publishedEvents.isEmpty)
        #expect(results == [false, false])
    }

    @Test func relayRejectionDoesNotPersistDedupAndRetryCanSucceed() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-dedup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let key = Fixture.randomKey()
        let messageID = UUID().uuidString

        let failed = Fixture(dedupStore: BridgeDropDedupStore(fileURL: fileURL))
        failed.sealResult = makeEnvelope(recipientKey: key)
        failed.automaticPublishResult = false
        var failedResults: [Bool] = []
        failed.service.depositDrop(content: "retry", messageID: messageID, recipientNoiseKey: key) {
            failedResults.append($0)
        }
        failed.service.flushDedupSnapshot()
        #expect(failedResults == [false])
        #expect(failed.publishedEvents.count == 1)

        // A relaunch over the failed attempt must be allowed to send again.
        let retry = Fixture(dedupStore: BridgeDropDedupStore(fileURL: fileURL))
        retry.sealResult = makeEnvelope(recipientKey: key)
        var retryResults: [Bool] = []
        retry.service.depositDrop(content: "retry", messageID: messageID, recipientNoiseKey: key) {
            retryResults.append($0)
        }
        retry.service.flushDedupSnapshot()
        #expect(retryResults == [true])
        #expect(retry.publishedEvents.count == 1)

        // Only confirmed relay acceptance consumes durable dedup.
        let confirmed = Fixture(dedupStore: BridgeDropDedupStore(fileURL: fileURL))
        confirmed.sealResult = makeEnvelope(recipientKey: key)
        confirmed.service.depositDrop(content: "retry", messageID: messageID, recipientNoiseKey: key)
        #expect(confirmed.publishedEvents.isEmpty)
        #expect(confirmed.sealRequests.isEmpty)
    }

    @Test func panicWipeInvalidatesInFlightPublishCompletion() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-dedup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let key = Fixture.randomKey()
        let messageID = UUID().uuidString
        let fixture = Fixture(dedupStore: BridgeDropDedupStore(fileURL: fileURL))
        fixture.sealResult = makeEnvelope(recipientKey: key)
        fixture.automaticPublishResult = nil
        var results: [Bool] = []

        fixture.service.depositDrop(content: "in flight", messageID: messageID, recipientNoiseKey: key) {
            results.append($0)
        }
        let staleCompletion = try #require(fixture.pendingPublishCompletions.first)
        fixture.service.wipe()
        #expect(results == [false])

        // The pre-wipe relay completion cannot resurrect durable dedup or
        // complete the caller a second time.
        staleCompletion(true)
        fixture.service.flushDedupSnapshot()
        #expect(results == [false])

        let relaunched = Fixture(dedupStore: BridgeDropDedupStore(fileURL: fileURL))
        relaunched.sealResult = makeEnvelope(recipientKey: key)
        relaunched.service.depositDrop(content: "retry", messageID: messageID, recipientNoiseKey: key)
        #expect(relaunched.publishedEvents.count == 1)
    }

    @Test func bridgeDisableCancelsPendingAndInFlightPublishes() throws {
        let fixture = Fixture()
        let key = Fixture.randomKey()
        fixture.sealResult = makeEnvelope(recipientKey: key)
        fixture.automaticPublishResult = nil
        var results: [Bool] = []

        fixture.service.depositDrop(content: "in flight", messageID: "in-flight", recipientNoiseKey: key) {
            results.append($0)
        }
        let staleCompletion = try #require(fixture.pendingPublishCompletions.first)

        fixture.relaysConnected = false
        fixture.service.depositDrop(content: "pending", messageID: "pending", recipientNoiseKey: key) {
            results.append($0)
        }
        #expect(fixture.service.pendingDrops.count == 1)

        fixture.bridgeOn = false
        fixture.service.refresh()
        #expect(results == [false, false])
        #expect(fixture.service.pendingDrops.isEmpty)

        staleCompletion(true)
        #expect(results == [false, false])
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
        var firstResults: [Bool] = []
        fixture.service.depositDrop(content: "0", messageID: firstID, recipientNoiseKey: key) { firstResults.append($0) }
        // Fill past capacity so the first drop is evicted.
        for i in 1...BridgeCourierService.Limits.maxPendingDrops {
            fixture.service.depositDrop(content: "\(i)", messageID: UUID().uuidString, recipientNoiseKey: key)
        }
        #expect(fixture.service.pendingDrops.count == BridgeCourierService.Limits.maxPendingDrops)
        #expect(firstResults == [false])

        // The evicted first drop is deposit-able again (slot released).
        fixture.service.depositDrop(content: "0-retry", messageID: firstID, recipientNoiseKey: key)
        #expect(fixture.service.pendingDrops.last?.dedupKey == firstID)
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
        var results: [Bool] = []

        fixture.service.depositDrop(content: "big", messageID: messageID, recipientNoiseKey: key) { results.append($0) }
        #expect(fixture.publishedEvents.isEmpty)

        // The retry sweep must not seal the same payload again.
        fixture.service.depositDrop(content: "big", messageID: messageID, recipientNoiseKey: key) { results.append($0) }
        #expect(fixture.sealRequests.count == 1)
        #expect(results == [false, false])
    }

    @Test func rejectedOversizeDropKeysExpireAndStayBounded() {
        var date = Date(timeIntervalSince1970: 1_750_000_000)
        let fixture = Fixture(now: { date })
        let key = Fixture.randomKey()
        fixture.sealResult = makeEnvelope(
            recipientKey: key,
            ciphertext: Data(repeating: 7, count: BridgeCourierService.Limits.maxDropEnvelopeBytes + 1)
        )

        let firstID = "oversize-0"
        fixture.service.depositDrop(content: "big", messageID: firstID, recipientNoiseKey: key)
        for index in 1...BridgeCourierService.Limits.maxTrackedIDs {
            date = date.addingTimeInterval(1)
            fixture.service.depositDrop(content: "big", messageID: "oversize-\(index)", recipientNoiseKey: key)
        }
        let afterCapacityFill = fixture.sealRequests.count
        date = date.addingTimeInterval(1)
        fixture.service.depositDrop(content: "big", messageID: firstID, recipientNoiseKey: key)
        #expect(fixture.sealRequests.count == afterCapacityFill + 1)

        let newestID = "oversize-\(BridgeCourierService.Limits.maxTrackedIDs)"
        let beforeExpiry = fixture.sealRequests.count
        fixture.service.depositDrop(content: "big", messageID: newestID, recipientNoiseKey: key)
        #expect(fixture.sealRequests.count == beforeExpiry)

        date = date.addingTimeInterval(CourierEnvelope.maxLifetimeSeconds + 1)
        fixture.service.depositDrop(content: "big", messageID: newestID, recipientNoiseKey: key)
        #expect(fixture.sealRequests.count == beforeExpiry + 1)
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
        var publishResults: [Bool] = []
        fixture.service.depositDrop(content: "hello", messageID: messageID, recipientNoiseKey: recipientKey) { publishResults.append($0) }
        #expect(fixture.publishedEvents.count == 1)
        #expect(publishResults == [true])
        // Persistence is coalesced; a real launch flushes within a second or
        // on backgrounding — tests flush explicitly.
        fixture.service.flushDedupSnapshot()

        // "Relaunch": a fresh service over the same store must refuse to
        // publish the same message ID again (before even re-sealing it).
        let relaunched = Fixture(dedupStore: BridgeDropDedupStore(fileURL: fileURL))
        relaunched.sealResult = makeEnvelope(recipientKey: recipientKey)
        var relaunchResults: [Bool] = []
        relaunched.service.depositDrop(content: "hello", messageID: messageID, recipientNoiseKey: recipientKey) { relaunchResults.append($0) }
        #expect(relaunched.publishedEvents.isEmpty)
        #expect(relaunched.sealRequests.isEmpty)
        #expect(relaunchResults == [false])
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
        fixture.service.flushDedupSnapshot()

        let relaunched = Fixture(dedupStore: BridgeDropDedupStore(fileURL: fileURL))
        relaunched.myKey = myKey
        relaunched.service.refresh()
        relaunched.service.handleDropEvent(event)
        #expect(relaunched.openedEnvelopes.isEmpty)
    }

    @Test func offlineQueuedDropStaysRedepositableAfterRelaunch() throws {
        // A deposit made while relays are down only joins the in-memory
        // pending queue. Its dedup key must NOT be durable yet: if the app is
        // killed before relays connect, the relaunch loses the queued drop —
        // a persisted key would then block every 120s re-deposit for 24h and
        // the message would silently never reach a relay.
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-dedup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let recipientKey = Fixture.randomKey()
        let messageID = UUID().uuidString

        let fixture = Fixture(dedupStore: BridgeDropDedupStore(fileURL: fileURL))
        fixture.relaysConnected = false
        fixture.sealResult = makeEnvelope(recipientKey: recipientKey)
        fixture.service.depositDrop(content: "later", messageID: messageID, recipientNoiseKey: recipientKey)
        #expect(fixture.publishedEvents.isEmpty)
        // Even a flush while the drop is still pending must exclude its key.
        fixture.service.flushDedupSnapshot()

        // "App killed before relays connected": pendingDrops were memory-only.
        let relaunched = Fixture(dedupStore: BridgeDropDedupStore(fileURL: fileURL))
        relaunched.sealResult = makeEnvelope(recipientKey: recipientKey)
        relaunched.service.depositDrop(content: "later", messageID: messageID, recipientNoiseKey: recipientKey)
        #expect(relaunched.publishedEvents.count == 1)
    }

    @Test func publishedPendingDropBecomesDurableAfterFlush() throws {
        // Counterpart: once the queued drop actually publishes on reconnect,
        // its key becomes durable and a relaunch must not republish.
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-dedup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let recipientKey = Fixture.randomKey()
        let messageID = UUID().uuidString

        let fixture = Fixture(dedupStore: BridgeDropDedupStore(fileURL: fileURL))
        fixture.relaysConnected = false
        fixture.sealResult = makeEnvelope(recipientKey: recipientKey)
        fixture.service.depositDrop(content: "later", messageID: messageID, recipientNoiseKey: recipientKey)
        fixture.relaysConnected = true
        fixture.service.flushPendingDrops()
        #expect(fixture.publishedEvents.count == 1)
        fixture.service.flushDedupSnapshot()

        let relaunched = Fixture(dedupStore: BridgeDropDedupStore(fileURL: fileURL))
        relaunched.sealResult = makeEnvelope(recipientKey: recipientKey)
        var relaunchResults: [Bool] = []
        relaunched.service.depositDrop(content: "later", messageID: messageID, recipientNoiseKey: recipientKey) { relaunchResults.append($0) }
        #expect(relaunched.publishedEvents.isEmpty)
        #expect(relaunchResults == [false])
    }

    @Test func failedGatewayHandoffReleasesSeenSlot() throws {
        // A gateway's deliverToPeer handoff is best-effort: when it fails
        // (the peer walked away between relay fetch and mesh send), the drop
        // event must stay retryable — for a single-gateway mesh island this
        // gateway is the recipient's only carrier.
        let fixture = Fixture()
        let peerKey = Fixture.randomKey()
        let peer = PeerID(str: "aabbccdd00112233")
        fixture.localPeers = [(peer, peerKey)]
        fixture.service.refresh()
        let event = try makeDropEvent(for: makeEnvelope(recipientKey: peerKey))

        fixture.deliverResult = false
        fixture.service.handleDropEvent(event)
        #expect(fixture.delivered.count == 1)

        // Redelivery (relaunch/backlog re-fetch) retries the handoff …
        fixture.deliverResult = true
        fixture.service.handleDropEvent(event)
        #expect(fixture.delivered.count == 2)

        // … and a successful handoff consumes the event for good.
        fixture.service.handleDropEvent(event)
        #expect(fixture.delivered.count == 2)
    }

    @Test func staleWatchSetDeliveryIsNotConsumedBeforePeerBecomesCurrent() throws {
        let fixture = Fixture()
        let peerKey = Fixture.randomKey()
        let peer = PeerID(str: "aabbccdd00112233")
        let event = try makeDropEvent(for: makeEnvelope(recipientKey: peerKey))

        // A callback from the previous relay subscription can land after its
        // peer was removed from the bounded watch set. Ignore it without
        // poisoning the persistent event-ID dedup record.
        fixture.service.refresh()
        fixture.service.handleDropEvent(event)
        #expect(fixture.delivered.isEmpty)

        fixture.localPeers = [(peer, peerKey)]
        fixture.service.refresh()
        fixture.service.handleDropEvent(event)
        #expect(fixture.delivered.count == 1)

        // Once the current peer's physical handoff succeeds, normal durable
        // dedup applies.
        fixture.service.handleDropEvent(event)
        #expect(fixture.delivered.count == 1)
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
        #expect(fixture.markedHeldEnvelopes == fixture.held)
    }

    @Test func rejectedHeldPublishDoesNotStartCooldown() {
        let fixture = Fixture()
        fixture.automaticPublishResult = false
        fixture.held = [makeEnvelope(recipientKey: Fixture.randomKey())]

        fixture.service.publishHeldEnvelopes()

        #expect(fixture.publishedEvents.count == 1)
        #expect(fixture.markedHeldEnvelopes.isEmpty)
    }

    @Test func heldPublishIsSingleFlightAndRetryableAfterRejection() {
        let fixture = Fixture()
        fixture.automaticPublishResult = nil
        fixture.held = [makeEnvelope(recipientKey: Fixture.randomKey())]

        fixture.service.publishHeldEnvelopes()
        fixture.service.publishHeldEnvelopes()
        #expect(fixture.publishedEvents.count == 1)

        fixture.resolveNextPublish(false)
        fixture.service.publishHeldEnvelopes()
        #expect(fixture.publishedEvents.count == 2)
        #expect(fixture.markedHeldEnvelopes.isEmpty)

        fixture.resolveNextPublish(true)
        #expect(fixture.markedHeldEnvelopes == fixture.held)
    }

    @Test func bridgeDisableInvalidatesHeldPublishOperation() throws {
        let fixture = Fixture()
        fixture.automaticPublishResult = nil
        fixture.held = [makeEnvelope(recipientKey: Fixture.randomKey())]

        fixture.service.publishHeldEnvelopes()
        let staleCompletion = try #require(fixture.pendingPublishCompletions.first)
        fixture.bridgeOn = false
        fixture.service.refresh()
        staleCompletion(true)

        #expect(fixture.markedHeldEnvelopes.isEmpty)
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

    @Test func announceDebounceSchedulesTrailingRefreshForPeersLearnedInsideWindow() throws {
        var date = Date(timeIntervalSince1970: 1_750_000_000)
        let fixture = Fixture(now: { date })

        // Leading edge opens the own-tag subscription immediately.
        fixture.service.refreshAfterVerifiedAnnounce()
        #expect(fixture.openedSubscriptions.count == 1)

        // A second peer learned inside the debounce window must not wait for
        // the 30-minute periodic timer.
        date = date.addingTimeInterval(10)
        fixture.localPeers = [(PeerID(str: "aabbccdd00112233"), Fixture.randomKey())]
        fixture.service.refreshAfterVerifiedAnnounce()
        fixture.service.refreshAfterVerifiedAnnounce() // coalesces, not a second timer

        let trailingTimers = fixture.scheduledTimers.filter { $0.delay < 100 }
        #expect(trailingTimers.count == 1)
        let trailing = try #require(trailingTimers.first)
        #expect(trailing.delay == 50)
        date = date.addingTimeInterval(50)
        trailing.fire()

        #expect(fixture.openedSubscriptions.count == 2)
        #expect(fixture.openedSubscriptions.last?.count == 6)
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

    @Test func transientOwnDropOpenFailureRemainsRetryable() throws {
        let fixture = Fixture()
        let myKey = try #require(fixture.myKey)
        fixture.service.refresh()
        let event = try makeDropEvent(for: makeEnvelope(recipientKey: myKey))

        fixture.openResult = false
        fixture.service.handleDropEvent(event)
        fixture.openResult = true
        fixture.service.handleDropEvent(event)
        fixture.service.handleDropEvent(event)

        #expect(fixture.openedEnvelopes.count == 2)
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

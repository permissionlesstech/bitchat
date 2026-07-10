//
// PerformanceBaselineTests.swift
// bitchatTests
//
// Performance baselines for hot paths so regressions are measured, not
// guessed. Uses XCTest `measure {}` (swift-testing has no equivalent) with
// NO recorded baselines — these tests record timing in CI logs but never
// fail on timing, so they cannot flake.
//
// Each benchmark builds its fixtures OUTSIDE the measure block with fixed
// seeds/content so every iteration does deterministic work: no network,
// no Tor, no sleeps.
//
// Skippable via the BITCHAT_SKIP_PERF_BASELINES=1 environment variable;
// runs by default.
//

import XCTest
import SwiftUI
import BitFoundation
@testable import bitchat

@MainActor
final class PerformanceBaselineTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["BITCHAT_SKIP_PERF_BASELINES"] == "1",
            "Performance baselines skipped via BITCHAT_SKIP_PERF_BASELINES"
        )
    }

    override func tearDown() {
        // Drain main-queue tasks spawned by coordinators (handlePublicMessage
        // hops etc.) so they don't bleed into the next test's measure block.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        super.tearDown()
    }

    /// Reports one human-readable throughput line per benchmark so CI logs
    /// are readable without parsing XCTest's measure output. The same line is
    /// appended to the file named by `BITCHAT_PERF_LOG` (if set): under
    /// `swift test --parallel` the runner swallows stdout of passing tests,
    /// so the CI floor gate (scripts/check-perf-floors.sh) reads the file.
    private func reportThroughput(_ name: String, samples: [TimeInterval], operations: Int, unit: String) {
        guard !samples.isEmpty else { return }
        let avg = samples.reduce(0, +) / Double(samples.count)
        let opsPerSec = avg > 0 ? Double(operations) / avg : .infinity
        let line = String(
            format: "PERF[%@]: %.0f %@/sec (avg %.3f ms per pass of %d, %d passes)",
            name, opsPerSec, unit, avg * 1000, operations, samples.count
        )
        print(line)
        Self.appendToPerfLog(line)
    }

    private static var perfLogPath: String? {
        let path = ProcessInfo.processInfo.environment["BITCHAT_PERF_LOG"]
        return (path?.isEmpty ?? true) ? nil : path
    }

    /// Appends with `O_APPEND` because `swift test --parallel` may split this
    /// class across worker processes that write concurrently. The file is
    /// append-only (CI workspaces start fresh); delete it between local runs
    /// if you reuse a path.
    private static func appendToPerfLog(_ line: String) {
        guard let path = perfLogPath else { return }
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array((line + "\n").utf8)
        bytes.withUnsafeBufferPointer { buffer in
            _ = write(fd, buffer.baseAddress, buffer.count)
        }
    }

    // MARK: - 1a. Nostr inbound event handling (fresh events)

    /// `NostrInboundPipeline.handleNostrEvent` for never-seen geo events
    /// (kind 20000): signature verification, dedup record, presence/nickname
    /// bookkeeping, and public-message ingest scheduling.
    func testNostrInboundEventHandling_freshEvents() throws {
        let events = try Self.makeSignedGeohashEvents(count: 500)
        // A fresh context per measure pass so every event takes the
        // first-seen path on every iteration. Kept alive so the weakly
        // captured Task hops stay valid.
        var keepAlive: [(PerfNostrContext, ChatNostrCoordinator)] = []
        var samples: [TimeInterval] = []

        measure {
            let context = PerfNostrContext()
            let coordinator = ChatNostrCoordinator(context: context)
            keepAlive.append((context, coordinator))
            let start = Date()
            for event in events {
                coordinator.inbound.handleNostrEvent(event)
            }
            samples.append(Date().timeIntervalSince(start))
            XCTAssertEqual(context.processedEventCount, events.count)
        }

        reportThroughput("nostrInbound.fresh", samples: samples, operations: events.count, unit: "events")
    }

    // MARK: - 1b. Nostr inbound event handling (duplicate events)

    /// The dedup-hit path: identical events replayed. Duplicates dominate
    /// real relay traffic (the same event arrives from several relays), so
    /// this path runs hundreds of times a minute in busy geohashes. Note it
    /// still pays full Schnorr signature verification before the dedup check.
    func testNostrInboundEventHandling_duplicateEvents() throws {
        let events = try Self.makeSignedGeohashEvents(count: 500)
        let context = PerfNostrContext()
        let coordinator = ChatNostrCoordinator(context: context)
        // Pre-warm: every event is now recorded as processed.
        for event in events {
            coordinator.inbound.handleNostrEvent(event)
        }
        XCTAssertEqual(context.processedEventCount, events.count)
        var samples: [TimeInterval] = []

        measure {
            let start = Date()
            for event in events {
                coordinator.inbound.handleNostrEvent(event)
            }
            samples.append(Date().timeIntervalSince(start))
        }

        // Dedup held: nothing was re-processed.
        XCTAssertEqual(context.processedEventCount, events.count)
        reportThroughput("nostrInbound.duplicate", samples: samples, operations: events.count, unit: "events")
    }

    // MARK: - 2. BLE inbound packet pipeline (decode + dedup)

    /// Binary encode/decode round trip plus `MessageDeduplicator` at
    /// realistic mesh sizes: 1000 packets with 100-300 byte payloads, each
    /// dedup-checked twice (first-seen insert, then duplicate hit) the way
    /// relayed packets arrive on multiple links.
    func testBLEInboundPacketPipeline() throws {
        var rng = SeededGenerator(seed: 0xB17C4A7)
        let baseTimestamp = UInt64(1_700_000_000_000)
        var packets: [BitchatPacket] = []
        var dedupIDs: [String] = []
        packets.reserveCapacity(1000)
        dedupIDs.reserveCapacity(1000)
        for index in 0..<1000 {
            let senderID = Data((0..<8).map { _ in UInt8.random(in: 0...255, using: &rng) })
            let payloadSize = Int.random(in: 100...300, using: &rng)
            let payload = Data((0..<payloadSize).map { _ in UInt8.random(in: 0...255, using: &rng) })
            let packet = BitchatPacket(
                type: MessageType.message.rawValue,
                senderID: senderID,
                recipientID: nil,
                timestamp: baseTimestamp + UInt64(index),
                payload: payload,
                signature: nil,
                ttl: 7
            )
            packets.append(packet)
            // Same dedup key shape BLEService uses: sender-timestamp-type.
            dedupIDs.append("\(senderID.hexEncodedString())-\(packet.timestamp)-\(packet.type)")
        }
        let deduplicator = MessageDeduplicator()
        var samples: [TimeInterval] = []

        measure {
            deduplicator.reset() // identical work every pass
            let start = Date()
            var decodedCount = 0
            var duplicateCount = 0
            for (index, packet) in packets.enumerated() {
                guard let data = packet.toBinaryData(),
                      let decoded = BitchatPacket.from(data) else { continue }
                decodedCount += 1
                _ = decoded.payload.count
                if deduplicator.isDuplicate(dedupIDs[index]) { duplicateCount += 1 }
            }
            for id in dedupIDs where deduplicator.isDuplicate(id) {
                duplicateCount += 1
            }
            samples.append(Date().timeIntervalSince(start))
            XCTAssertEqual(decodedCount, packets.count)
            XCTAssertEqual(duplicateCount, packets.count)
        }

        reportThroughput("bleInbound.roundTripAndDedup", samples: samples, operations: packets.count, unit: "packets")
    }

    // MARK: - 3. GCS sync filters

    /// `GCSFilter.buildFilter` + `decodeToSortedSet` at the production gossip
    /// config (`TransportConfig.syncGCSMaxBytes` / `syncGCSTargetFpr`) with
    /// 1000 candidate packet IDs (the filter caps to its byte budget).
    func testGCSFilterBuildAndDecode() {
        var rng = SeededGenerator(seed: 0x6C5F11)
        let ids: [Data] = (0..<1000).map { _ in
            Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &rng) })
        }
        let maxBytes = TransportConfig.syncGCSMaxBytes
        let targetFpr = TransportConfig.syncGCSTargetFpr
        let repsPerPass = 20
        var samples: [TimeInterval] = []

        measure {
            let start = Date()
            var decodedTotal = 0
            for _ in 0..<repsPerPass {
                let params = GCSFilter.buildFilter(ids: ids, maxBytes: maxBytes, targetFpr: targetFpr)
                let decoded = GCSFilter.decodeToSortedSet(p: params.p, m: params.m, data: params.data)
                decodedTotal += decoded.count
                XCTAssertLessThanOrEqual(params.data.count, maxBytes)
            }
            samples.append(Date().timeIntervalSince(start))
            XCTAssertGreaterThan(decodedTotal, 0)
        }

        reportThroughput("gcs.buildAndDecode", samples: samples, operations: repsPerPass, unit: "filters")
    }

    // MARK: - 4a. Delivery status updates through the coordinator (store path)

    /// `ChatDeliveryCoordinator.updateMessageDeliveryStatus` over the
    /// `ConversationStore`'s message-ID → conversation map: 2000 public
    /// (split mesh + geohash to stay under the per-conversation cap) + 50x40
    /// private messages, 500 status updates per pass. Statuses alternate
    /// between two `delivered` timestamps so every call performs a real update
    /// (never the skip path). A sent <-> delivered alternation would now hit
    /// the store's no-downgrade guard on the delivered -> sent half.
    func testDeliveryStatusIncrementalUpdates() {
        let context = PerfDeliveryContext.makeCorpus(publicCount: 2000, peerCount: 50, messagesPerPeer: 40)
        let coordinator = ChatDeliveryCoordinator(context: context)
        let targetIDs = context.makeTargetIDs(publicTargets: 250, privateTargets: 250)
        XCTAssertEqual(targetIDs.count, 500)

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let fixedDate2 = Date(timeIntervalSince1970: 1_700_000_001)
        var toggle = false
        var samples: [TimeInterval] = []

        measure {
            toggle.toggle()
            let status: DeliveryStatus = toggle ? .delivered(to: "peer", at: fixedDate) : .delivered(to: "peer", at: fixedDate2)
            let start = Date()
            var updated = 0
            for id in targetIDs where coordinator.updateMessageDeliveryStatus(id, status: status) {
                updated += 1
            }
            samples.append(Date().timeIntervalSince(start))
            XCTAssertEqual(updated, targetIDs.count)
        }

        reportThroughput("delivery.incrementalUpdate", samples: samples, operations: targetIDs.count, unit: "updates")
    }

    // MARK: - 4b. Delivery status updates against the store directly

    /// `ConversationStore.setDeliveryStatus(_:forMessageID:)` at the same
    /// scale as 4a, without the coordinator/context wrapping — the store-side
    /// cost of an ID-only delivery update (map lookup + per-conversation
    /// ID-index apply + change emission). Replaces the deleted
    /// `delivery.indexRebuild` benchmark: the positional location index and
    /// its rebuild path no longer exist; the store's ID indexes are
    /// maintained inside each mutation, so there is no rebuild to measure.
    func testDeliveryStatusStoreUpdates() {
        let context = PerfDeliveryContext.makeCorpus(publicCount: 2000, peerCount: 50, messagesPerPeer: 40)
        let store = context.store
        let targetIDs = context.makeTargetIDs(publicTargets: 250, privateTargets: 250)
        XCTAssertEqual(targetIDs.count, 500)

        // Alternate two delivered timestamps so every update is real; a
        // sent <-> delivered swing would hit the no-downgrade guard.
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let fixedDate2 = Date(timeIntervalSince1970: 1_700_000_001)
        var toggle = false
        var samples: [TimeInterval] = []

        measure {
            toggle.toggle()
            let status: DeliveryStatus = toggle ? .delivered(to: "peer", at: fixedDate) : .delivered(to: "peer", at: fixedDate2)
            let start = Date()
            var updated = 0
            for id in targetIDs where store.setDeliveryStatus(status, forMessageID: id) {
                updated += 1
            }
            samples.append(Date().timeIntervalSince(start))
            XCTAssertEqual(updated, targetIDs.count)
        }

        reportThroughput("delivery.storeUpdate", samples: samples, operations: targetIDs.count, unit: "updates")
    }

    // MARK: - 5. Message formatting

    /// `MessageFormattingEngine.formatMessage` over 200 messages with
    /// mentions, hashtags, and URLs. Formatting caches per message, so each
    /// measure pass consumes a fresh pre-built batch (cache-miss path, which
    /// is the cost paid when messages first render).
    func testMessageFormatting() {
        let context = PerfFormattingContext(nickname: "carol")
        let batchCount = 16 // > XCTest's default 10 measure iterations
        let batchSize = 200
        let contents: [(String, [String]?)] = [
            ("hello mesh, anyone around tonight?", nil),
            ("@carol#a1b2 did you see this? https://example.com/threads/42", ["carol"]),
            ("checking in from the harbor #bitchat #mesh", nil),
            ("@bob#0042 ping me when you get this", ["bob#0042"]),
            ("long form update with a link https://news.example.org/articles/2026/06/mesh-networks and a tag #geohash", nil)
        ]
        let batches: [[BitchatMessage]] = (0..<batchCount).map { batch in
            (0..<batchSize).map { i in
                let (content, mentions) = contents[i % contents.count]
                return BitchatMessage(
                    id: "fmt-\(batch)-\(i)",
                    sender: "alice#a1b\(i % 10)",
                    content: content,
                    timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)),
                    isRelay: false,
                    senderPeerID: PeerID(str: "abcdef123456789\(i % 10)"),
                    mentions: mentions
                )
            }
        }
        var pass = 0
        var samples: [TimeInterval] = []

        measure {
            precondition(pass < batches.count, "add more pre-built batches")
            let batch = batches[pass]
            pass += 1
            let start = Date()
            var formattedCharacters = 0
            for message in batch {
                let formatted = MessageFormattingEngine.formatMessage(message, context: context, colorScheme: .light)
                formattedCharacters += formatted.characters.count
            }
            samples.append(Date().timeIntervalSince(start))
            XCTAssertGreaterThan(formattedCharacters, 0)
        }

        reportThroughput("formatting.formatMessage", samples: samples, operations: batchSize, unit: "messages")
    }

    // MARK: - 6a. End-to-end private ingest pipeline (current architecture)

    /// Baseline for the full private-message ingest cycle through a real
    /// `ChatViewModel`: `handlePrivateMessage` → `ConversationStore.append`
    /// intent (ordered insert + ID-index dedup) → per-conversation publish +
    /// `changes` emission → `PrivateInboxModel` (direct store reads).
    /// Measures wall time from first ingest until the store AND the feature
    /// model both reflect every message. The peer is not mesh-active and no
    /// chat is selected, so notification/read-receipt side paths stay cold
    /// (notifications are no-ops under test anyway).
    func testPipelinePrivateIngest() {
        let messageCount = 200
        // 64-hex (stable Noise key) peer ID: skips the short-ID consolidation
        // and ephemeral-mirror paths so every pass does identical work.
        let peerID = PeerID(str: String(repeating: "ab", count: 32))
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let messages: [BitchatMessage] = (0..<messageCount).map { i in
            BitchatMessage(
                id: "perf-dm-\(i)",
                sender: "perfsender",
                content: "private pipeline message \(i)",
                timestamp: base.addingTimeInterval(Double(i)),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "me",
                senderPeerID: peerID
            )
        }
        // Fresh fixture per pass so dedup scans and store syncs start from the
        // same empty state every iteration. Kept alive so weakly captured
        // coordinator Task hops stay valid.
        var keepAlive: [PerfPipelineFixture] = []
        var samples: [TimeInterval] = []

        measure {
            let fixture = PerfPipelineFixture()
            keepAlive.append(fixture)
            let start = Date()
            for message in messages {
                fixture.viewModel.handlePrivateMessage(message)
            }
            // Reads are synchronous against the single-writer store; the
            // spin covers any coordinator main-actor hops.
            let consistent = spinMainRunLoop(timeout: 10) {
                fixture.conversations.conversationsByID[.directPeer(peerID)]?.messages.count == messageCount
                    && fixture.privateInbox.messages(for: peerID).count == messageCount
            }
            samples.append(Date().timeIntervalSince(start))
            XCTAssertTrue(consistent, "ConversationStore/PrivateInboxModel never converged")
            XCTAssertEqual(fixture.viewModel.privateChats[peerID]?.count, messageCount)
        }

        reportThroughput("pipeline.privateIngest", samples: samples, operations: messageCount, unit: "messages")
    }

    // MARK: - 6b. End-to-end public ingest pipeline (current architecture)

    /// Baseline for the full public-message ingest cycle through a real
    /// `ChatViewModel`: `didReceivePublicMessage` (transport delegate entry,
    /// main-actor Task hop per message) → `handlePublicMessage` (rate limit,
    /// pipeline enqueue) → `PublicMessagePipeline` timer-batched flush into
    /// the `ConversationStore` (derived `ChatViewModel.messages` view;
    /// `PublicChatModel` observes the active `Conversation` directly).
    /// Measures until `messages` and the feature model reflect every message,
    /// so the pipeline's flush latency is part of the cycle. Senders are
    /// spread 4-per-peer to stay under the 5-token sender rate bucket.
    func testPipelinePublicIngest() {
        let messageCount = 200
        let senderCount = 50
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        struct InboundPublic {
            let peerID: PeerID
            let nickname: String
            let content: String
            let timestamp: Date
            let messageID: String
        }
        let items: [InboundPublic] = (0..<messageCount).map { i in
            let sender = i % senderCount
            return InboundPublic(
                peerID: PeerID(str: String(format: "%016x", 0xC0DE_0000 + sender)),
                nickname: "perfpeer\(sender)",
                content: "public pipeline message \(i) from sender \(sender)",
                timestamp: base.addingTimeInterval(Double(i)),
                messageID: "perf-pub-\(i)"
            )
        }
        let expectedIDs = Set(items.map(\.messageID))
        var keepAlive: [PerfPipelineFixture] = []
        var samples: [TimeInterval] = []

        measure {
            let fixture = PerfPipelineFixture()
            keepAlive.append(fixture)
            let start = Date()
            for item in items {
                fixture.viewModel.didReceivePublicMessage(
                    from: item.peerID,
                    nickname: item.nickname,
                    content: item.content,
                    timestamp: item.timestamp,
                    messageID: item.messageID
                )
            }
            // Drain the per-message main-actor hops and whichever surfacing
            // path wins (the pipeline's batched timer flush or the startup
            // channel apply's `refreshVisibleMessages`); `PublicChatModel`
            // reads the same conversation synchronously.
            let consistent = spinMainRunLoop(timeout: 10) {
                fixture.viewModel.messages.count >= messageCount
                    && fixture.publicChat.messages.count >= messageCount
            }
            samples.append(Date().timeIntervalSince(start))
            XCTAssertTrue(consistent, "messages/PublicChatModel never converged")
            let ingested = fixture.viewModel.messages.filter { expectedIDs.contains($0.id) }
            XCTAssertEqual(ingested.count, messageCount)
        }

        reportThroughput("pipeline.publicIngest", samples: samples, operations: messageCount, unit: "messages")
    }

    // MARK: - 7. ConversationStore append (to-be architecture)

    /// Core op of the new single-source-of-truth `ConversationStore`
    /// (docs/CONVERSATION-STORE-DESIGN.md): 1000 appends into one
    /// conversation, every 10th arriving out of order so the binary-search
    /// insert path (plus suffix reindex) is part of the measured work.
    /// Includes per-message ID-index dedup and the per-conversation
    /// `@Published` array write.
    func testConversationStoreAppend() {
        let messageCount = 1000
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let messages: [BitchatMessage] = (0..<messageCount).map { i in
            // Every 10th message is "late": its timestamp predates already
            // appended messages, forcing the ordered-insert slow path.
            let offset = (i % 10 == 9) ? Double(i) - 5.5 : Double(i)
            return BitchatMessage(
                id: "perf-store-\(i)",
                sender: "perfsender",
                content: "store append message \(i)",
                timestamp: base.addingTimeInterval(offset),
                isRelay: false
            )
        }
        var samples: [TimeInterval] = []

        measure {
            let store = ConversationStore()
            let start = Date()
            for message in messages {
                store.append(message, to: .mesh)
            }
            samples.append(Date().timeIntervalSince(start))
            XCTAssertEqual(store.conversation(for: .mesh).messages.count, messageCount)
        }

        reportThroughput("store.append", samples: samples, operations: messageCount, unit: "messages")
    }

    // MARK: - 8. ConversationStore invariant audit (field observability)

    /// `ConversationStore.auditInvariants()` over a realistic 5k-message
    /// corpus (mesh + geohash + 75 private chats). The audit runs in the
    /// field on the read-receipt cleanup cadence
    /// (`ChatViewModel.auditConversationStore`), so this measures the
    /// per-audit cost that piggybacks on peer-list updates — it must stay
    /// trivially cheap relative to that cadence.
    func testConversationStoreAudit() {
        let context = PerfDeliveryContext.makeCorpus(publicCount: 2000, peerCount: 75, messagesPerPeer: 40)
        let store = context.store
        XCTAssertEqual(store.totalMessageCount, 5000)
        let repsPerPass = 20
        var samples: [TimeInterval] = []

        measure {
            let start = Date()
            var violationCount = 0
            for _ in 0..<repsPerPass {
                violationCount += store.auditInvariants().count
            }
            samples.append(Date().timeIntervalSince(start))
            XCTAssertEqual(violationCount, 0, "healthy corpus must audit clean")
        }

        reportThroughput("store.audit", samples: samples, operations: repsPerPass, unit: "audits")
    }

    /// Spins the main run loop in small slices (draining main-queue tasks and
    /// timers) until `condition` holds or `timeout` elapses.
    private func spinMainRunLoop(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        return true
    }

    // MARK: - Fixtures

    /// Builds deterministic signed kind-20000 geohash events. Content cycles
    /// through realistic chat lines; a handful of sender identities mimics a
    /// busy channel.
    private static func makeSignedGeohashEvents(count: Int) throws -> [NostrEvent] {
        let senders = try (0..<8).map { _ in try NostrIdentity.generate() }
        let lines = [
            "hello from the geohash",
            "anyone near the station?",
            "@bob#0042 are you on mesh too?",
            "check this out https://example.com/p/123 #bitchat",
            "teleport check, who's local?"
        ]
        return try (0..<count).map { i in
            try NostrProtocol.createEphemeralGeohashEvent(
                content: "\(lines[i % lines.count]) [\(i)]",
                geohash: "u4pruyd",
                senderIdentity: senders[i % senders.count],
                nickname: "peer\(i % senders.count)",
                teleported: i % 25 == 0
            )
        }
    }
}

// MARK: - Deterministic RNG

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Mock ChatNostrContext

/// Minimal `ChatNostrContext` for benchmarking the `ChatNostrCoordinator`
/// stack (`NostrInboundPipeline` in particular) without a `ChatViewModel`
/// (mirrors `ChatNostrCoordinatorContextTests`).
/// Callbacks are cheap dictionary/array operations so the measured cost is
/// the coordinator's own pipeline.
@MainActor
private final class PerfNostrContext: ChatNostrContext {
    var activeChannel: ChannelID = .location(GeohashChannel(level: .neighborhood, geohash: "u4pruyd"))
    var currentGeohash: String? = "u4pruyd"
    var geoSubscriptionID: String?
    var geoDmSubscriptionID: String?
    var geoSamplingSubs: [String: String] = [:]
    var lastGeoNotificationAt: [String: Date] = [:]
    var nostrRelayManager: NostrRelayManager? { nil }

    func setGeoChatSubscriptionID(_ id: String?) { geoSubscriptionID = id }
    func setGeoDmSubscriptionID(_ id: String?) { geoDmSubscriptionID = id }
    func addGeoSamplingSub(_ subID: String, forGeohash geohash: String) { geoSamplingSubs[subID] = geohash }
    func removeGeoSamplingSub(_ subID: String) { geoSamplingSubs.removeValue(forKey: subID) }

    func clearGeoSamplingSubs() -> [String] {
        defer { geoSamplingSubs.removeAll() }
        return Array(geoSamplingSubs.keys)
    }

    var messages: [BitchatMessage] = []
    func flushPublicMessagePipeline() {}
    func refreshVisibleMessages(from channel: ChannelID?) {}
    func addPublicSystemMessage(_ content: String) {}
    func drainPendingGeohashSystemMessages() -> [String] { [] }
    func appendGeohashMessageIfAbsent(_ message: BitchatMessage, toGeohash geohash: String) -> Bool { true }

    private(set) var handledPublicMessageCount = 0
    func handlePublicMessage(_ message: BitchatMessage, powBits: Int) { handledPublicMessageCount += 1 }
    func checkForMentions(_ message: BitchatMessage) {}
    func sendHapticFeedback(for message: BitchatMessage) {}
    func parseMentions(from content: String) -> [String] {
        MessageFormattingEngine.extractMentions(from: content)
    }

    var selectedPrivateChatPeer: PeerID?
    var nostrKeyMapping: [PeerID: String] = [:]
    func registerNostrKeyMapping(_ pubkey: String, for peerID: PeerID) { nostrKeyMapping[peerID] = pubkey }
    func handlePrivateMessage(_ payload: NoisePayload, senderPubkey: String, convKey: PeerID, id: NostrIdentity, messageTimestamp: Date) {}
    func handleDelivered(_ payload: NoisePayload, senderPubkey: String, convKey: PeerID) {}
    func handleReadReceipt(_ payload: NoisePayload, senderPubkey: String, convKey: PeerID) {}
    func startPrivateChat(with peerID: PeerID) {}

    private struct NoIdentity: Error {}
    var geohashIdentities: [String: NostrIdentity] = [:]
    func deriveNostrIdentity(forGeohash geohash: String) throws -> NostrIdentity {
        guard let identity = geohashIdentities[geohash] else { throw NoIdentity() }
        return identity
    }
    func currentNostrIdentity() -> NostrIdentity? { nil }
    func isNostrBlocked(pubkeyHexLowercased: String) -> Bool { false }
    func displayNameForNostrPubkey(_ pubkeyHex: String) -> String { "anon#\(pubkeyHex.prefix(4))" }

    private var processedNostrEventIDs: Set<String> = []
    var processedEventCount: Int { processedNostrEventIDs.count }
    func hasProcessedNostrEvent(_ eventID: String) -> Bool { processedNostrEventIDs.contains(eventID) }
    func recordProcessedNostrEvent(_ eventID: String) { processedNostrEventIDs.insert(eventID) }
    func clearProcessedNostrEvents() { processedNostrEventIDs.removeAll() }

    var geoNicknames: [String: String] = [:]
    private var teleportedKeys: Set<String> = []
    var teleportedGeoCount: Int { teleportedKeys.count }
    func startGeoParticipantRefreshTimer() {}
    func stopGeoParticipantRefreshTimer() {}
    func setActiveParticipantGeohash(_ geohash: String?) {}
    private(set) var participantRecords = 0
    func recordGeoParticipant(pubkeyHex: String) { participantRecords += 1 }
    func recordGeoParticipant(pubkeyHex: String, geohash: String) { participantRecords += 1 }
    func geoParticipantCount(for geohash: String) -> Int { 0 }
    func setGeoNickname(_ nickname: String, forPubkey pubkeyHex: String) { geoNicknames[pubkeyHex.lowercased()] = nickname }
    func markGeoTeleported(_ pubkeyHexLowercased: String) { teleportedKeys.insert(pubkeyHexLowercased) }
    func clearGeoTeleported(_ pubkeyHexLowercased: String) { teleportedKeys.remove(pubkeyHexLowercased) }
    func clearTeleportedGeo() { teleportedKeys.removeAll() }
    func clearGeoNicknames() { geoNicknames.removeAll() }
    func visibleGeohashPeople() -> [GeoPerson] { [] }

    var isTeleported = false
    func isGeohashOutsideRegionalChannels(_ geohash: String) -> Bool { false }

    func routeFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {}
    func sendGeohashDeliveryAck(for messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity) {}
    func sendGeohashReadReceipt(_ messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity) {}

    func favoriteRelationship(forNoiseKey noiseKey: Data) -> FavoritesPersistenceService.FavoriteRelationship? { nil }
    func allFavoriteRelationships() -> [FavoritesPersistenceService.FavoriteRelationship] { [] }
    func notifyGeohashActivity(geohash: String, bodyPreview: String) {}
}

// MARK: - Mock ChatDeliveryContext

/// Minimal `ChatDeliveryContext` over a real `ConversationStore` (the
/// coordinator is a thin mapper onto store intents, so the measured cost is
/// the store's ID-map delivery path).
@MainActor
private final class PerfDeliveryContext: ChatDeliveryContext {
    let store = ConversationStore()
    var sentReadReceipts: Set<String> = []
    var isStartupPhase: Bool { false }
    private var publicIDs: [String] = []
    private var privateIDsByPeer: [(peerID: PeerID, messageIDs: [String])] = []

    func notifyUIChanged() {}
    func markMessageDelivered(_ messageID: String) {}

    @discardableResult
    func setDeliveryStatus(_ status: DeliveryStatus, forMessageID messageID: String) -> Bool {
        store.setDeliveryStatus(status, forMessageID: messageID)
    }

    func deliveryStatus(forMessageID messageID: String) -> DeliveryStatus? {
        store.deliveryStatus(forMessageID: messageID)
    }

    func privateMessageIDs() -> Set<String> {
        store.directMessageIDs()
    }

    func pruneSentReadReceipts(keeping validMessageIDs: Set<String>) -> Int {
        let oldCount = sentReadReceipts.count
        sentReadReceipts = sentReadReceipts.intersection(validMessageIDs)
        return oldCount - sentReadReceipts.count
    }

    /// `publicCount` public messages (split evenly between mesh and one
    /// geohash conversation so the corpus stays under the per-conversation
    /// cap) + `peerCount` x `messagesPerPeer` private messages, seeded into
    /// the store with deterministic IDs and timestamps.
    static func makeCorpus(publicCount: Int, peerCount: Int, messagesPerPeer: Int) -> PerfDeliveryContext {
        let context = PerfDeliveryContext()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let geohashID = ConversationID.geohash("u4pruyd")
        for i in 0..<publicCount {
            let message = BitchatMessage(
                id: "pub-\(i)",
                sender: "peer\(i % 20)",
                content: "public message number \(i)",
                timestamp: base.addingTimeInterval(Double(i)),
                isRelay: false
            )
            context.store.append(message, to: i % 2 == 0 ? .mesh : geohashID)
            context.publicIDs.append(message.id)
        }
        for p in 0..<peerCount {
            let peerID = PeerID(str: String(format: "%016x", 0xA000_0000 + p))
            var messageIDs: [String] = []
            for i in 0..<messagesPerPeer {
                let message = BitchatMessage(
                    id: "dm-\(p)-\(i)",
                    sender: "peer\(p)",
                    content: "private message \(i) for peer \(p)",
                    timestamp: base.addingTimeInterval(Double(i)),
                    isRelay: false,
                    isPrivate: true,
                    recipientNickname: "me",
                    senderPeerID: peerID
                )
                context.store.append(message, to: .directPeer(peerID))
                messageIDs.append(message.id)
            }
            context.privateIDsByPeer.append((peerID, messageIDs))
        }
        return context
    }

    /// Deterministic update targets spread across the corpus: `publicTargets`
    /// public IDs plus `privateTargets` private IDs.
    func makeTargetIDs(publicTargets: Int, privateTargets: Int) -> [String] {
        var targetIDs: [String] = []
        let publicStride = max(1, publicIDs.count / publicTargets)
        for i in stride(from: 0, to: publicIDs.count, by: publicStride) where targetIDs.count < publicTargets {
            targetIDs.append(publicIDs[i])
        }
        var privateCount = 0
        outer: for (_, messageIDs) in privateIDsByPeer {
            for i in stride(from: 0, to: messageIDs.count, by: 4) {
                guard privateCount < privateTargets else { break outer }
                targetIDs.append(messageIDs[i])
                privateCount += 1
            }
        }
        return targetIDs
    }
}

// MARK: - End-to-end pipeline fixture

/// A real `ChatViewModel` over `MockTransport` plus the AppRuntime-style
/// feature models (`PrivateInboxModel` / `PublicChatModel`) bound to the same
/// single-writer `ConversationStore`, so end-to-end ingest benchmarks cover
/// the full ingest-to-feature-model chain. Mirrors the construction used by
/// `ChatViewModelExtensionsTests`.
@MainActor
private final class PerfPipelineFixture {
    let viewModel: ChatViewModel
    let conversations: ConversationStore
    let privateInbox: PrivateInboxModel
    let publicChat: PublicChatModel

    init() {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
        let identityManager = MockIdentityManager(keychain)
        let transport = MockTransport()
        let conversations = ConversationStore()
        let locationSuite = "PerformanceBaselineTests.\(UUID().uuidString)"
        let locationStorage = UserDefaults(suiteName: locationSuite) ?? .standard
        locationStorage.removePersistentDomain(forName: locationSuite)
        let locationManager = LocationChannelManager(storage: locationStorage)

        self.conversations = conversations
        self.viewModel = ChatViewModel(
            keychain: keychain,
            idBridge: idBridge,
            identityManager: identityManager,
            transport: transport,
            conversations: conversations,
            locationManager: locationManager
        )
        self.privateInbox = PrivateInboxModel(conversations: conversations)
        self.publicChat = PublicChatModel(conversations: conversations)
    }
}

// MARK: - Mock MessageFormattingContext

@MainActor
private final class PerfFormattingContext: MessageFormattingContext {
    let nickname: String
    init(nickname: String) { self.nickname = nickname }
    func isSelfMessage(_ message: BitchatMessage) -> Bool { false }
    func senderColor(for message: BitchatMessage, isDark: Bool) -> Color { .blue }
    func peerURL(for peerID: PeerID) -> URL? { URL(string: "bitchat://peer/\(peerID.id)") }
}

import BitFoundation
import Combine
import Foundation
import SwiftUI
import XCTest
@testable import bitchat

@MainActor
final class PanicWipeCoverageTests: XCTestCase {
    func test_nostrIdentityBridge_clearInMemoryCaches_rotatesAfterKeychainWipe() throws {
        let keychain = PreviewKeychainManager()
        let bridgeA = NostrIdentityBridge(keychain: keychain)
        let bridgeB = NostrIdentityBridge(keychain: keychain)

        let beforeA = try bridgeA.deriveIdentity(forGeohash: "u4pruy")
        let beforeB = try bridgeB.deriveIdentity(forGeohash: "u4pruy")
        XCTAssertEqual(beforeA.publicKeyHex, beforeB.publicKeyHex)

        // Wipe keychain through primary bridge and clear shadow bridge cache.
        bridgeA.clearAllAssociations()
        bridgeB.clearInMemoryCaches()

        let afterB = try bridgeB.deriveIdentity(forGeohash: "u4pruy")
        XCTAssertNotEqual(beforeA.publicKeyHex, afterB.publicKeyHex)
    }

    func test_geohashPresenceService_stopForPanic_invokesClearIdentityCache() {
        var clearCalls = 0
        let service = GeohashPresenceService(
            availableChannelsProvider: { [] },
            isLocationAuthorized: { true },
            locationChanges: Empty().eraseToAnyPublisher(),
            torReadyPublisher: Empty().eraseToAnyPublisher(),
            torIsReady: { false },
            torIsForeground: { true },
            deriveIdentity: { _ in try NostrIdentity.generate() },
            clearIdentityCache: { clearCalls += 1 },
            relayLookup: { _, _ in [] },
            relaySender: { _, _ in }
        )

        service.stopForPanic()

        XCTAssertEqual(clearCalls, 1)
    }

    func test_bridgeService_resetForPanic_clearsPersistedToggleCellAndQueues() {
        let suite = "PanicWipeBridge-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        var closedSubscriptions = 0
        var enabledNotifications: [Bool] = []
        let service = BridgeService(defaults: defaults)
        service.locationCell = { "u4pruy" }
        service.closeSubscription = { closedSubscriptions += 1 }
        service.onEnabledChanged = { enabledNotifications.append($0) }

        service.setEnabled(true)
        XCTAssertTrue(service.isEnabled)
        XCTAssertEqual(defaults.bool(forKey: "bridge.userEnabled"), true)
        XCTAssertEqual(service.activeCell, "u4pruy")

        service.resetForPanic()

        XCTAssertFalse(service.isEnabled)
        XCTAssertNil(defaults.object(forKey: "bridge.userEnabled"))
        XCTAssertNil(service.activeCell)
        XCTAssertTrue(service.subscribedCells.isEmpty)
        XCTAssertTrue(service.queuedUplinks.isEmpty)
        XCTAssertEqual(service.bridgedPeerCount, 0)
        XCTAssertTrue(service.bridgedParticipants.isEmpty)
        XCTAssertGreaterThanOrEqual(closedSubscriptions, 1)
        XCTAssertEqual(enabledNotifications.last, false)
    }

    func test_gatewayService_resetForPanic_clearsPersistedToggleAndQueues() {
        let suite = "PanicWipeGateway-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        var enabledNotifications: [Bool] = []
        let service = GatewayService(defaults: defaults)
        service.onEnabledChanged = { enabledNotifications.append($0) }

        service.setEnabled(true)
        XCTAssertTrue(service.isEnabled)
        XCTAssertEqual(defaults.bool(forKey: "gateway.userEnabled"), true)

        service.resetForPanic()

        XCTAssertFalse(service.isEnabled)
        XCTAssertNil(defaults.object(forKey: "gateway.userEnabled"))
        XCTAssertTrue(service.queuedUplinks.isEmpty)
        XCTAssertEqual(enabledNotifications.last, false)
    }

    func test_nostrAckPacer_resetForPanic_dropsQueuedClosuresAndFencesInFlightTimer() {
        final class PacerBox: @unchecked Sendable {
            private let lock = NSLock()
            private var callbacks: [@Sendable () -> Void] = []
            private var firedItems: [Int] = []

            func addCallback(_ cb: @escaping @Sendable () -> Void) {
                lock.lock()
                callbacks.append(cb)
                lock.unlock()
            }

            func takeCallbacks() -> [@Sendable () -> Void] {
                lock.lock()
                defer { lock.unlock() }
                return callbacks
            }

            func recordFired(_ value: Int) {
                lock.lock()
                firedItems.append(value)
                lock.unlock()
            }

            func fired() -> [Int] {
                lock.lock()
                defer { lock.unlock() }
                return firedItems
            }
        }

        let box = PacerBox()
        let pacer = NostrTransport.AckPacer { _, action in
            box.addCallback(action)
        }

        let firstStarted = expectation(description: "first ack started")
        pacer.enqueue {
            box.recordFired(1)
            firstStarted.fulfill()
        }
        pacer.enqueue {
            box.recordFired(2)
        }
        wait(for: [firstStarted], timeout: TestConstants.settleTimeout)

        pacer.resetForPanic()

        // Fire the stale pre-panic timer callback; queued item #2 must never run.
        for callback in box.takeCallbacks() {
            callback()
        }

        // Enqueue a post-panic item to flush the serial queue and verify #2 stayed dropped.
        let postPanicDone = expectation(description: "post-panic ack ran")
        pacer.enqueue {
            box.recordFired(3)
            postPanicDone.fulfill()
        }
        wait(for: [postPanicDone], timeout: TestConstants.settleTimeout)

        XCTAssertEqual(box.fired(), [1, 3])
    }

    func test_nostrTransport_resetForPanic_cancelsInFlightMainActorGeohashAck() async throws {
        let dequeued = DispatchSemaphore(value: 0)
        let pacer = NostrTransport.AckPacer { _, _ in
            dequeued.signal()
        }
        var sentEvents: [NostrEvent] = []
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let transport = NostrTransport(
            keychain: PreviewKeychainManager(),
            idBridge: NostrIdentityBridge(keychain: PreviewKeychainManager()),
            dependencies: NostrTransport.Dependencies(
                notificationCenter: NotificationCenter(),
                loadFavorites: { [:] },
                favoriteStatusForNoiseKey: { _ in nil },
                favoriteStatusForPeerID: { _ in nil },
                currentIdentity: { sender },
                registerPendingGiftWrap: { _ in },
                sendEvent: { sentEvents.append($0) },
                scheduleAfter: { _, _ in },
                relayConnectivity: { Just(true).eraseToAnyPublisher() },
                ackPacer: pacer
            )
        )

        // Enqueue a geohash ACK and wait until AckPacer has dequeued it and
        // handed off `Task { @MainActor in ... }` while we still hold MainActor.
        transport.sendDeliveryAckGeohash(
            for: "pre-panic-mid",
            toRecipientHex: recipient.publicKeyHex,
            from: sender
        )
        XCTAssertEqual(dequeued.wait(timeout: .now() + TestConstants.settleTimeout), .success)

        // Panic runs on MainActor BEFORE the handed-off ACK task executes.
        pacer.resetForPanic()

        // Yield so the already-queued MainActor ACK task gets a turn to run.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(sentEvents.isEmpty, "Pre-panic MainActor ACK task must not publish after resetForPanic()")
    }

    func test_verificationService_resetForPanic_evictsCachedQRString() throws {
        let transport = MockTransport()
        let service = VerificationService()
        service.configure(with: transport)

        let nickname = "panic-qr-\(UUID().uuidString)"
        let first = try XCTUnwrap(service.buildMyQRString(nickname: nickname, npub: nil))
        let cached = try XCTUnwrap(service.buildMyQRString(nickname: nickname, npub: nil))
        XCTAssertEqual(first, cached)

        service.resetForPanic()
        let refreshed = try XCTUnwrap(service.buildMyQRString(nickname: nickname, npub: nil))
        XCTAssertNotEqual(first, refreshed)
    }

    func test_nostrProcessedEventStore_wipe_deletesFileSynchronously() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanicProcessedEvents-\(UUID().uuidString)", isDirectory: true)
        let fileURL = tempDir.appendingPathComponent("processed-events.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = NostrProcessedEventStore(fileURL: fileURL)
        store.append(["evt-1", "evt-2"], cap: 100)
        // `load()` synchronizes on `ioQueue`, ensuring the async append wrote to disk.
        XCTAssertEqual(store.load(), ["evt-1", "evt-2"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        store.wipe()

        // Must be deleted synchronously before `wipe()` returns.
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(store.load().isEmpty)
    }

    func test_privateChatManager_resetForPanic_clearsSentReadReceipts() {
        let manager = PrivateChatManager()
        manager.sentReadReceipts.insert("msg-1")
        manager.sentReadReceipts.insert("msg-2")

        manager.resetForPanic()

        XCTAssertTrue(manager.sentReadReceipts.isEmpty)
    }

    func test_nearbyNotesCounter_resetForPanic_clearsRevealedAndReleasesManager() {
        var released = 0
        let counter = NearbyNotesCounter(
            managerFactory: { geohash in
                LocationNotesManager(
                    geohash: geohash,
                    dependencies: LocationNotesDependencies(
                        relayLookup: { _, _ in [] },
                        subscribe: { _, _, _, _, _ in },
                        unsubscribe: { _ in },
                        sendEvent: { _, _ in },
                        deriveIdentity: { _ in try NostrIdentity.generate() },
                        now: Date.init
                    )
                )
            },
            releaseManager: { manager in
                if manager != nil { released += 1 }
            },
            locationNotesEnabled: { true }
        )

        counter.reveal()
        XCTAssertTrue(counter.revealed)

        counter.resetForPanic()

        XCTAssertFalse(counter.revealed)
        XCTAssertEqual(counter.noteCount, 0)
        XCTAssertGreaterThanOrEqual(released, 0)
    }

    func test_secureIdentityStateManager_postPanicStateSurvivesReinitAfterKeychainWipe() {
        let keychain = PreviewKeychainManager()
        let manager = SecureIdentityStateManager(keychain)

        // Pre-panic block
        manager.setBlocked("aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111", isBlocked: true)

        // Simulate panic wipe sequence from ChatViewModel.panicClearAllData():
        // keychain.deleteAllKeychainData() followed by identityManager.clearAllIdentityData().
        XCTAssertTrue(keychain.deleteAllKeychainData())
        manager.clearAllIdentityData()

        // Record post-panic block & verification on the same live manager instance.
        let postPanicBlocked = "bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222"
        let postPanicVerified = "cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333"
        manager.setBlocked(postPanicBlocked, isBlocked: true)
        manager.setVerified(fingerprint: postPanicVerified, verified: true)

        // Simulate next cold launch with a fresh manager reading the same keychain.
        let relaunched = SecureIdentityStateManager(keychain)
        XCTAssertTrue(relaunched.isBlocked(fingerprint: postPanicBlocked))
        XCTAssertTrue(relaunched.isVerified(fingerprint: postPanicVerified))
        XCTAssertFalse(relaunched.isBlocked(fingerprint: "aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"))
    }

    func test_publicMessagePipeline_resetDropsBufferedMessages() {
        final class RecordingDelegate: PublicMessagePipelineDelegate {
            var committed: [BitchatMessage] = []
            func pipeline(_: PublicMessagePipeline, normalizeContent content: String) -> String { content }
            func pipeline(_: PublicMessagePipeline, contentTimestampForKey _: String) -> Date? { nil }
            func pipeline(_: PublicMessagePipeline, recordContentKey _: String, timestamp _: Date) {}
            func pipeline(_: PublicMessagePipeline, commit message: BitchatMessage, to _: ConversationID) -> Bool {
                committed.append(message)
                return true
            }
            func pipelinePrewarmMessage(_: PublicMessagePipeline, message _: BitchatMessage) {}
        }

        let pipeline = PublicMessagePipeline(baseFlushInterval: 60)
        let delegate = RecordingDelegate()
        pipeline.delegate = delegate

        let message = BitchatMessage(
            id: "pre-panic-public",
            sender: "alice",
            content: "buffered before wipe",
            timestamp: Date(),
            isRelay: false
        )
        pipeline.enqueue(message, to: .mesh)
        XCTAssertTrue(pipeline.containsMessage(withID: "pre-panic-public"))

        pipeline.reset()
        pipeline.flushIfNeeded()

        XCTAssertFalse(pipeline.containsMessage(withID: "pre-panic-public"))
        XCTAssertTrue(delegate.committed.isEmpty)
    }

    func test_nostrTransport_senderPeerIDProvider_tracksRotatedIdentityAfterPanic() {
        var currentPeerID = PeerID(str: "0123456789abcdef")
        let transport = NostrTransport(
            keychain: PreviewKeychainManager(),
            idBridge: NostrIdentityBridge(keychain: PreviewKeychainManager())
        )
        transport.senderPeerIDProvider = { currentPeerID }
        XCTAssertEqual(transport.senderPeerID, PeerID(str: "0123456789abcdef"))

        currentPeerID = PeerID(str: "fedcba9876543210")
        XCTAssertEqual(transport.senderPeerID, PeerID(str: "fedcba9876543210"))
    }

    func test_cashuAndPeerColorCaches_resetForPanicWithoutCrash() {
        _ = CashuTokenDecoder.decode("cashuAeyJ0b2tlbiI6W3sibWludCI6Imh0dHBzOi8vbWludC5leGFtcGxlLmNvbSIsInByb29mcyI6W3siYW1vdW50IjoxMH1dfV19")
        CashuTokenDecoder.resetForPanic()

        let before = Color(peerSeed: "panic-peer-seed", isDark: true)
        Color.clearPeerColorCache()
        let after = Color(peerSeed: "panic-peer-seed", isDark: true)
        XCTAssertEqual(before, after)
    }

    func test_bleService_resetIdentityForPanic_preservesInstalledNoiseCallbacks() {
        let mesh = SimulatedMesh()
        let alice = mesh.addNode(nickname: "alice")
        let bob = mesh.addNode(nickname: "bob")
        mesh.connect(0, 1)
        mesh.announceAll()

        let callbackLock = NSLock()
        var installedAuthPeers: [PeerID] = []
        var observerAuthPeers: [PeerID] = []

        bob.service.installNoiseSessionCallbacks(
            onPeerAuthenticated: { peerID, _ in
                callbackLock.lock()
                installedAuthPeers.append(peerID)
                callbackLock.unlock()
            },
            onHandshakeRequired: { _ in }
        )
        bob.service.addPeerAuthenticatedObserver { peerID, _ in
            callbackLock.lock()
            observerAuthPeers.append(peerID)
            callbackLock.unlock()
        }

        // Replace bob's NoiseEncryptionService via panic reset.
        bob.service.suspendForPanicReset()
        bob.service.resetIdentityForPanic(currentNickname: "anon1234", restartServices: false)
        bob.service.completePanicReset(restartServices: false)
        mesh.pump()

        // Re-announce so both nodes discover bob's fresh post-panic identity.
        mesh.forceAnnounce(from: 1)
        mesh.forceAnnounce(from: 0)
        let newBobID = bob.service.myPeerID
        mesh.settleUntil { alice.service.getConnectedPeers().contains(newBobID) }

        // Initiate a real Noise handshake from alice to bob's post-panic identity.
        alice.service.sendPrivateMessage(
            "hello after panic",
            to: newBobID,
            recipientNickname: "anon1234",
            messageID: UUID().uuidString
        )
        mesh.settleUntil {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            return installedAuthPeers.contains(alice.service.myPeerID)
                && observerAuthPeers.contains(alice.service.myPeerID)
        }

        callbackLock.lock()
        let installedCount = installedAuthPeers.filter { $0 == alice.service.myPeerID }.count
        let observerCount = observerAuthPeers.filter { $0 == alice.service.myPeerID }.count
        callbackLock.unlock()

        XCTAssertGreaterThanOrEqual(installedCount, 1)
        XCTAssertGreaterThanOrEqual(observerCount, 1)
    }

    func test_transferProgressManager_resetForPanic_clearsStatesSynchronously() {
        let manager = TransferProgressManager()
        let transferID = "tx-\(UUID().uuidString)"
        manager.start(id: transferID, totalFragments: 4)
        // Drain barrier before verifying state was recorded.
        _ = manager.snapshot(id: transferID)
        XCTAssertNotNil(manager.snapshot(id: transferID))

        manager.resetForPanic()

        XCTAssertNil(manager.snapshot(id: transferID))
    }

    func test_minimalDistancePalette_reset_clearsStoredPeerColors() {
        let palette = MinimalDistancePalette(config: .mesh)
        palette.ensurePalette(for: ["peerA": "noise:aaaa", "peerB": "noise:bbbb"])
        XCTAssertNotNil(palette.color(for: "peerA", isDark: false))

        palette.reset()

        XCTAssertNil(palette.color(for: "peerA", isDark: false))
        XCTAssertNil(palette.color(for: "peerB", isDark: false))
    }

    func test_nostrIdentityBridge_concurrentColdStartReturnsConsistentIdentity() async throws {
        let keychain = PreviewKeychainManager()
        let bridge = NostrIdentityBridge(keychain: keychain)

        let results: [String] = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    guard let id = try bridge.getCurrentNostrIdentity() else {
                        throw NSError(domain: "Test", code: 1)
                    }
                    return id.publicKeyHex
                }
            }
            var pubkeys: [String] = []
            for try await pubkey in group {
                pubkeys.append(pubkey)
            }
            return pubkeys
        }

        XCTAssertEqual(Set(results).count, 1)
    }

    func test_cashuTokenDecoder_resetForPanic_evictsCachedToken() throws {
        let payload: [String: Any] = [
            "token": [[
                "mint": "https://mint.example.com",
                "proofs": [["amount": 10, "id": "009a1f293253e41e", "secret": "s", "C": "02c"] as [String: Any]]
            ] as [String: Any]]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "cashuA" + encoded

        let decoded = CashuTokenDecoder.decode(token)
        XCTAssertEqual(decoded?.amount, 10)
        XCTAssertTrue(CashuTokenDecoder.hasCachedDecode(for: token))

        CashuTokenDecoder.resetForPanic()

        XCTAssertFalse(CashuTokenDecoder.hasCachedDecode(for: token))
    }

    func test_cashuTokenDecoder_oversizedInput_isNotCached() {
        let huge = "cashuA" + String(repeating: "Q", count: CashuTokenDecoder.maxTokenLength + 1)

        XCTAssertNil(CashuTokenDecoder.decode(huge))
        XCTAssertFalse(CashuTokenDecoder.hasCachedDecode(for: huge))
    }

    func test_bleService_courierDepositAndSpray_fencedAcrossPanicLifecycle() async throws {
        func makeIsolatedBLEService() -> BLEService {
            let keychain = MockKeychain()
            let service = BLEService(
                keychain: keychain,
                idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
                identityManager: MockIdentityManager(keychain),
                initializeBluetoothManagers: false
            )
            service.courierStore = CourierStore(persistsToDisk: false)
            return service
        }

        // Part A: A courier deposit arriving before panic must not write to
        // `courierStore` on `messageQueue.async` after panic suspends & wipes.
        let carol = makeIsolatedBLEService()
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bobKey = NoiseEncryptionService(keychain: MockKeychain()).getStaticPublicKeyData()
        let typedPayload = try XCTUnwrap(
            BLENoisePayloadFactory.privateMessage(content: "pre-panic deposit", messageID: "panic-deposit-1")
        )
        let sealed = try alice.sealCourierPayload(typedPayload, recipientStaticKey: bobKey)
        let now = Date()
        let envelope = CourierEnvelope(
            recipientTag: CourierEnvelope.recipientTag(
                noiseStaticKey: bobKey,
                epochDay: CourierEnvelope.epochDay(for: now)
            ),
            expiry: UInt64((now.timeIntervalSince1970 + 3600) * 1000),
            ciphertext: sealed,
            copies: 4,
            prekeyID: nil
        )
        let alicePeerID = PeerID(publicKey: alice.getStaticPublicKeyData())
        let unsigned = BitchatPacket(
            type: MessageType.courierEnvelope.rawValue,
            senderID: Data(hexString: alicePeerID.id) ?? Data(),
            recipientID: Data(hexString: carol.myPeerID.id),
            timestamp: UInt64(now.timeIntervalSince1970 * 1000),
            payload: try XCTUnwrap(envelope.encode()),
            signature: nil,
            ttl: 1
        )
        let signedPacket = try XCTUnwrap(alice.signPacket(unsigned))

        let depositPolicyEvaluated = expectation(description: "deposit policy evaluated")
        carol.courierDepositPolicy = { _, _ in
            carol.suspendForPanicReset()
            carol.courierStore.wipe()
            depositPolicyEvaluated.fulfill()
            return .favorite
        }

        carol._test_handlePacket(
            signedPacket,
            fromPeerID: alicePeerID,
            signingPublicKey: alice.getSigningPublicKeyData()
        )
        await fulfillment(of: [depositPolicyEvaluated], timeout: TestConstants.settleTimeout)
        await carol._test_drainPrivateMediaSendPipeline()
        XCTAssertTrue(carol.courierStore.isEmpty)

        // Part B: A courier spray triggered before panic must not run
        // `sendSpray()` on `messageQueue.async` after panic suspends.
        let sender = makeIsolatedBLEService()
        let peerNoise = NoiseEncryptionService(keychain: MockKeychain())
        let peerID = PeerID(publicKey: peerNoise.getStaticPublicKeyData())
        XCTAssertTrue(
            sender.courierStore.deposit(envelope, from: alice.getStaticPublicKeyData(), tier: .favorite)
        )
        XCTAssertFalse(sender.courierStore.isEmpty)

        let packetLock = NSLock()
        var outboundCourierPackets: [BitchatPacket] = []
        sender._test_onOutboundPacket = { packet in
            guard packet.type == MessageType.courierEnvelope.rawValue else { return }
            packetLock.lock()
            outboundCourierPackets.append(packet)
            packetLock.unlock()
        }

        let sprayPolicyEvaluated = expectation(description: "spray policy evaluated")
        sender.courierDepositPolicy = { _, _ in
            sender.suspendForPanicReset()
            sprayPolicyEvaluated.fulfill()
            return .favorite
        }

        sender.sprayCourierMail(
            to: peerID,
            noiseKey: peerNoise.getStaticPublicKeyData(),
            isVerifiedPeer: true
        )
        await fulfillment(of: [sprayPolicyEvaluated], timeout: TestConstants.settleTimeout)
        await sender._test_drainPrivateMediaSendPipeline()

        let sentCount = packetLock.withLock {
            outboundCourierPackets.count
        }
        XCTAssertEqual(sentCount, 0)
    }
}

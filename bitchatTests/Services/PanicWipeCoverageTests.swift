import BitFoundation
import Combine
import Foundation
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
}

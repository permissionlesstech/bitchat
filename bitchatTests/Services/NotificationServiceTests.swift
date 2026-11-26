import XCTest
import UserNotifications
import BitFoundation
@testable import bitchat

final class NotificationServiceTests: XCTestCase {
    func test_requestAuthorization_skipsWhenRunningTests() {
        let authorizer = RecordingNotificationAuthorizer()
        let service = NotificationService(
            isRunningTestsProvider: { true },
            authorizer: authorizer,
            requestDeliverer: RecordingNotificationRequestDeliverer()
        )

        service.requestAuthorization()

        XCTAssertEqual(authorizer.requestCallCount, 0)
    }

    func test_requestAuthorization_requestsAlertSoundAndBadgePermissions() {
        let authorizer = RecordingNotificationAuthorizer()
        let service = NotificationService(
            isRunningTestsProvider: { false },
            authorizer: authorizer,
            requestDeliverer: RecordingNotificationRequestDeliverer()
        )

        service.requestAuthorization()

        XCTAssertEqual(authorizer.requestCallCount, 1)
        XCTAssertEqual(authorizer.lastOptions, [.alert, .sound, .badge])
    }

    func test_sendLocalNotification_buildsImmediateRequestWithUserInfo() {
        let deliverer = RecordingNotificationRequestDeliverer()
        let service = NotificationService(
            isRunningTestsProvider: { false },
            authorizer: RecordingNotificationAuthorizer(),
            requestDeliverer: deliverer
        )

        service.sendLocalNotification(
            title: "Hello",
            body: "World",
            identifier: "custom-id",
            userInfo: ["peerID": "abcd"],
            interruptionLevel: .timeSensitive
        )

        let request = deliverer.requests.singleValue
        XCTAssertEqual(request?.identifier, "custom-id")
        XCTAssertEqual(request?.content.title, "Hello")
        XCTAssertEqual(request?.content.body, "World")
        XCTAssertEqual(request?.content.userInfo["peerID"] as? String, "abcd")
        XCTAssertEqual(request?.content.interruptionLevel, .timeSensitive)
        XCTAssertNil(request?.trigger)
    }

    /// Previews shown: the opt-in behavior. Stated explicitly rather than
    /// inherited from the shared preference, which now defaults to hidden.
    func test_sendPrivateMessageNotification_populatesPeerMetadata() {
        let deliverer = RecordingNotificationRequestDeliverer()
        let service = NotificationService(
            isRunningTestsProvider: { false },
            authorizer: RecordingNotificationAuthorizer(),
            requestDeliverer: deliverer,
            hidePreviewsProvider: { false }
        )
        let peerID = PeerID(str: "deadbeefdeadbeef")

        service.sendPrivateMessageNotification(from: "Alice", message: "hi", peerID: peerID)

        let request = deliverer.requests.singleValue
        XCTAssertEqual(request?.content.title, "🔒 DM from Alice")
        XCTAssertEqual(request?.content.body, "hi")
        XCTAssertEqual(request?.content.userInfo["peerID"] as? String, peerID.id)
    }

    func test_removeAllNotifications_removesThemFromTheCenter() {
        let remover = RecordingNotificationRemover()
        let service = NotificationService(
            isRunningTestsProvider: { false },
            authorizer: RecordingNotificationAuthorizer(),
            requestDeliverer: RecordingNotificationRequestDeliverer(),
            remover: remover
        )

        service.removeAllNotifications()

        XCTAssertEqual(remover.removalCount, 1)
    }

    func test_removeAllNotifications_skipsWhenRunningTests() {
        let remover = RecordingNotificationRemover()
        let service = NotificationService(
            isRunningTestsProvider: { true },
            authorizer: RecordingNotificationAuthorizer(),
            requestDeliverer: RecordingNotificationRequestDeliverer(),
            remover: remover
        )

        service.removeAllNotifications()

        XCTAssertEqual(remover.removalCount, 0)
    }

    /// A post the center finishes taking between the removal and the
    /// invalidation would find its generation still current and stay up.
    func test_removeAllNotifications_invalidatesPostsBeforeRemoving() {
        let generation = NotificationPostGeneration()
        let postedBefore = generation.current
        var stillCurrentAtRemoval: Bool?
        let remover = RecordingNotificationRemover {
            stillCurrentAtRemoval = generation.isCurrent(postedBefore)
        }
        let service = NotificationService(
            isRunningTestsProvider: { false },
            authorizer: RecordingNotificationAuthorizer(),
            requestDeliverer: RecordingNotificationRequestDeliverer(),
            remover: remover,
            postGeneration: generation
        )

        service.removeAllNotifications()

        XCTAssertEqual(stillCurrentAtRemoval, false)
    }

    func test_deliver_handsTheCenterARequestNoWipeOvertook() async {
        let center = FakeNotificationCenter()
        let generation = NotificationPostGeneration()
        let deliverer = NotificationCenterRequestDelivererAdapter(center: center, generation: generation)

        await deliverer.deliver(Self.request("dm-1"), postedIn: generation.current)

        XCTAssertEqual(center.added, ["dm-1"])
        XCTAssertEqual(center.removedDelivered, [])
        XCTAssertEqual(center.removedPending, [])
    }

    func test_deliver_dropsARequestPostedBeforeAWipe() async {
        let center = FakeNotificationCenter()
        let generation = NotificationPostGeneration()
        let deliverer = NotificationCenterRequestDelivererAdapter(center: center, generation: generation)
        let postedIn = generation.current
        generation.invalidate()

        await deliverer.deliver(Self.request("dm-1"), postedIn: postedIn)

        XCTAssertEqual(center.added, [])
    }

    /// The wipe starts while the center is still taking the request, so the
    /// wipe's own removal can run before the request lands.
    func test_deliver_takesBackARequestAWipeOvertakesInFlight() async {
        let center = FakeNotificationCenter()
        let addStarted = expectation(description: "the center started taking the request")
        center.holdAdds { addStarted.fulfill() }
        let generation = NotificationPostGeneration()
        let deliverer = NotificationCenterRequestDelivererAdapter(center: center, generation: generation)
        let postedIn = generation.current

        let delivery = Task { await deliverer.deliver(Self.request("dm-1"), postedIn: postedIn) }
        await fulfillment(of: [addStarted], timeout: TestConstants.settleTimeout)
        generation.invalidate()
        center.releaseHeldAdd()
        await delivery.value

        XCTAssertEqual(center.added, ["dm-1"])
        XCTAssertEqual(center.removedDelivered, ["dm-1"])
        XCTAssertEqual(center.removedPending, ["dm-1"])
    }

    func test_removerAdapter_removesPendingRequestsAsWellAsDeliveredAlerts() {
        let center = FakeNotificationCenter()

        NotificationCenterRemoverAdapter(center: center).removeAllNotifications()

        XCTAssertEqual(center.pendingClears, 1)
        XCTAssertEqual(center.deliveredClears, 1)
    }

    private static func request(_ identifier: String) -> UNNotificationRequest {
        UNNotificationRequest(identifier: identifier, content: UNMutableNotificationContent(), trigger: nil)
    }

    /// Previews hidden: the default. The routing payload has to survive
    /// redaction, or tapping the alert would not open the conversation.
    func test_sendPrivateMessageNotification_withPreviewsHidden_keepsRoutingButDropsContent() {
        let deliverer = RecordingNotificationRequestDeliverer()
        let service = NotificationService(
            isRunningTestsProvider: { false },
            authorizer: RecordingNotificationAuthorizer(),
            requestDeliverer: deliverer,
            hidePreviewsProvider: { true }
        )
        let peerID = PeerID(str: "deadbeefdeadbeef")

        service.sendPrivateMessageNotification(from: "Alice", message: "hi", peerID: peerID)

        let request = deliverer.requests.singleValue
        XCTAssertFalse(request?.content.title.contains("Alice") ?? true)
        XCTAssertFalse(request?.content.body.contains("hi") ?? true)
        XCTAssertFalse(request?.content.title.isEmpty ?? true)
        XCTAssertEqual(request?.content.userInfo["peerID"] as? String, peerID.id)
        // Routing reads only the peer ID. With previews hidden the title
        // omits the sender, so userInfo must not carry it either.
        XCTAssertEqual(request?.content.userInfo.count, 1)
    }

    func test_wrapperNotifications_setExpectedIdentifiersAndDeepLinks() {
        let deliverer = RecordingNotificationRequestDeliverer()
        let service = NotificationService(
            isRunningTestsProvider: { false },
            authorizer: RecordingNotificationAuthorizer(),
            requestDeliverer: deliverer
        )

        service.sendGeohashActivityNotification(geohash: "87yv", bodyPreview: "Someone is here")
        service.sendNetworkAvailableNotification(peerCount: 2)

        XCTAssertEqual(deliverer.requests.count, 2)
        XCTAssertEqual(deliverer.requests[0].content.userInfo["deeplink"] as? String, "bitchat://geohash/87yv")
        XCTAssertTrue(deliverer.requests[0].identifier.hasPrefix("geo-activity-87yv-"))
        XCTAssertEqual(deliverer.requests[1].identifier, "network-available")
        XCTAssertEqual(deliverer.requests[1].content.interruptionLevel, .timeSensitive)
        XCTAssertEqual(deliverer.requests[1].content.body, "2 people around")
    }
}

private final class RecordingNotificationAuthorizer: NotificationAuthorizing {
    private(set) var requestCallCount = 0
    private(set) var lastOptions: UNAuthorizationOptions?

    func requestAuthorization(
        options: UNAuthorizationOptions,
        completionHandler: @escaping (Bool, Error?) -> Void
    ) {
        requestCallCount += 1
        lastOptions = options
        completionHandler(true, nil)
    }
}

private final class RecordingNotificationRequestDeliverer: NotificationRequestDelivering {
    private(set) var requests: [UNNotificationRequest] = []

    func add(_ request: UNNotificationRequest) {
        requests.append(request)
    }
}

private final class RecordingNotificationRemover: NotificationRemoving {
    private(set) var removalCount = 0
    private let onRemove: () -> Void

    init(onRemove: @escaping () -> Void = {}) {
        self.onRemove = onRemove
    }

    func removeAllNotifications() {
        removalCount += 1
        onRemove()
    }
}

/// Records what reaches the center. After `holdAdds`, `add` waits until
/// `releaseHeldAdd()`, so a test can start a wipe mid-add.
private final class FakeNotificationCenter: NotificationCenterPosting, NotificationCenterClearing, @unchecked Sendable {
    private let lock = NSLock()
    private var addedIDs: [String] = []
    private var removedDeliveredIDs: [String] = []
    private var removedPendingIDs: [String] = []
    private var pendingClearCount = 0
    private var deliveredClearCount = 0
    private var onAddHeld: (() -> Void)?
    private var heldAdd: CheckedContinuation<Void, Never>?

    var added: [String] { lock.withLock { addedIDs } }
    var removedDelivered: [String] { lock.withLock { removedDeliveredIDs } }
    var removedPending: [String] { lock.withLock { removedPendingIDs } }
    var pendingClears: Int { lock.withLock { pendingClearCount } }
    var deliveredClears: Int { lock.withLock { deliveredClearCount } }

    func holdAdds(onHeld: @escaping () -> Void) {
        lock.withLock { onAddHeld = onHeld }
    }

    func releaseHeldAdd() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { heldAdd = nil }
            return heldAdd
        }
        continuation?.resume()
    }

    func add(_ request: UNNotificationRequest) async throws {
        if let onHeld = lock.withLock({ onAddHeld }) {
            await withCheckedContinuation { continuation in
                lock.withLock { heldAdd = continuation }
                onHeld()
            }
        }
        lock.withLock { addedIDs.append(request.identifier) }
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        lock.withLock { removedDeliveredIDs += identifiers }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        lock.withLock { removedPendingIDs += identifiers }
    }

    func removeAllPendingNotificationRequests() {
        lock.withLock { pendingClearCount += 1 }
    }

    func removeAllDeliveredNotifications() {
        lock.withLock { deliveredClearCount += 1 }
    }
}

private extension Array {
    var singleValue: Element? {
        count == 1 ? self[0] : nil
    }
}

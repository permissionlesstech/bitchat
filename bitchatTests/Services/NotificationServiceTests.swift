import XCTest
import UserNotifications
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

    func test_sendPrivateMessageNotification_populatesPeerMetadata() {
        let deliverer = RecordingNotificationRequestDeliverer()
        let service = NotificationService(
            isRunningTestsProvider: { false },
            authorizer: RecordingNotificationAuthorizer(),
            requestDeliverer: deliverer
        )
        let peerID = PeerID(str: "deadbeefdeadbeef")

        service.sendPrivateMessageNotification(from: "Alice", message: "hi", peerID: peerID)

        let request = deliverer.requests.singleValue
        XCTAssertEqual(request?.content.title, "🔒 DM from Alice")
        XCTAssertEqual(request?.content.body, "hi")
        XCTAssertEqual(request?.content.userInfo["peerID"] as? String, peerID.id)
        XCTAssertEqual(request?.content.userInfo["senderName"] as? String, "Alice")
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

private extension Array {
    var singleValue: Element? {
        count == 1 ? self[0] : nil
    }
}

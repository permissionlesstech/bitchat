import XCTest
import UserNotifications
import BitFoundation
@testable import bitchat

final class NotificationServiceTests: XCTestCase {
    func test_requestAuthorization_skipsWhenRunningTests() {
        var requestCallCount = 0
        var deps = NotificationService.Dependencies.noop
        deps.requestAuthorization = { _, completion in
            requestCallCount += 1
            completion(true, nil)
        }
        let service = NotificationService(
            isRunningTestsProvider: { true },
            dependencies: deps
        )

        service.requestAuthorization()

        XCTAssertEqual(requestCallCount, 0)
    }

    func test_requestAuthorization_requestsAlertSoundAndBadgePermissions() {
        var requestCallCount = 0
        var lastOptions: UNAuthorizationOptions?
        var deps = NotificationService.Dependencies.noop
        deps.requestAuthorization = { options, completion in
            requestCallCount += 1
            lastOptions = options
            completion(true, nil)
        }
        let service = NotificationService(
            isRunningTestsProvider: { false },
            dependencies: deps
        )

        service.requestAuthorization()

        XCTAssertEqual(requestCallCount, 1)
        XCTAssertEqual(lastOptions, [.alert, .sound, .badge])
    }

    func test_sendLocalNotification_buildsImmediateRequestWithUserInfo() {
        var requests: [UNNotificationRequest] = []
        var deps = NotificationService.Dependencies.noop
        deps.deliver = { requests.append($0) }
        let service = NotificationService(
            isRunningTestsProvider: { false },
            dependencies: deps
        )

        service.sendLocalNotification(
            title: "Hello",
            body: "World",
            identifier: "custom-id",
            userInfo: ["peerID": "abcd"],
            interruptionLevel: .timeSensitive
        )

        let request = requests.singleValue
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
        var requests: [UNNotificationRequest] = []
        var deps = NotificationService.Dependencies.noop
        deps.deliver = { requests.append($0) }
        let service = NotificationService(
            isRunningTestsProvider: { false },
            dependencies: deps,
            hidePreviewsProvider: { false }
        )
        let peerID = PeerID(str: "deadbeefdeadbeef")

        service.sendPrivateMessageNotification(from: "Alice", message: "hi", peerID: peerID)

        let request = requests.singleValue
        XCTAssertEqual(request?.content.title, "🔒 DM from Alice")
        XCTAssertEqual(request?.content.body, "hi")
        XCTAssertEqual(request?.content.userInfo["peerID"] as? String, peerID.id)
        XCTAssertEqual(request?.content.userInfo["senderName"] as? String, "Alice")
    }

    /// Previews hidden: the default. The routing payload has to survive
    /// redaction, or tapping the alert would not open the conversation.
    func test_sendPrivateMessageNotification_withPreviewsHidden_keepsRoutingButDropsContent() {
        var requests: [UNNotificationRequest] = []
        var deps = NotificationService.Dependencies.noop
        deps.deliver = { requests.append($0) }
        let service = NotificationService(
            isRunningTestsProvider: { false },
            dependencies: deps,
            hidePreviewsProvider: { true }
        )
        let peerID = PeerID(str: "deadbeefdeadbeef")

        service.sendPrivateMessageNotification(from: "Alice", message: "hi", peerID: peerID)

        let request = requests.singleValue
        XCTAssertFalse(request?.content.title.contains("Alice") ?? true)
        XCTAssertFalse(request?.content.body.contains("hi") ?? true)
        XCTAssertFalse(request?.content.title.isEmpty ?? true)
        XCTAssertEqual(request?.content.userInfo["peerID"] as? String, peerID.id)
    }

    func test_wrapperNotifications_setExpectedIdentifiersAndDeepLinks() {
        var requests: [UNNotificationRequest] = []
        var deps = NotificationService.Dependencies.noop
        deps.deliver = { requests.append($0) }
        let service = NotificationService(
            isRunningTestsProvider: { false },
            dependencies: deps
        )

        service.sendGeohashActivityNotification(geohash: "87yv", bodyPreview: "Someone is here")
        service.sendNetworkAvailableNotification(peerCount: 2)

        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].content.userInfo["deeplink"] as? String, "bitchat://geohash/87yv")
        XCTAssertTrue(requests[0].identifier.hasPrefix("geo-activity-87yv-"))
        XCTAssertEqual(requests[1].identifier, "network-available")
        XCTAssertEqual(requests[1].content.interruptionLevel, .timeSensitive)
        XCTAssertEqual(requests[1].content.body, "2 people around")
    }

    func test_clearAllNotificationsForPanic_clearsPendingAndDelivered() {
        var removePendingCalls = 0
        var removeDeliveredCalls = 0
        var deps = NotificationService.Dependencies.noop
        deps.removeAllPending = { removePendingCalls += 1 }
        deps.removeAllDelivered = { removeDeliveredCalls += 1 }
        let service = NotificationService(
            isRunningTestsProvider: { false },
            dependencies: deps
        )

        service.clearAllNotificationsForPanic()

        XCTAssertEqual(removePendingCalls, 1)
        XCTAssertEqual(removeDeliveredCalls, 1)
    }

    func test_clearAllNotificationsForPanic_skipsWhenRunningTests() {
        var removePendingCalls = 0
        var removeDeliveredCalls = 0
        var deps = NotificationService.Dependencies.noop
        deps.removeAllPending = { removePendingCalls += 1 }
        deps.removeAllDelivered = { removeDeliveredCalls += 1 }
        let service = NotificationService(
            isRunningTestsProvider: { true },
            dependencies: deps
        )

        service.clearAllNotificationsForPanic()

        XCTAssertEqual(removePendingCalls, 0)
        XCTAssertEqual(removeDeliveredCalls, 0)
    }
}

private extension Array {
    var singleValue: Element? {
        count == 1 ? self[0] : nil
    }
}

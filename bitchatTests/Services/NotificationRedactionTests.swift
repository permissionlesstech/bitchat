import BitFoundation
import Foundation
import Testing
import UserNotifications
@testable import bitchat

/// Lock-screen notifications used to carry the DM body and the sender's
/// nickname verbatim, and the geohash in the title, so a locked phone lying on
/// a table narrated conversations to anyone looking at it. These cover the
/// redaction that is now the default.
///
/// The preference is injected rather than written to shared preferences. These
/// run in the same process as `NotificationServiceTests`, and mutating the
/// global store made whichever ran second depend on the other's cleanup — which
/// passed locally and failed in CI.
struct NotificationRedactionTests {
    private final class RecordingDeliverer: NotificationRequestDelivering {
        var requests: [UNNotificationRequest] = []

        func add(_ request: UNNotificationRequest) {
            requests.append(request)
        }
    }

    private struct StubAuthorizer: NotificationAuthorizing {
        func requestAuthorization(
            options: UNAuthorizationOptions,
            completionHandler: @escaping (Bool, Error?) -> Void
        ) {
            completionHandler(true, nil)
        }
    }

    private func makeService(
        hidePreviews: Bool
    ) -> (NotificationService, RecordingDeliverer) {
        let deliverer = RecordingDeliverer()
        let service = NotificationService(
            isRunningTestsProvider: { false },
            authorizer: StubAuthorizer(),
            requestDeliverer: deliverer,
            hidePreviewsProvider: { hidePreviews }
        )
        return (service, deliverer)
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "bitchat.tests.notifications.\(UUID().uuidString)")!
    }

    @Test func previewsAreHiddenByDefault() {
        // A fresh install must start quiet rather than opt-in quiet.
        #expect(NotificationPrivacySettings.hideMessagePreviews(in: isolatedDefaults()))
    }

    @Test func theSettingRoundTrips() {
        let defaults = isolatedDefaults()

        NotificationPrivacySettings.setHideMessagePreviews(false, in: defaults)
        #expect(!NotificationPrivacySettings.hideMessagePreviews(in: defaults))

        // Panic wipe restores the safe default rather than the last choice.
        NotificationPrivacySettings.reset(in: defaults)
        #expect(NotificationPrivacySettings.hideMessagePreviews(in: defaults))
    }

    @Test func redactedDirectMessageWithholdsSenderAndBody() throws {
        let (service, deliverer) = makeService(hidePreviews: true)

        service.sendPrivateMessageNotification(
            from: "alice",
            message: "meet at the north gate",
            peerID: PeerID(str: "00112233445566ff")
        )

        let content = try #require(deliverer.requests.first).content
        #expect(!content.title.contains("alice"))
        #expect(!content.body.contains("north gate"))
        #expect(!content.title.isEmpty)
        // Still routable: userInfo is never rendered on the lock screen.
        #expect(content.userInfo["peerID"] as? String == "00112233445566ff")
    }

    @Test func redactedMentionWithholdsSenderAndBody() throws {
        let (service, deliverer) = makeService(hidePreviews: true)

        service.sendMentionNotification(from: "bob", message: "regroup now")

        let content = try #require(deliverer.requests.first).content
        #expect(!content.title.contains("bob"))
        #expect(!content.body.contains("regroup"))
    }

    @Test func redactedGeohashActivityWithholdsTheGeohash() throws {
        let (service, deliverer) = makeService(hidePreviews: true)

        service.sendGeohashActivityNotification(
            geohash: "u4pruyd",
            bodyPreview: "someone said something"
        )

        let content = try #require(deliverer.requests.first).content
        #expect(!content.title.contains("u4pruyd"))
        #expect(!content.body.contains("someone said"))
        // The deep link still carries it: tapping must land in the channel.
        #expect(content.userInfo["deeplink"] as? String == "bitchat://geohash/u4pruyd")
    }

    @Test func previewsShownWhenTheSettingIsOff() {
        let (service, deliverer) = makeService(hidePreviews: false)

        service.sendPrivateMessageNotification(
            from: "alice",
            message: "meet at the north gate",
            peerID: PeerID(str: "00112233445566ff")
        )
        service.sendGeohashActivityNotification(
            geohash: "u4pruyd",
            bodyPreview: "someone said something"
        )

        #expect(deliverer.requests.count == 2)
        let dm = deliverer.requests[0].content
        #expect(dm.title.contains("alice"))
        #expect(dm.body == "meet at the north gate")
        let geo = deliverer.requests[1].content
        #expect(geo.title.contains("u4pruyd"))
        #expect(geo.body == "someone said something")
    }
}

import BitFoundation
import Foundation
import Testing
import UserNotifications
@testable import bitchat

@Suite(.serialized)
struct BitchatHarnessServiceTests {
    @Test func decodesServiceRequestArguments() throws {
        let line = #"{"arguments":{"channel":"mesh","text":"hello","to":"alice"},"command":"send"}"#
        let request = try HarnessServiceRequest.decode(line)

        #expect(request.command == "send")
        #expect(request.string("text") == "hello")
        #expect(request.string("to") == "alice")
        #expect(request.string("channel") == "mesh")
    }

    @Test func encodesServiceResponseAsJSONLines() throws {
        let line = try HarnessServiceResponse.encodeLines([
            ["type": "service", "status": "running"],
            ["type": "status", "backend_mode": "live"]
        ])

        let rows = line.split(separator: "\n").map(String.init)
        #expect(rows.count == 2)
        #expect(rows[0].contains(#""service""#))
        #expect(rows[1].contains(#""live""#))
    }

    @Test func inboundPrivateMessageNotifiesOnce() {
        let peerID = PeerID(str: "deadbeefdeadbeef")
        let notifier = RecordingHarnessDirectMessageNotifier()
        let recorder = makeRecorder(notifier: notifier)
        let message = BitchatMessage(
            id: "inbound-private-1",
            sender: "Alice",
            content: "secret hello",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "agent",
            senderPeerID: peerID
        )

        recorder.recordIfInbound(message, chatID: "dm:\(peerID.id)", nickname: "agent")

        #expect(notifier.notifications.count == 1)
        #expect(notifier.notifications.first?.sender == "Alice")
        #expect(notifier.notifications.first?.message == "secret hello")
        #expect(notifier.notifications.first?.peerID == peerID)
    }

    @Test func duplicateInboundPrivateMessageDoesNotNotifyTwice() {
        let peerID = PeerID(str: "deadbeefdeadbeef")
        let notifier = RecordingHarnessDirectMessageNotifier()
        let recorder = makeRecorder(notifier: notifier)
        let message = BitchatMessage(
            id: "duplicate-private-1",
            sender: "Alice",
            content: "only once",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "agent",
            senderPeerID: peerID
        )

        recorder.recordIfInbound(message, chatID: "dm:\(peerID.id)", nickname: "agent")
        recorder.recordIfInbound(message, chatID: "dm:\(peerID.id)", nickname: "agent")

        #expect(notifier.notifications.count == 1)
    }

    @Test func selfPrivateMessageDoesNotNotify() {
        let myPeerID = PeerID(str: "feedfacefeedface")
        let notifier = RecordingHarnessDirectMessageNotifier()
        let recorder = makeRecorder(myPeerID: myPeerID, notifier: notifier)
        let message = BitchatMessage(
            id: "self-private-1",
            sender: "agent",
            content: "local echo",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Alice",
            senderPeerID: myPeerID
        )

        recorder.recordIfInbound(message, chatID: "dm:\(myPeerID.id)", nickname: "agent")

        #expect(notifier.notifications.isEmpty)
    }

    @Test func privateMessageFromOwnNicknameDoesNotNotify() {
        let peerID = PeerID(str: "deadbeefdeadbeef")
        let notifier = RecordingHarnessDirectMessageNotifier()
        let recorder = makeRecorder(notifier: notifier)
        let message = BitchatMessage(
            id: "own-nickname-private-1",
            sender: "agent#mac",
            content: "local echo",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Alice",
            senderPeerID: peerID
        )

        recorder.recordIfInbound(message, chatID: "dm:\(peerID.id)", nickname: "agent")

        #expect(notifier.notifications.isEmpty)
    }

    @Test func publicMessageDoesNotNotify() {
        let peerID = PeerID(str: "deadbeefdeadbeef")
        let notifier = RecordingHarnessDirectMessageNotifier()
        let recorder = makeRecorder(notifier: notifier)
        let message = BitchatMessage(
            id: "public-1",
            sender: "Alice",
            content: "hello mesh",
            timestamp: Date(),
            isRelay: false,
            isPrivate: false,
            senderPeerID: peerID
        )

        recorder.recordIfInbound(message, chatID: "mesh", nickname: "agent")

        #expect(notifier.notifications.isEmpty)
    }

    @Test func harnessNotificationSetupRegistersCopyMessageAction() {
        let notificationCenter = RecordingHarnessNotificationCenter()
        let pasteboard = RecordingHarnessMessagePasteboard()
        let notifier = HarnessUserNotificationDirectMessageNotifier(
            notificationCenter: notificationCenter,
            pasteboard: pasteboard
        )

        notifier.requestAuthorization()

        #expect(notificationCenter.requestCallCount == 1)
        #expect(notificationCenter.delegate is HarnessNotificationDelegate)
        let category = notificationCenter.categories.singleValue
        #expect(category?.identifier == HarnessNotificationConstants.privateMessageCategoryIdentifier)
        #expect(category?.actions.count == 1)
        let action = category?.actions.first
        #expect(action?.identifier == HarnessNotificationConstants.copyMessageActionIdentifier)
        #expect(action?.title == "Copy Message")
    }

    @Test func copyMessageActionCopiesMessageBodyToPasteboard() {
        let pasteboard = RecordingHarnessMessagePasteboard()
        let delegate = HarnessNotificationDelegate(pasteboard: pasteboard, logger: { _ in })

        delegate.handleResponse(
            actionIdentifier: HarnessNotificationConstants.copyMessageActionIdentifier,
            userInfo: ["message": "copy this exact text"]
        )

        #expect(pasteboard.copiedMessages == ["copy this exact text"])
    }

    @Test func nonCopyNotificationResponseDoesNotMutatePasteboard() {
        let pasteboard = RecordingHarnessMessagePasteboard()
        let delegate = HarnessNotificationDelegate(pasteboard: pasteboard, logger: { _ in })

        delegate.handleResponse(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: ["message": "do not copy"]
        )

        #expect(pasteboard.copiedMessages.isEmpty)
    }

    private func makeRecorder(
        myPeerID: PeerID = PeerID(str: "feedfacefeedface"),
        notifier: HarnessDirectMessageNotifying
    ) -> LiveHarnessEventRecorder {
        LiveHarnessEventRecorder(
            myPeerID: myPeerID,
            historyPath: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("jsonl"),
            notifier: notifier
        )
    }
}

private final class RecordingHarnessDirectMessageNotifier: HarnessDirectMessageNotifying {
    private(set) var notifications: [(sender: String, message: String, peerID: PeerID)] = []

    func requestAuthorization() {}

    func notifyPrivateMessage(from sender: String, message: String, peerID: PeerID) {
        notifications.append((sender, message, peerID))
    }
}

private final class RecordingHarnessNotificationCenter: HarnessNotificationCenterManaging {
    private(set) var requestCallCount = 0
    private(set) var categories: Set<UNNotificationCategory> = []
    private(set) var delegate: (any UNUserNotificationCenterDelegate)?

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        self.categories = categories
    }

    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {
        self.delegate = delegate
    }

    func requestAuthorization(
        options: UNAuthorizationOptions,
        completionHandler: @escaping (Bool, (any Error)?) -> Void
    ) {
        requestCallCount += 1
        completionHandler(true, nil)
    }
}

private final class RecordingHarnessMessagePasteboard: HarnessMessagePasteboarding {
    private(set) var copiedMessages: [String] = []

    func copyMessage(_ message: String) -> Bool {
        copiedMessages.append(message)
        return true
    }
}

private extension Set {
    var singleValue: Element? {
        count == 1 ? first : nil
    }
}

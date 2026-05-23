#if os(macOS)
import AppKit
import BitFoundation
import Combine
import CoreBluetooth
import Foundation
import Network
import UserNotifications

enum HarnessServiceLog {
    private static let queue = DispatchQueue(label: "chat.bitchat.harness.service-log")
    private static var path: URL?

    static func configure(path pathString: String?) {
        guard let pathString, !pathString.isEmpty else { return }
        path = URL(fileURLWithPath: pathString)
    }

    static func write(_ message: String) {
        fputs("\(message)\n", stderr)
        guard let path else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: path) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: path, options: [.atomic])
            }
        }
    }
}

struct HarnessServiceRequest {
    let command: String
    let arguments: [String: Any]

    static func decode(_ line: String) throws -> HarnessServiceRequest {
        guard let data = line.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = object["command"] as? String else {
            throw HarnessServiceError.message("invalid service request")
        }
        return HarnessServiceRequest(
            command: command,
            arguments: object["arguments"] as? [String: Any] ?? [:]
        )
    }

    func string(_ key: String) -> String? {
        arguments[key] as? String
    }
}

enum HarnessServiceResponse {
    static func encodeLines(_ objects: [[String: Any]]) throws -> String {
        try objects.map { object in
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            guard let line = String(data: data, encoding: .utf8) else {
                throw HarnessServiceError.message("failed to encode service response")
            }
            return line
        }.joined(separator: "\n") + "\n"
    }
}

enum HarnessServiceError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}

protocol HarnessDirectMessageNotifying: AnyObject {
    func requestAuthorization()
    func notifyPrivateMessage(from sender: String, message: String, peerID: PeerID)
}

protocol HarnessNotificationCenterManaging: AnyObject {
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?)
    func requestAuthorization(
        options: UNAuthorizationOptions,
        completionHandler: @escaping (Bool, Error?) -> Void
    )
}

protocol HarnessMessagePasteboarding: AnyObject {
    func copyMessage(_ message: String) -> Bool
}

private final class HarnessNotificationCenterManager: HarnessNotificationCenterManaging {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        center.setNotificationCategories(categories)
    }

    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {
        center.delegate = delegate
    }

    func requestAuthorization(
        options: UNAuthorizationOptions,
        completionHandler: @escaping (Bool, Error?) -> Void
    ) {
        center.requestAuthorization(options: options, completionHandler: completionHandler)
    }
}

private final class HarnessMessagePasteboard: HarnessMessagePasteboarding {
    func copyMessage(_ message: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(message, forType: .string)
    }
}

final class HarnessNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let pasteboard: HarnessMessagePasteboarding
    private let logger: (String) -> Void

    init(
        pasteboard: HarnessMessagePasteboarding = HarnessMessagePasteboard(),
        logger: @escaping (String) -> Void = HarnessServiceLog.write
    ) {
        self.pasteboard = pasteboard
        self.logger = logger
    }

    func handleResponse(actionIdentifier: String, userInfo: [AnyHashable: Any]) {
        guard actionIdentifier == HarnessNotificationConstants.copyMessageActionIdentifier else { return }
        guard let message = userInfo["message"] as? String else {
            logger("BitChat harness service: notification copy action missing message content")
            return
        }
        if pasteboard.copyMessage(message) {
            logger("BitChat harness service: copied notification message to clipboard")
        } else {
            logger("BitChat harness service: failed to copy notification message to clipboard")
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handleResponse(
            actionIdentifier: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo
        )
        completionHandler()
    }
}

final class HarnessUserNotificationDirectMessageNotifier: HarnessDirectMessageNotifying {
    private let notificationCenter: HarnessNotificationCenterManaging
    private let notificationDelegate: HarnessNotificationDelegate

    init(
        notificationCenter: HarnessNotificationCenterManaging = HarnessNotificationCenterManager(),
        pasteboard: HarnessMessagePasteboarding = HarnessMessagePasteboard()
    ) {
        self.notificationCenter = notificationCenter
        self.notificationDelegate = HarnessNotificationDelegate(pasteboard: pasteboard)
    }

    func requestAuthorization() {
        let copyAction = UNNotificationAction(
            identifier: HarnessNotificationConstants.copyMessageActionIdentifier,
            title: "Copy Message",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: HarnessNotificationConstants.privateMessageCategoryIdentifier,
            actions: [copyAction],
            intentIdentifiers: [],
            options: []
        )
        notificationCenter.setNotificationCategories([category])
        notificationCenter.setDelegate(notificationDelegate)
        notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                HarnessServiceLog.write("BitChat harness service: notification authorization failed: \(error.localizedDescription)")
            } else if !granted {
                HarnessServiceLog.write("BitChat harness service: notification authorization denied")
            }
        }
    }

    func notifyPrivateMessage(from sender: String, message: String, peerID: PeerID) {
        NotificationService.shared.sendPrivateMessageNotification(from: sender, message: message, peerID: peerID)
    }
}

@MainActor
final class BitchatHarnessService {
    private let runtime: LiveHarnessRuntime
    private let listenerQueue = DispatchQueue(label: "chat.bitchat.harness.service")
    private var listener: NWListener?

    init() {
        runtime = LiveHarnessRuntime()
    }

    func start(port: UInt16) throws {
        let nwPort = NWEndpoint.Port(rawValue: port) ?? 0
        let listener = try NWListener(using: .tcp, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handle(connection)
            }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                HarnessServiceLog.write("BitChat harness service listener failed: \(error)")
            }
        }
        listener.start(queue: listenerQueue)
        self.listener = listener
        print("BitChat harness live service listening on 127.0.0.1:\(port)")
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: listenerQueue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { return }
            Task { @MainActor in
                let objects: [[String: Any]]
                if let error {
                    objects = [["type": "error", "message": error.localizedDescription]]
                } else if let data, let line = String(data: data, encoding: .utf8) {
                    objects = await self.dispatch(line)
                } else {
                    objects = [["type": "error", "message": "empty service request"]]
                }
                self.send(objects, over: connection)
            }
        }
    }

    private func dispatch(_ line: String) async -> [[String: Any]] {
        do {
            let request = try HarnessServiceRequest.decode(line)
            return try runtime.handle(request)
        } catch {
            return [["type": "error", "message": error.localizedDescription]]
        }
    }

    private func send(_ objects: [[String: Any]], over connection: NWConnection) {
        do {
            let response = try HarnessServiceResponse.encodeLines(objects)
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        } catch {
            let fallback = #"{"message":"failed to encode service response","type":"error"}"# + "\n"
            connection.send(content: fallback.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

@MainActor
final class LiveHarnessRuntime: NSObject, @MainActor BitchatDelegate, CommandContextProvider {
    private let keychain: KeychainManagerProtocol
    let idBridge: NostrIdentityBridge
    private let identityManager: SecureIdentityStateManager
    private let transport: BLEService
    private let recorder: LiveHarnessEventRecorder
    private let directMessageNotifier: HarnessDirectMessageNotifying
    private let nicknameKey = "bitchat.nickname"
    private var bluetoothState: CBManagerState = .unknown
    var nickname: String
    var selectedPrivateChatPeer: PeerID?
    var blockedUsers: Set<String> = []
    var privateChats: [PeerID: [BitchatMessage]] = [:]

    init(directMessageNotifier: HarnessDirectMessageNotifying = HarnessUserNotificationDirectMessageNotifier()) {
        keychain = HarnessFileKeychain()
        idBridge = NostrIdentityBridge(keychain: keychain)
        identityManager = SecureIdentityStateManager(keychain)
        transport = BLEService(keychain: keychain, idBridge: idBridge, identityManager: identityManager)
        self.directMessageNotifier = directMessageNotifier
        nickname = UserDefaults.standard.string(forKey: nicknameKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if nickname.isEmpty {
            nickname = "agent\(Int.random(in: 1000...9999))"
            UserDefaults.standard.set(nickname, forKey: nicknameKey)
        }
        recorder = LiveHarnessEventRecorder(myPeerID: transport.myPeerID, notifier: directMessageNotifier)
        super.init()

        transport.delegate = self
        transport.setNickname(nickname)
        directMessageNotifier.requestAuthorization()
        transport.startServices()
        HarnessServiceLog.write(
            "BitChat harness service: bluetooth service uuid \(BLEService.serviceUUID.uuidString) (\(Self.buildConfiguration))"
        )
    }

    func handle(_ request: HarnessServiceRequest) throws -> [[String: Any]] {
        switch request.command {
        case "status":
            return [statusObject()]
        case "peers":
            return peerObjects()
        case "chats":
            return chatObjects()
        case "send":
            return [try send(request)]
        case "command":
            return [try command(request)]
        case "nickname_get":
            return [["type": "status", "nickname": nickname, "backend_mode": "live"]]
        case "nickname_set":
            guard let value = request.string("nickname")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                throw HarnessServiceError.message("nickname cannot be empty")
            }
            nickname = value
            UserDefaults.standard.set(value, forKey: nicknameKey)
            transport.setNickname(value)
            return [["type": "status", "nickname": nickname, "backend_mode": "live"]]
        default:
            throw HarnessServiceError.message("unknown live service command: \(request.command)")
        }
    }

    private func statusObject() -> [String: Any] {
        [
            "type": "status",
            "backend_mode": "live",
            "active_channel": "mesh",
            "bluetooth_state": String(describing: bluetoothState),
            "bluetooth_service_uuid": BLEService.serviceUUID.uuidString,
            "build_configuration": Self.buildConfiguration,
            "connected_peer_count": transport.currentPeerSnapshots().filter(\.isConnected).count,
            "message_count": privateChats.values.reduce(0) { $0 + $1.count },
            "my_peer_id": transport.myPeerID.id,
            "nickname": nickname
        ]
    }

    private static var buildConfiguration: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    private func peerObjects() -> [[String: Any]] {
        transport.currentPeerSnapshots().map { peer in
            [
                "type": "peer",
                "id": peer.peerID.id,
                "nickname": peer.nickname,
                "transport": "mesh",
                "connected": peer.isConnected,
                "last_seen": isoDate(peer.lastSeen),
                "backend_mode": "live"
            ] as [String: Any]
        }
    }

    private func chatObjects() -> [[String: Any]] {
        var objects: [[String: Any]] = [
            ["type": "chat", "id": "mesh", "name": "#mesh", "service": "bitchat", "backend_mode": "live"]
        ]
        for (peerID, messages) in privateChats where !messages.isEmpty {
            objects.append([
                "type": "chat",
                "id": "dm:\(peerID.id)",
                "name": "@\(transport.peerNickname(peerID: peerID) ?? peerID.id)",
                "service": "bitchat",
                "backend_mode": "live"
            ])
        }
        return objects
    }

    private func send(_ request: HarnessServiceRequest) throws -> [String: Any] {
        guard let text = request.string("text")?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw HarnessServiceError.message("send requires text")
        }
        if let channel = request.string("channel") {
            try select(channel: channel)
        }
        if let recipient = request.string("to"), !recipient.isEmpty {
            guard let peerID = getPeerIDForNickname(recipient) else {
                throw HarnessServiceError.message("'\(recipient)' not found")
            }
            sendPrivateMessage(text, to: peerID)
            return messageObject(text: text, chatID: "dm:\(recipient)")
        }
        transport.sendMessage(text, mentions: mentions(in: text), messageID: UUID().uuidString, timestamp: Date())
        return messageObject(text: text, chatID: "mesh")
    }

    private func command(_ request: HarnessServiceRequest) throws -> [String: Any] {
        guard let command = request.string("command"), command.hasPrefix("/") else {
            throw HarnessServiceError.message("command must start with /")
        }
        let processor = CommandProcessor(contextProvider: self, meshService: transport, identityManager: identityManager)
        let result = processor.process(command)
        switch result {
        case .success(let message):
            return ["type": "event", "command": command, "text": message ?? "ok", "backend_mode": "live"]
        case .handled:
            return ["type": "event", "command": command, "text": "handled", "backend_mode": "live"]
        case .error(let message):
            return ["type": "error", "command": command, "message": message, "backend_mode": "live"]
        }
    }

    private func messageObject(text: String, chatID: String) -> [String: Any] {
        [
            "type": "message",
            "id": UUID().uuidString,
            "chat_id": chatID,
            "sender": nickname,
            "text": text,
            "created_at": isoDate(Date()),
            "delivery": "live-submitted",
            "backend_mode": "live"
        ]
    }

    private func select(channel: String) throws {
        if channel != "mesh" {
            throw HarnessServiceError.message("unsupported channel: \(channel)")
        }
    }

    private func isoDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func mentions(in text: String) -> [String] {
        text.split(separator: " ")
            .filter { $0.hasPrefix("@") && $0.count > 1 }
            .map { String($0.dropFirst()) }
    }

    func getPeerIDForNickname(_ nickname: String) -> PeerID? {
        let needle = nickname.lowercased()
        return transport.getPeerNicknames().first { _, value in
            value.lowercased() == needle
        }?.key
    }

    func getVisibleGeoParticipants() -> [CommandGeoParticipant] { [] }
    func nostrPubkeyForDisplayName(_ displayName: String) -> String? { nil }
    func startPrivateChat(with peerID: PeerID) { selectedPrivateChatPeer = peerID }

    func sendPrivateMessage(_ content: String, to peerID: PeerID) {
        let recipientNickname = transport.peerNickname(peerID: peerID) ?? "user"
        let messageID = UUID().uuidString
        transport.sendPrivateMessage(content, to: peerID, recipientNickname: recipientNickname, messageID: messageID)
        let message = BitchatMessage(
            id: messageID,
            sender: nickname,
            content: content,
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: recipientNickname,
            senderPeerID: transport.myPeerID
        )
        privateChats[peerID, default: []].append(message)
    }

    func clearCurrentPublicTimeline() {}
    func sendPublicRaw(_ content: String) {
        transport.sendMessage(content, mentions: [], messageID: UUID().uuidString, timestamp: Date())
    }
    func addLocalPrivateSystemMessage(_ content: String, to peerID: PeerID) {}
    func addPublicSystemMessage(_ content: String) {}
    func toggleFavorite(peerID: PeerID) {}
    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {}

    func didReceiveMessage(_ message: BitchatMessage) {
        if message.isPrivate, let peerID = message.senderPeerID {
            privateChats[peerID, default: []].append(message)
            recorder.recordIfInbound(message, chatID: "dm:\(peerID.id)", nickname: nickname)
        } else {
            recorder.recordIfInbound(message, chatID: "mesh", nickname: nickname)
        }
    }

    func didReceivePublicMessage(from peerID: PeerID, nickname: String, content: String, timestamp: Date, messageID: String?) {
        let message = BitchatMessage(
            id: messageID,
            sender: nickname,
            content: content,
            timestamp: timestamp,
            isRelay: false,
            senderPeerID: peerID
        )
        recorder.recordIfInbound(message, chatID: "mesh", nickname: self.nickname)
    }

    func didReceiveNoisePayload(from peerID: PeerID, type: NoisePayloadType, payload: Data, timestamp: Date) {
        switch type {
        case .privateMessage:
            guard let packet = PrivateMessagePacket.decode(from: payload) else { return }
            let message = BitchatMessage(
                id: packet.messageID,
                sender: transport.peerNickname(peerID: peerID) ?? "unknown",
                content: packet.content,
                timestamp: timestamp,
                isRelay: false,
                isPrivate: true,
                recipientNickname: nickname,
                senderPeerID: peerID
            )
            privateChats[peerID, default: []].append(message)
            recorder.recordIfInbound(message, chatID: "dm:\(peerID.id)", nickname: nickname)
            transport.sendDeliveryAck(for: packet.messageID, to: peerID)
        case .delivered, .readReceipt, .verifyChallenge, .verifyResponse:
            break
        }
    }

    func didConnectToPeer(_ peerID: PeerID) {}
    func didDisconnectFromPeer(_ peerID: PeerID) {}
    func didUpdatePeerList(_ peers: [PeerID]) {}
    func didUpdateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) {}
    func didUpdateBluetoothState(_ state: CBManagerState) {
        bluetoothState = state
        HarnessServiceLog.write("BitChat harness service: bluetooth state changed to \(state.rawValue)")
    }
    func isFavorite(fingerprint: String) -> Bool { false }
}

final class LiveHarnessEventRecorder {
    private let path: URL
    private let queue = DispatchQueue(label: "chat.bitchat.harness.event-recorder")
    private let myPeerID: PeerID
    private let notifier: HarnessDirectMessageNotifying?
    private var seenIDs: Set<String> = []

    init(myPeerID: PeerID, historyPath: URL? = nil, notifier: HarnessDirectMessageNotifying? = nil) {
        self.myPeerID = myPeerID
        self.notifier = notifier
        if let historyPath {
            path = historyPath
            try? FileManager.default.createDirectory(at: historyPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        } else {
            let base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".bitchat", isDirectory: true)
                .appendingPathComponent("agent-harness", isDirectory: true)
            path = base.appendingPathComponent("history.jsonl")
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
    }

    func recordIfInbound(_ message: BitchatMessage, chatID: String, nickname: String) {
        guard !seenIDs.contains(message.id) else { return }
        guard message.senderPeerID != myPeerID else { return }
        guard message.sender != nickname && !message.sender.hasPrefix("\(nickname)#") else { return }
        seenIDs.insert(message.id)
        if message.isPrivate, let peerID = message.senderPeerID {
            notifier?.notifyPrivateMessage(from: message.sender, message: message.content, peerID: peerID)
        }
        let object: [String: Any] = [
            "type": "message",
            "id": message.id,
            "chat_id": chatID,
            "sender": message.sender,
            "text": message.content,
            "created_at": ISO8601DateFormatter().string(from: message.timestamp),
            "delivery": message.deliveryStatus?.displayText ?? "received",
            "backend_mode": "live"
        ]
        queue.async { [path] in
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let line = String(data: data, encoding: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: path) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data((line + "\n").utf8))
                try? handle.close()
            } else {
                try? (line + "\n").write(to: path, atomically: true, encoding: .utf8)
            }
        }
    }
}

final class HarnessFileKeychain: KeychainManagerProtocol {
    private let path: URL
    private let queue = DispatchQueue(label: "chat.bitchat.harness.file-keychain")
    private var storage: [String: String]

    init() {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".bitchat", isDirectory: true)
            .appendingPathComponent("agent-harness", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        path = base.appendingPathComponent("keychain.json")
        if let data = try? Data(contentsOf: path),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            storage = decoded
        } else {
            storage = [:]
        }
    }

    func saveIdentityKey(_ keyData: Data, forKey key: String) -> Bool {
        saveValue(keyData, forStorageKey: "identity:\(key)")
    }

    func getIdentityKey(forKey key: String) -> Data? {
        loadValue(forStorageKey: "identity:\(key)")
    }

    func deleteIdentityKey(forKey key: String) -> Bool {
        queue.sync {
            storage.removeValue(forKey: "identity:\(key)")
            persist()
        }
        return true
    }

    func deleteAllKeychainData() -> Bool {
        queue.sync {
            storage.removeAll()
            persist()
        }
        return true
    }

    func secureClear(_ data: inout Data) {
        data.resetBytes(in: 0..<data.count)
    }

    func secureClear(_ string: inout String) {
        string = ""
    }

    func verifyIdentityKeyExists() -> Bool {
        getIdentityKey(forKey: "identity_noiseStaticKey") != nil
    }

    func getIdentityKeyWithResult(forKey key: String) -> KeychainReadResult {
        if let data = getIdentityKey(forKey: key) {
            return .success(data)
        }
        return .itemNotFound
    }

    func saveIdentityKeyWithResult(_ keyData: Data, forKey key: String) -> KeychainSaveResult {
        saveIdentityKey(keyData, forKey: key) ? .success : .otherError(-1)
    }

    func save(key: String, data: Data, service: String, accessible: CFString?) {
        _ = saveValue(data, forStorageKey: "service:\(service):\(key)")
    }

    func load(key: String, service: String) -> Data? {
        loadValue(forStorageKey: "service:\(service):\(key)")
    }

    func delete(key: String, service: String) {
        queue.sync {
            storage.removeValue(forKey: "service:\(service):\(key)")
            persist()
        }
    }

    private func saveValue(_ data: Data, forStorageKey key: String) -> Bool {
        queue.sync {
            storage[key] = data.base64EncodedString()
            persist()
        }
        return true
    }

    private func loadValue(forStorageKey key: String) -> Data? {
        queue.sync {
            guard let value = storage[key] else { return nil }
            return Data(base64Encoded: value)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        try? data.write(to: path, options: [.atomic])
    }
}
#endif

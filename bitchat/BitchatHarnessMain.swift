#if os(macOS)
import BitFoundation
import Combine
import Foundation

enum BitchatHarnessMain {
    @MainActor
    static func run(arguments: [String]) async -> Int {
        do {
            guard let command = arguments.first else {
                try emit(["type": "error", "message": "missing harness command"])
                return 2
            }
            let rest = Array(arguments.dropFirst())
            switch command {
            case "status":
                try emit(statusObject(makeRuntime()))
            case "peers":
                try emitMany(peerObjects(makeRuntime()))
            case "chats":
                try emitMany(chatObjects())
            case "send":
                try emit(send(arguments: rest))
            case "command":
                try emit(commandResult(arguments: rest))
            case "nickname":
                try emit(nickname(arguments: rest))
            case "service":
                return await service(arguments: rest)
            default:
                try emit(["type": "error", "message": "unknown harness command: \(command)"])
                return 2
            }
            return 0
        } catch {
            emitError(error.localizedDescription)
            return 1
        }
    }

    static func emitError(_ message: String) {
        try? emit(["type": "error", "message": message])
    }

    @MainActor
    private static func makeRuntime() -> HarnessRuntime {
        let idBridge = NostrIdentityBridge()
        let identityManager = HarnessIdentityManager()
        let transport = HarnessTransport(nickname: currentNickname())
        transport.setNickname(currentNickname())
        return HarnessRuntime(
            transport: transport,
            identityManager: identityManager,
            context: HarnessCommandContext(nickname: currentNickname(), idBridge: idBridge)
        )
    }

    @MainActor
    private static func statusObject(_ runtime: HarnessRuntime) -> [String: Any] {
        [
            "type": "status",
            "nickname": currentNickname(),
            "my_peer_id": runtime.transport.myPeerID.id,
            "active_channel": currentChannelID(),
            "connected_peer_count": runtime.transport.currentPeerSnapshots().count,
            "message_count": 0,
            "backend_mode": "harness"
        ]
    }

    @MainActor
    private static func peerObjects(_ runtime: HarnessRuntime) -> [[String: Any]] {
        runtime.transport.currentPeerSnapshots().map { peer in
            [
                "type": "peer",
                "id": peer.peerID.id,
                "nickname": peer.nickname,
                "transport": "mesh",
                "connected": peer.isConnected,
                "last_seen": isoDate(peer.lastSeen)
            ] as [String: Any]
        }
    }

    private static func chatObjects() -> [[String: Any]] {
        var objects: [[String: Any]] = [
            [
                "type": "chat",
                "id": "mesh",
                "name": "#mesh",
                "service": "bitchat"
            ]
        ]
        if case .location(let channel) = LocationChannelManager.shared.selectedChannel {
            objects.append([
                "type": "chat",
                "id": "geo:\(channel.geohash)",
                "name": "#\(channel.geohash)",
                "service": "bitchat"
            ])
        }
        return objects
    }

    @MainActor
    private static func send(arguments: [String]) throws -> [String: Any] {
        let parsed = ParsedArguments(arguments)
        guard let text = parsed.value(after: "--text"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HarnessError.message("send requires --text")
        }

        let runtime = makeRuntime()
        if let channel = parsed.value(after: "--channel") {
            try select(channel: channel)
        }

        if let recipient = parsed.value(after: "--to") {
            let command = "/msg @\(recipient) \(text)"
            let processor = CommandProcessor(
                contextProvider: runtime.context,
                meshService: runtime.transport,
                identityManager: runtime.identityManager
            )
            let result = processor.process(command)
            switch result {
            case .success(let message):
                return [
                    "type": "message",
                    "id": UUID().uuidString,
                    "chat_id": "dm:\(recipient)",
                    "sender": currentNickname(),
                    "text": text,
                    "created_at": isoDate(Date()),
                    "delivery": "harness-observed",
                    "backend_result": message ?? "sent"
                ]
            case .handled:
                return [
                    "type": "message",
                    "id": UUID().uuidString,
                    "chat_id": "dm:\(recipient)",
                    "sender": currentNickname(),
                    "text": text,
                    "created_at": isoDate(Date()),
                    "delivery": "harness-observed"
                ]
            case .error(let message):
                throw HarnessError.message(message)
            }
        }

        let messageID = UUID().uuidString
        runtime.transport.startServices()
        runtime.transport.sendMessage(text, mentions: mentions(in: text), messageID: messageID, timestamp: Date())
        return [
            "type": "message",
            "id": messageID,
            "chat_id": currentChannelID(),
            "sender": currentNickname(),
            "text": text,
            "created_at": isoDate(Date()),
            "delivery": "harness-observed"
        ]
    }

    @MainActor
    private static func commandResult(arguments: [String]) throws -> [String: Any] {
        let command = arguments.joined(separator: " ")
        guard command.hasPrefix("/") else {
            throw HarnessError.message("command must start with /")
        }
        let runtime = makeRuntime()
        let processor = CommandProcessor(
            contextProvider: runtime.context,
            meshService: runtime.transport,
            identityManager: runtime.identityManager
        )
        let result = processor.process(command)
        switch result {
        case .success(let message):
            return ["type": "event", "command": command, "text": message ?? "ok"]
        case .handled:
            return ["type": "event", "command": command, "text": "handled"]
        case .error(let message):
            return ["type": "error", "command": command, "message": message]
        }
    }

    private static func nickname(arguments: [String]) throws -> [String: Any] {
        guard let action = arguments.first else {
            throw HarnessError.message("nickname requires get or set")
        }
        switch action {
        case "get":
            return ["type": "status", "nickname": currentNickname()]
        case "set":
            guard arguments.count > 1 else {
                throw HarnessError.message("nickname set requires a value")
            }
            let value = arguments.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw HarnessError.message("nickname cannot be empty")
            }
            UserDefaults.standard.set(value, forKey: nicknameKey)
            return ["type": "status", "nickname": value]
        default:
            throw HarnessError.message("unknown nickname action: \(action)")
        }
    }

    @MainActor
    private static func service(arguments: [String]) async -> Int {
        guard arguments.first == "run" else {
            emitError("service requires run")
            return 2
        }
        let parsed = ParsedArguments(Array(arguments.dropFirst()))
        let port = UInt16(parsed.value(after: "--port") ?? "") ?? 0
        HarnessServiceLog.configure(path: parsed.value(after: "--log-file"))
        guard port > 0 else {
            emitError("service run requires --port")
            return 2
        }
        do {
            HarnessServiceLog.write("BitChat harness service: initializing runtime")
            let service = BitchatHarnessService()
            HarnessServiceLog.write("BitChat harness service: starting listener")
            try service.start(port: port)
            HarnessServiceLog.write("BitChat harness service: ready")
            dispatchMain()
        } catch {
            HarnessServiceLog.write("BitChat harness service: failed: \(error.localizedDescription)")
            emitError(error.localizedDescription)
            return 1
        }
    }

    @MainActor
    private static func select(channel: String) throws {
        if channel == "mesh" {
            LocationChannelManager.shared.select(.mesh)
            return
        }
        guard channel.hasPrefix("geo:") else {
            throw HarnessError.message("unsupported channel: \(channel)")
        }
        let geohash = String(channel.dropFirst("geo:".count)).lowercased()
        guard !geohash.isEmpty else {
            throw HarnessError.message("geo channel requires a geohash")
        }
        let geohashChannel = GeohashChannel(level: level(forGeohash: geohash), geohash: geohash)
        let channelID = ChannelID.location(geohashChannel)
        LocationChannelManager.shared.select(channelID)
    }

    private static func level(forGeohash geohash: String) -> GeohashChannelLevel {
        switch geohash.count {
        case 8...: return .building
        case 7: return .block
        case 6: return .neighborhood
        case 5: return .city
        case 4: return .province
        default: return .region
        }
    }

    private static func emitMany(_ objects: [[String: Any]]) throws {
        for object in objects {
            try emit(object)
        }
    }

    private static func emit(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let line = String(data: data, encoding: .utf8) else {
            throw HarnessError.message("failed to encode JSON")
        }
        print(line)
    }

    private static func isoDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static let nicknameKey = "bitchat.nickname"

    private static func currentNickname() -> String {
        if let value = UserDefaults.standard.string(forKey: nicknameKey),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        let generated = "anon\(Int.random(in: 1000...9999))"
        UserDefaults.standard.set(generated, forKey: nicknameKey)
        return generated
    }

    private static func currentChannelID() -> String {
        switch LocationChannelManager.shared.selectedChannel {
        case .mesh:
            return "mesh"
        case .location(let channel):
            return "geo:\(channel.geohash)"
        }
    }

    private static func mentions(in text: String) -> [String] {
        text.split(separator: " ")
            .filter { $0.hasPrefix("@") && $0.count > 1 }
            .map { String($0.dropFirst()) }
    }

    private enum HarnessError: LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case .message(let message):
                return message
            }
        }
    }

    private struct ParsedArguments {
        let arguments: [String]

        init(_ arguments: [String]) {
            self.arguments = arguments
        }

        func value(after option: String) -> String? {
            guard let index = arguments.firstIndex(of: option) else { return nil }
            let valueIndex = arguments.index(after: index)
            guard valueIndex < arguments.endIndex else { return nil }
            return arguments[valueIndex]
        }
    }

    private struct HarnessRuntime {
        let transport: Transport
        let identityManager: SecureIdentityStateManagerProtocol
        let context: HarnessCommandContext
    }

    private final class HarnessTransport: Transport {
        weak var delegate: BitchatDelegate?
        weak var peerEventsDelegate: TransportPeerEventsDelegate?
        var peerSnapshotPublisher: AnyPublisher<[TransportPeerSnapshot], Never> {
            Just([]).eraseToAnyPublisher()
        }
        private(set) var myPeerID: PeerID
        private(set) var myNickname: String
        private var sentMessages: [(content: String, mentions: [String], id: String, timestamp: Date)] = []

        init(nickname: String) {
            self.myPeerID = PeerID(str: UserDefaults.standard.string(forKey: "bitchat.harness.peerID") ?? "")
            if self.myPeerID.id.isEmpty {
                let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
                let value = String(generated)
                UserDefaults.standard.set(value, forKey: "bitchat.harness.peerID")
                self.myPeerID = PeerID(str: value)
            }
            self.myNickname = nickname
        }

        func currentPeerSnapshots() -> [TransportPeerSnapshot] { [] }
        func setNickname(_ nickname: String) { myNickname = nickname }
        func startServices() {}
        func stopServices() {}
        func emergencyDisconnectAll() {}
        func isPeerConnected(_ peerID: PeerID) -> Bool { false }
        func isPeerReachable(_ peerID: PeerID) -> Bool { false }
        func peerNickname(peerID: PeerID) -> String? { nil }
        func getPeerNicknames() -> [PeerID: String] { [:] }
        func getFingerprint(for peerID: PeerID) -> String? { nil }
        func getNoiseSessionState(for peerID: PeerID) -> LazyHandshakeState { .none }
        func triggerHandshake(with peerID: PeerID) {}
        func getNoiseService() -> NoiseEncryptionService { NoiseEncryptionService(keychain: KeychainManager()) }
        func sendMessage(_ content: String, mentions: [String]) {
            sentMessages.append((content, mentions, UUID().uuidString, Date()))
        }
        func sendMessage(_ content: String, mentions: [String], messageID: String, timestamp: Date) {
            sentMessages.append((content, mentions, messageID, timestamp))
        }
        func sendPrivateMessage(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String) {}
        func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {}
        func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {}
        func sendBroadcastAnnounce() {}
        func sendDeliveryAck(for messageID: String, to peerID: PeerID) {}
    }

    private final class HarnessIdentityManager: SecureIdentityStateManagerProtocol {
        private var favorites: Set<String> = []
        private var blocked: Set<String> = []
        private var nostrBlocked: Set<String> = []
        private var verified: Set<String> = []
        private var socialIdentities: [String: SocialIdentity] = [:]

        func forceSave() {}
        func getSocialIdentity(for fingerprint: String) -> SocialIdentity? { socialIdentities[fingerprint] }
        func upsertCryptographicIdentity(fingerprint: String, noisePublicKey: Data, signingPublicKey: Data?, claimedNickname: String?) {}
        func getCryptoIdentitiesByPeerIDPrefix(_ peerID: PeerID) -> [CryptographicIdentity] { [] }
        func updateSocialIdentity(_ identity: SocialIdentity) { socialIdentities[identity.fingerprint] = identity }
        func getFavorites() -> Set<String> { favorites }
        func setFavorite(_ fingerprint: String, isFavorite: Bool) {
            if isFavorite { favorites.insert(fingerprint) } else { favorites.remove(fingerprint) }
        }
        func isFavorite(fingerprint: String) -> Bool { favorites.contains(fingerprint) }
        func isBlocked(fingerprint: String) -> Bool { blocked.contains(fingerprint) }
        func setBlocked(_ fingerprint: String, isBlocked: Bool) {
            if isBlocked { blocked.insert(fingerprint) } else { blocked.remove(fingerprint) }
        }
        func isNostrBlocked(pubkeyHexLowercased: String) -> Bool { nostrBlocked.contains(pubkeyHexLowercased) }
        func setNostrBlocked(_ pubkeyHexLowercased: String, isBlocked: Bool) {
            if isBlocked { nostrBlocked.insert(pubkeyHexLowercased) } else { nostrBlocked.remove(pubkeyHexLowercased) }
        }
        func getBlockedNostrPubkeys() -> Set<String> { nostrBlocked }
        func registerEphemeralSession(peerID: PeerID, handshakeState: HandshakeState) {}
        func updateHandshakeState(peerID: PeerID, state: HandshakeState) {}
        func clearAllIdentityData() {
            favorites.removeAll()
            blocked.removeAll()
            nostrBlocked.removeAll()
            verified.removeAll()
            socialIdentities.removeAll()
        }
        func removeEphemeralSession(peerID: PeerID) {}
        func setVerified(fingerprint: String, verified isVerified: Bool) {
            if isVerified { verified.insert(fingerprint) } else { verified.remove(fingerprint) }
        }
        func isVerified(fingerprint: String) -> Bool { verified.contains(fingerprint) }
        func getVerifiedFingerprints() -> Set<String> { verified }
    }

    @MainActor
    private final class HarnessCommandContext: CommandContextProvider {
        var nickname: String
        var selectedPrivateChatPeer: PeerID?
        var blockedUsers: Set<String> = []
        var privateChats: [PeerID: [BitchatMessage]] = [:]
        let idBridge: NostrIdentityBridge
        var sentPrivateMessages: [(String, PeerID)] = []
        var publicMessages: [String] = []

        init(nickname: String, idBridge: NostrIdentityBridge) {
            self.nickname = nickname
            self.idBridge = idBridge
        }

        func getPeerIDForNickname(_ nickname: String) -> PeerID? { nil }
        func getVisibleGeoParticipants() -> [CommandGeoParticipant] { [] }
        func nostrPubkeyForDisplayName(_ displayName: String) -> String? { nil }
        func startPrivateChat(with peerID: PeerID) { selectedPrivateChatPeer = peerID }
        func sendPrivateMessage(_ content: String, to peerID: PeerID) {
            sentPrivateMessages.append((content, peerID))
        }
        func clearCurrentPublicTimeline() { publicMessages.removeAll() }
        func sendPublicRaw(_ content: String) { publicMessages.append(content) }
        func addLocalPrivateSystemMessage(_ content: String, to peerID: PeerID) {
            privateChats[peerID, default: []].append(
                BitchatMessage(sender: "system", content: content, timestamp: Date(), isRelay: false, isPrivate: true)
            )
        }
        func addPublicSystemMessage(_ content: String) { publicMessages.append(content) }
        func toggleFavorite(peerID: PeerID) {}
        func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {}
    }
}
#endif

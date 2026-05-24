//
// NostrTransportTests.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
import BitFoundation
@testable import bitchat

@Suite("NostrTransport Tests")
struct NostrTransportTests {
    typealias FavoriteRelationship = FavoritesPersistenceService.FavoriteRelationship

    @Test("Warm cache marks full and short IDs reachable")
    @MainActor
    func reachabilityCacheWarmsFromFavorites() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let ndrService = try makeNdrService(label: "reachability-cache")
        let recipient = try NostrIdentity.generate()
        let noiseKey = Data((0..<32).map(UInt8.init))
        let fullPeerID = PeerID(hexData: noiseKey)
        let shortPeerID = fullPeerID.toShort()
        let relationship = makeRelationship(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: recipient.npub,
            peerNickname: "Alice"
        )
        let favorites = [noiseKey: relationship]

        let transport = NostrTransport(
            keychain: keychain,
            idBridge: idBridge,
            ndrService: ndrService,
            dependencies: makeDependencies(
                loadFavorites: { favorites },
                favoriteStatusForNoiseKey: { favorites[$0] },
                favoriteStatusForPeerID: { $0 == shortPeerID ? relationship : nil },
                currentIdentity: { nil }
            )
        )

        #expect(!transport.isPeerReachable(fullPeerID))
        #expect(transport.isPeerReachable(shortPeerID))
        #expect(!transport.isPeerReachable(PeerID(str: "feedfeedfeedfeed")))
    }

    @Test("Favorite status notification refreshes reachability cache")
    @MainActor
    func favoriteStatusNotificationRefreshesReachability() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let ndrService = try makeNdrService(label: "favorite-refresh")
        let recipient = try NostrIdentity.generate()
        let noiseKey = Data((32..<64).map(UInt8.init))
        let peerID = PeerID(hexData: noiseKey).toShort()
        let notificationCenter = NotificationCenter()
        var favorites: [Data: FavoriteRelationship] = [:]

        let transport = NostrTransport(
            keychain: keychain,
            idBridge: idBridge,
            ndrService: ndrService,
            dependencies: makeDependencies(
                notificationCenter: notificationCenter,
                loadFavorites: { favorites },
                favoriteStatusForNoiseKey: { favorites[$0] },
                favoriteStatusForPeerID: { _ in favorites.values.first },
                currentIdentity: { nil }
            )
        )

        #expect(!transport.isPeerReachable(peerID))

        favorites[noiseKey] = makeRelationship(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: recipient.npub,
            peerNickname: "Bob"
        )
        notificationCenter.post(name: .favoriteStatusChanged, object: nil)

        let didRefresh = await TestHelpers.waitUntil({ transport.isPeerReachable(peerID) }, timeout: 0.5)
        #expect(didRefresh)
    }

    @Test("Private message resolves short peer ID and emits decryptable packet")
    @MainActor
    func sendPrivateMessageResolvesShortPeerID() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let ndrService = try makeNdrService(label: "private-message")
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let noiseKey = Data((64..<96).map(UInt8.init))
        let shortPeerID = PeerID(hexData: noiseKey).toShort()
        let relationship = makeRelationship(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: recipient.npub,
            peerNickname: "Carol"
        )
        let probe = NostrTransportProbe()
        let transport = NostrTransport(
            keychain: keychain,
            idBridge: idBridge,
            ndrService: ndrService,
            dependencies: makeDependencies(
                favoriteStatusForNoiseKey: { _ in nil },
                favoriteStatusForPeerID: { $0 == shortPeerID ? relationship : nil },
                currentIdentity: { sender },
                registerPendingGiftWrap: probe.recordPendingGiftWrap(id:),
                sendEvent: probe.record(event:),
                scheduleAfter: { delay, action in
                    probe.enqueueScheduledAction(delay: delay, action: action)
                }
            )
        )
        transport.senderPeerID = PeerID(str: "0123456789abcdef")

        transport.sendPrivateMessage("hello over nostr", to: shortPeerID, recipientNickname: "Carol", messageID: "pm-1")

        let didSend = await TestHelpers.waitUntil({ probe.sentEvents.count == 1 }, timeout: 0.5)
        #expect(didSend)
        let result = try decodeEmbeddedPayload(from: probe.sentEvents[0], recipient: recipient)
        let privateMessage = try decodePrivateMessage(from: result.payload)

        #expect(result.senderPubkey == sender.publicKeyHex)
        #expect(privateMessage.messageID == "pm-1")
        #expect(privateMessage.content == "hello over nostr")
        #expect(result.packet.recipientID == shortPeerID.routingData)
        #expect(probe.pendingGiftWrapIDs.isEmpty)
    }

    @Test("Private message prefers NDR when a session already exists")
    @MainActor
    func sendPrivateMessagePrefersNdrWhenSessionExists() throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let senderRelay = FakeRelayManager()
        let recipientRelay = FakeRelayManager()
        let senderStorage = try makeTempDir(label: "transport-ndr-sender")
        let recipientStorage = try makeTempDir(label: "transport-ndr-recipient")
        let senderNdr = NdrNostrService(
            relayManager: senderRelay,
            deviceId: "transport-ndr-sender",
            storageDirectoryProvider: { senderStorage }
        )
        let recipientNdr = NdrNostrService(
            relayManager: recipientRelay,
            deviceId: "transport-ndr-recipient",
            storageDirectoryProvider: { recipientStorage }
        )
        senderNdr.configureIfNeeded(identity: sender)
        recipientNdr.configureIfNeeded(identity: recipient)
        try establishMutualSession(senderNdr, recipientNdr, senderIdentity: sender, recipientIdentity: recipient)

        let noiseKey = Data((64..<96).map(UInt8.init))
        let fullPeerID = PeerID(hexData: noiseKey)
        let relationship = makeRelationship(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: recipient.npub,
            peerNickname: "Carol"
        )
        let transport = NostrTransport(
            keychain: keychain,
            idBridge: idBridge,
            ndrService: senderNdr,
            dependencies: makeDependencies(
                favoriteStatusForNoiseKey: { $0 == noiseKey ? relationship : nil },
                favoriteStatusForPeerID: { _ in nil },
                currentIdentity: { sender }
            )
        )
        transport.senderPeerID = PeerID(str: "0123456789abcdef")

        let transportUsed = try transport.sendPrivateMessageAndReturnTransport(
            "hello via ndr",
            to: fullPeerID,
            recipientNickname: "Carol",
            messageID: "pm-ndr"
        )

        #expect(transportUsed == .ndr)
        #expect(senderRelay.sentEvents.contains(where: { $0.kind == 1060 }))
    }

    @Test("Private message stays on NDR when an active session queues before relay publish")
    @MainActor
    func sendPrivateMessageDoesNotFallBackWhenNdrQueues() throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let senderRelay = FakeRelayManager()
        let recipientRelay = FakeRelayManager()
        let senderStorage = try makeTempDir(label: "transport-ndr-queued-sender")
        let recipientStorage = try makeTempDir(label: "transport-ndr-queued-recipient")
        let senderNdr = NdrNostrService(
            relayManager: senderRelay,
            deviceId: "transport-ndr-queued-sender",
            storageDirectoryProvider: { senderStorage }
        )
        let recipientNdr = NdrNostrService(
            relayManager: recipientRelay,
            deviceId: "transport-ndr-queued-recipient",
            storageDirectoryProvider: { recipientStorage }
        )
        senderNdr.configureIfNeeded(identity: sender)
        recipientNdr.configureIfNeeded(identity: recipient)

        let senderInvite = try #require(senderNdr.currentInviteEventJson())
        let recipientPublishes = recipientNdr.processOutOfBandEventJson(senderInvite)
        let recipientResponse = try #require(
            recipientPublishes.first(where: { (try? extractNostrKind(json: $0)) == 1059 }),
            "Recipient should return a response after processing sender invite"
        )
        let recipientBootstrap = try #require(
            recipientRelay.sentEvents.first(where: { $0.kind == 1060 }),
            "Recipient should publish a bootstrap message event after accepting sender invite"
        )
        _ = senderNdr.processOutOfBandEventJson(recipientResponse)
        #expect(senderNdr.hasActiveSession(with: recipient.publicKeyHex))

        senderRelay.resetSentEvents()
        let probe = NostrTransportProbe()
        let noiseKey = Data((80..<112).map(UInt8.init))
        let fullPeerID = PeerID(hexData: noiseKey)
        let relationship = makeRelationship(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: recipient.npub,
            peerNickname: "Queued"
        )
        let transport = NostrTransport(
            keychain: keychain,
            idBridge: idBridge,
            ndrService: senderNdr,
            dependencies: makeDependencies(
                favoriteStatusForNoiseKey: { $0 == noiseKey ? relationship : nil },
                favoriteStatusForPeerID: { _ in nil },
                currentIdentity: { sender },
                sendEvent: probe.record(event:)
            )
        )
        transport.senderPeerID = PeerID(str: "0123456789abcdef")

        let transportUsed = try transport.sendPrivateMessageAndReturnTransport(
            "queued via ndr",
            to: fullPeerID,
            recipientNickname: "Queued",
            messageID: "pm-ndr-queued"
        )

        #expect(transportUsed == .ndr)
        #expect(probe.sentEvents.isEmpty)
        #expect(senderRelay.sentEvents.filter { $0.kind == 1060 }.isEmpty)

        senderNdr.processInboundRelayEvent(recipientBootstrap)
        #expect(senderRelay.sentEvents.contains(where: { $0.kind == 1060 }))
    }

    @Test("Favorite notification embeds current npub")
    @MainActor
    func sendFavoriteNotificationEmbedsCurrentIdentity() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let ndrService = try makeNdrService(label: "favorite-notification")
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let noiseKey = Data((96..<128).map(UInt8.init))
        let fullPeerID = PeerID(hexData: noiseKey)
        let relationship = makeRelationship(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: recipient.npub,
            peerNickname: "Dan"
        )
        let probe = NostrTransportProbe()
        let transport = NostrTransport(
            keychain: keychain,
            idBridge: idBridge,
            ndrService: ndrService,
            dependencies: makeDependencies(
                favoriteStatusForNoiseKey: { $0 == noiseKey ? relationship : nil },
                favoriteStatusForPeerID: { _ in nil },
                currentIdentity: { sender },
                registerPendingGiftWrap: probe.recordPendingGiftWrap(id:),
                sendEvent: probe.record(event:),
                scheduleAfter: { delay, action in
                    probe.enqueueScheduledAction(delay: delay, action: action)
                }
            )
        )
        transport.senderPeerID = PeerID(str: "0123456789abcdef")

        transport.sendFavoriteNotification(to: fullPeerID, isFavorite: true)

        let didSend = await TestHelpers.waitUntil({ probe.sentEvents.count == 1 }, timeout: 0.5)
        #expect(didSend)
        let result = try decodeEmbeddedPayload(from: probe.sentEvents[0], recipient: recipient)
        let privateMessage = try decodePrivateMessage(from: result.payload)

        #expect(privateMessage.content == "[FAVORITED]:\(sender.npub)")
    }

    @Test("Delivery ACK encodes delivered payload type")
    @MainActor
    func sendDeliveryAckEmitsDeliveredAck() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let ndrService = try makeNdrService(label: "delivery-ack")
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let noiseKey = Data((128..<160).map(UInt8.init))
        let fullPeerID = PeerID(hexData: noiseKey)
        let relationship = makeRelationship(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: recipient.npub,
            peerNickname: "Eve"
        )
        let probe = NostrTransportProbe()
        let transport = NostrTransport(
            keychain: keychain,
            idBridge: idBridge,
            ndrService: ndrService,
            dependencies: makeDependencies(
                favoriteStatusForNoiseKey: { $0 == noiseKey ? relationship : nil },
                favoriteStatusForPeerID: { _ in nil },
                currentIdentity: { sender },
                registerPendingGiftWrap: probe.recordPendingGiftWrap(id:),
                sendEvent: probe.record(event:),
                scheduleAfter: { delay, action in
                    probe.enqueueScheduledAction(delay: delay, action: action)
                }
            )
        )
        transport.senderPeerID = PeerID(str: "0123456789abcdef")

        transport.sendDeliveryAck(for: "ack-1", to: fullPeerID)

        let didSend = await TestHelpers.waitUntil({ probe.sentEvents.count == 1 }, timeout: 0.5)
        #expect(didSend)
        let result = try decodeEmbeddedPayload(from: probe.sentEvents[0], recipient: recipient)

        #expect(result.payload.type == .delivered)
        #expect(String(data: result.payload.data, encoding: .utf8) == "ack-1")
        #expect(result.packet.recipientID == fullPeerID.toShort().routingData)
    }

    @Test("Geohash private message registers pending gift wrap")
    @MainActor
    func sendPrivateMessageGeohashRegistersPendingGiftWrap() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let ndrService = try makeNdrService(label: "geohash-pm")
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let probe = NostrTransportProbe()
        let transport = NostrTransport(
            keychain: keychain,
            idBridge: idBridge,
            ndrService: ndrService,
            dependencies: makeDependencies(
                currentIdentity: { sender },
                registerPendingGiftWrap: probe.recordPendingGiftWrap(id:),
                sendEvent: probe.record(event:),
                scheduleAfter: { delay, action in
                    probe.enqueueScheduledAction(delay: delay, action: action)
                }
            )
        )
        transport.senderPeerID = PeerID(str: "0123456789abcdef")

        transport.sendPrivateMessageGeohash(
            content: "geo hello",
            toRecipientHex: recipient.publicKeyHex,
            from: sender,
            messageID: "geo-1"
        )

        let didSend = await TestHelpers.waitUntil({ probe.sentEvents.count == 1 }, timeout: 0.5)
        #expect(didSend)
        let event = probe.sentEvents[0]
        let result = try decodeEmbeddedPayload(from: event, recipient: recipient)
        let privateMessage = try decodePrivateMessage(from: result.payload)

        #expect(privateMessage.messageID == "geo-1")
        #expect(privateMessage.content == "geo hello")
        #expect(result.packet.recipientID == nil)
        #expect(probe.pendingGiftWrapIDs == [event.id])
    }

    @Test("Read receipt queue sends in order and waits for scheduler")
    @MainActor
    func readReceiptQueueThrottlesSequentially() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let ndrService = try makeNdrService(label: "read-queue")
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let noiseKey = Data((160..<192).map(UInt8.init))
        let fullPeerID = PeerID(hexData: noiseKey)
        let relationship = makeRelationship(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: recipient.npub,
            peerNickname: "Frank"
        )
        let probe = NostrTransportProbe()
        let transport = NostrTransport(
            keychain: keychain,
            idBridge: idBridge,
            ndrService: ndrService,
            dependencies: makeDependencies(
                favoriteStatusForNoiseKey: { $0 == noiseKey ? relationship : nil },
                favoriteStatusForPeerID: { _ in nil },
                currentIdentity: { sender },
                registerPendingGiftWrap: probe.recordPendingGiftWrap(id:),
                sendEvent: probe.record(event:),
                scheduleAfter: { delay, action in
                    probe.enqueueScheduledAction(delay: delay, action: action)
                }
            )
        )
        transport.senderPeerID = PeerID(str: "0123456789abcdef")

        let first = ReadReceipt(originalMessageID: "read-1", readerID: transport.myPeerID, readerNickname: "Me")
        let second = ReadReceipt(originalMessageID: "read-2", readerID: transport.myPeerID, readerNickname: "Me")

        transport.sendReadReceipt(first, to: fullPeerID)
        transport.sendReadReceipt(second, to: fullPeerID)

        let sentFirst = await TestHelpers.waitUntil({ probe.sentEvents.count == 1 }, timeout: 1.5)
        try #require(sentFirst, "Expected first queued read receipt event")
        let scheduledThrottle = await TestHelpers.waitUntil({ probe.scheduledActionCount == 1 }, timeout: 1.5)
        try #require(scheduledThrottle, "Expected queued throttle action after first read receipt")
        let firstEvent = try #require(probe.sentEvents.first, "Expected first queued read receipt event")
        let firstPayload = try decodeEmbeddedPayload(from: firstEvent, recipient: recipient).payload
        #expect(firstPayload.type == .readReceipt)
        #expect(String(data: firstPayload.data, encoding: .utf8) == "read-1")

        try #require(probe.runNextScheduledAction(), "Expected queued throttle action after first read receipt")

        let sentSecond = await TestHelpers.waitUntil({ probe.sentEvents.count == 2 }, timeout: 1.5)
        try #require(sentSecond, "Expected second read receipt after running throttle action")
        let secondEvent = try #require(probe.sentEvents.last, "Expected second queued read receipt event")
        let secondPayload = try decodeEmbeddedPayload(from: secondEvent, recipient: recipient).payload
        #expect(secondPayload.type == .readReceipt)
        #expect(String(data: secondPayload.data, encoding: .utf8) == "read-2")
    }

    @Test("Concurrent read receipt enqueue does not crash")
    @MainActor
    func concurrentReadReceiptEnqueue() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let ndrService = try makeNdrService(label: "concurrent-read")
        let transport = NostrTransport(keychain: keychain, idBridge: idBridge, ndrService: ndrService)
        let iterations = 100

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    let receipt = ReadReceipt(
                        originalMessageID: UUID().uuidString,
                        readerID: PeerID(str: String(format: "%016x", i)),
                        readerNickname: "Reader\(i)"
                    )
                    let peerID = PeerID(str: String(format: "%016x", i))
                    transport.sendReadReceipt(receipt, to: peerID)
                }
            }
        }
    }

    @Test("isPeerReachable is thread safe")
    @MainActor
    func isPeerReachableThreadSafety() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let ndrService = try makeNdrService(label: "reachable-thread-safety")
        let transport = NostrTransport(keychain: keychain, idBridge: idBridge, ndrService: ndrService)
        let iterations = 100

        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    let peerID = PeerID(str: String(format: "%016x", i))
                    return transport.isPeerReachable(peerID)
                }
            }

            for await result in group {
                #expect(result == false)
            }
        }
    }

    @MainActor
    private func makeDependencies(
        notificationCenter: NotificationCenter = NotificationCenter(),
        loadFavorites: @escaping @MainActor () -> [Data: FavoriteRelationship] = { [:] },
        favoriteStatusForNoiseKey: @escaping @MainActor (Data) -> FavoriteRelationship? = { _ in nil },
        favoriteStatusForPeerID: @escaping @MainActor (PeerID) -> FavoriteRelationship? = { _ in nil },
        currentIdentity: @escaping @MainActor () throws -> NostrIdentity? = { nil },
        registerPendingGiftWrap: @escaping @MainActor (String) -> Void = { _ in },
        sendEvent: @escaping @MainActor (NostrEvent) -> Void = { _ in },
        scheduleAfter: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void = { _, _ in }
    ) -> NostrTransport.Dependencies {
        NostrTransport.Dependencies(
            notificationCenter: notificationCenter,
            loadFavorites: loadFavorites,
            favoriteStatusForNoiseKey: favoriteStatusForNoiseKey,
            favoriteStatusForPeerID: favoriteStatusForPeerID,
            currentIdentity: currentIdentity,
            registerPendingGiftWrap: registerPendingGiftWrap,
            sendEvent: sendEvent,
            scheduleAfter: scheduleAfter
        )
    }

    @MainActor
    private func makeNdrService(label: String) throws -> NdrNostrService {
        let storage = try makeTempDir(label: label)
        return NdrNostrService(
            relayManager: FakeRelayManager(),
            deviceId: "nostr-transport-\(label)",
            storageDirectoryProvider: { storage }
        )
    }

    private func makeRelationship(
        peerNoisePublicKey: Data,
        peerNostrPublicKey: String?,
        peerNickname: String
    ) -> FavoriteRelationship {
        FavoriteRelationship(
            peerNoisePublicKey: peerNoisePublicKey,
            peerNostrPublicKey: peerNostrPublicKey,
            peerNickname: peerNickname,
            isFavorite: true,
            theyFavoritedUs: true,
            favoritedAt: Date(timeIntervalSince1970: 1),
            lastUpdated: Date(timeIntervalSince1970: 2)
        )
    }

    private func makeTempDir(label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bitchat-tests-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        return dir
    }

    @MainActor
    private func establishMutualSession(
        _ senderService: NdrNostrService,
        _ recipientService: NdrNostrService,
        senderIdentity: NostrIdentity,
        recipientIdentity: NostrIdentity
    ) throws {
        var toRecipient: [String] = [try #require(senderService.currentInviteEventJson())]
        var toSender: [String] = [try #require(recipientService.currentInviteEventJson())]

        for _ in 0..<10 {
            let nextToSender = toRecipient.flatMap { recipientService.processOutOfBandEventJson($0) }
            let nextToRecipient = toSender.flatMap { senderService.processOutOfBandEventJson($0) }
            toRecipient = nextToRecipient
            toSender = nextToSender
            if senderService.hasActiveSession(with: recipientIdentity.publicKeyHex),
               recipientService.hasActiveSession(with: senderIdentity.publicKeyHex) {
                return
            }
            if toRecipient.isEmpty && toSender.isEmpty {
                break
            }
        }

        throw NostrTransportTestError.failedToEstablishNdrSession
    }

    private func decodeEmbeddedPayload(
        from event: NostrEvent,
        recipient: NostrIdentity
    ) throws -> (packet: BitchatPacket, payload: NoisePayload, senderPubkey: String) {
        let (content, senderPubkey, _) = try NostrProtocol.decryptPrivateMessage(
            giftWrap: event,
            recipientIdentity: recipient
        )
        guard content.hasPrefix("bitchat1:") else {
            throw NostrTransportTestError.invalidEmbeddedContent
        }
        let encoded = String(content.dropFirst("bitchat1:".count))
        guard let packetData = base64URLDecode(encoded),
              let packet = BitchatPacket.from(packetData),
              let payload = NoisePayload.decode(packet.payload) else {
            throw NostrTransportTestError.invalidPacket
        }
        return (packet, payload, senderPubkey)
    }

    private func decodePrivateMessage(from payload: NoisePayload) throws -> PrivateMessagePacket {
        guard payload.type == .privateMessage,
              let message = PrivateMessagePacket.decode(from: payload.data) else {
            throw NostrTransportTestError.invalidPrivateMessage
        }
        return message
    }

    private func extractNostrKind(json: String) throws -> Int {
        let data = Data(json.utf8)
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        let dict = try #require(obj as? [String: Any], "Nostr event should be a JSON object")
        return try #require(dict["kind"] as? Int, "Nostr event should include kind")
    }
}

private enum NostrTransportTestError: Error {
    case invalidEmbeddedContent
    case invalidPacket
    case invalidPrivateMessage
    case failedToEstablishNdrSession
}

private func base64URLDecode(_ string: String) -> Data? {
    var candidate = string
    let padding = (4 - (candidate.count % 4)) % 4
    if padding > 0 {
        candidate += String(repeating: "=", count: padding)
    }
    candidate = candidate
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    return Data(base64Encoded: candidate)
}

private final class NostrTransportProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var sentEventsStorage: [NostrEvent] = []
    private var pendingGiftWrapIDsStorage: [String] = []
    private var scheduledActionsStorage: [(@Sendable () -> Void)] = []

    var sentEvents: [NostrEvent] {
        lock.lock()
        defer { lock.unlock() }
        return sentEventsStorage
    }

    var pendingGiftWrapIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return pendingGiftWrapIDsStorage
    }

    var scheduledActionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return scheduledActionsStorage.count
    }

    func record(event: NostrEvent) {
        lock.lock()
        sentEventsStorage.append(event)
        lock.unlock()
    }

    func recordPendingGiftWrap(id: String) {
        lock.lock()
        pendingGiftWrapIDsStorage.append(id)
        lock.unlock()
    }

    func enqueueScheduledAction(delay: TimeInterval, action: @escaping @Sendable () -> Void) {
        _ = delay
        lock.lock()
        scheduledActionsStorage.append(action)
        lock.unlock()
    }

    @discardableResult
    func runNextScheduledAction() -> Bool {
        let action: (@Sendable () -> Void)?
        lock.lock()
        action = scheduledActionsStorage.isEmpty ? nil : scheduledActionsStorage.removeFirst()
        lock.unlock()
        guard let action else { return false }
        action()
        return true
    }
}

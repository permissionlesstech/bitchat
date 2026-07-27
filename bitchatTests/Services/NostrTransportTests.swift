//
// NostrTransportTests.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Combine
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

        // Offline favorites are addressed by the full 64-hex noise key, so
        // both forms must resolve to the same reachability answer.
        #expect(transport.isPeerReachable(fullPeerID))
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

        let didRefresh = await TestHelpers.waitUntil({ transport.isPeerReachable(peerID) }, timeout: 5.0)
        #expect(didRefresh)
    }

    @Test("Prompt delivery requires both a known npub and a relay connection")
    @MainActor
    func canDeliverPromptlyTracksRelayConnectivity() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let recipient = try NostrIdentity.generate()
        let noiseKey = Data((0..<32).map(UInt8.init))
        let peerID = PeerID(hexData: noiseKey)
        let relationship = makeRelationship(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: recipient.npub,
            peerNickname: "Alice"
        )
        let connectivity = CurrentValueSubject<Bool, Never>(false)

        let transport = NostrTransport(
            keychain: keychain,
            idBridge: idBridge,
            dependencies: makeDependencies(
                loadFavorites: { [noiseKey: relationship] },
                relayConnectivity: { connectivity.eraseToAnyPublisher() }
            )
        )

        // Reachable (npub known) but relays down: the peer must not be
        // treated as promptly deliverable, or the router would skip the
        // courier and let the message rot in the Nostr send queue.
        #expect(transport.isPeerReachable(peerID))
        #expect(!transport.canDeliverPromptly(to: peerID))

        connectivity.send(true)
        let deliverable = await TestHelpers.waitUntil(
            { transport.canDeliverPromptly(to: peerID) },
            timeout: 5.0
        )
        #expect(deliverable)

        connectivity.send(false)
        let undeliverable = await TestHelpers.waitUntil(
            { !transport.canDeliverPromptly(to: peerID) },
            timeout: 5.0
        )
        #expect(undeliverable)
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

        let didSend = await TestHelpers.waitUntil({ probe.sentEvents.count == 1 }, timeout: TestConstants.settleTimeout)
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
            rolloutEnabled: true,
            storageDirectoryProvider: { senderStorage }
        )
        let recipientNdr = NdrNostrService(
            relayManager: recipientRelay,
            rolloutEnabled: true,
            storageDirectoryProvider: { recipientStorage }
        )
        senderNdr.configureIfNeeded(identity: sender)
        recipientNdr.configureIfNeeded(identity: recipient)
        try establishMutualSession(
            senderNdr,
            recipientNdr,
            senderIdentity: sender,
            recipientIdentity: recipient,
            senderRelay: senderRelay,
            recipientRelay: recipientRelay
        )

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

    @Test("Disappearing-message expiry reaches the pairwise delivery")
    @MainActor
    func disappearingMessageForwardsAbsoluteExpiryToNdr() throws {
        let keychain = MockKeychain()
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let senderRelay = FakeRelayManager()
        let recipientRelay = FakeRelayManager()
        let senderStorage = try makeTempDir(
            label: "transport-expiry-sender"
        )
        let recipientStorage = try makeTempDir(
            label: "transport-expiry-recipient"
        )
        let senderNdr = NdrNostrService(
            relayManager: senderRelay,
            rolloutEnabled: true,
            storageDirectoryProvider: { senderStorage }
        )
        let recipientNdr = NdrNostrService(
            relayManager: recipientRelay,
            rolloutEnabled: true,
            storageDirectoryProvider: { recipientStorage }
        )
        senderNdr.configureIfNeeded(identity: sender)
        recipientNdr.configureIfNeeded(identity: recipient)
        try establishMutualSession(
            senderNdr,
            recipientNdr,
            senderIdentity: sender,
            recipientIdentity: recipient,
            senderRelay: senderRelay,
            recipientRelay: recipientRelay
        )
        senderRelay.resetSentEvents()

        let noiseKey = Data((72..<104).map(UInt8.init))
        let peerID = PeerID(hexData: noiseKey)
        let relationship = makeRelationship(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: recipient.npub,
            peerNickname: "Expires"
        )
        let transport = NostrTransport(
            keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: keychain),
            ndrService: senderNdr,
            dependencies: makeDependencies(
                favoriteStatusForNoiseKey: {
                    $0 == noiseKey ? relationship : nil
                },
                favoriteStatusForPeerID: { _ in nil },
                currentIdentity: { sender }
            )
        )
        transport.senderPeerID = PeerID(str: "0123456789abcdef")
        let expiration: UInt64 = 4_000_000_000

        let used = try transport.sendPrivateMessageAndReturnTransport(
            "vanish later",
            to: peerID,
            recipientNickname: "Expires",
            messageID: "pm-expiring",
            expiresAtSeconds: expiration
        )
        let outbound = try #require(
            senderRelay.sentEvents.first { $0.kind == 1060 }
        )
        var deliveredExpiration: UInt64?
        recipientNdr.onDecryptedMessage = { message, completion in
            deliveredExpiration = message.expiresAtSeconds
            completion(.consumed)
        }
        recipientNdr.processInboundRelayEvent(outbound)

        #expect(used == .ndr)
        #expect(deliveredExpiration == expiration)
    }

    @Test("A disappearing message never downgrades to kind 1059")
    @MainActor
    func disappearingMessageWithoutSessionFailsClosed() throws {
        let keychain = MockKeychain()
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let relay = FakeRelayManager()
        let ndrService = NdrNostrService(
            relayManager: relay,
            rolloutEnabled: true,
            storageDirectoryProvider: {
                try makeTempDir(label: "transport-expiry-no-session")
            }
        )
        let noiseKey = Data((104..<136).map(UInt8.init))
        let peerID = PeerID(hexData: noiseKey)
        let relationship = makeRelationship(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: recipient.npub,
            peerNickname: "No Session"
        )
        let probe = NostrTransportProbe()
        let transport = NostrTransport(
            keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: keychain),
            ndrService: ndrService,
            dependencies: makeDependencies(
                favoriteStatusForNoiseKey: {
                    $0 == noiseKey ? relationship : nil
                },
                favoriteStatusForPeerID: { _ in nil },
                currentIdentity: { sender },
                sendEvent: probe.record(event:)
            )
        )
        transport.senderPeerID = PeerID(str: "0123456789abcdef")

        do {
            _ = try transport.sendPrivateMessageAndReturnTransport(
                "must not become legacy",
                to: peerID,
                recipientNickname: "No Session",
                messageID: "pm-expiry-no-session",
                expiresAtSeconds: 4_000_000_000
            )
            Issue.record(
                "Expected an expiring send without NDR to fail closed"
            )
        } catch let error as NostrTransport.OutboundPrivateMessageError {
            guard case .expiringMessageRequiresNdrSession = error else {
                Issue.record("Unexpected transport error: \(error)")
                return
            }
        }

        #expect(probe.sentEvents.isEmpty)
        #expect(relay.sentEvents.isEmpty)
    }

    @Test("A durable NDR pin blocks legacy fallback with rollout off")
    @MainActor
    func durableNdrPinBlocksGateOffFallback() throws {
        let keychain = MockKeychain()
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let relay = FakeRelayManager()
        let ndrService = NdrNostrService(
            relayManager: relay,
            rolloutEnabled: false,
            storageDirectoryProvider: {
                try makeTempDir(label: "transport-gate-off-pin")
            }
        )
        let noiseKey = Data(repeating: 0x7d, count: 32)
        let peerID = PeerID(hexData: noiseKey)
        let relationship = makeRelationship(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: recipient.npub,
            peerNickname: "Pinned"
        )
        let probe = NostrTransportProbe()
        let transport = NostrTransport(
            keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: keychain),
            ndrService: ndrService,
            dependencies: makeDependencies(
                favoriteStatusForNoiseKey: {
                    $0 == noiseKey ? relationship : nil
                },
                canUseNdrBindingForPeerID: { _ in true },
                isNdrFallbackBlockedForPeerID: {
                    $0.toShort() == peerID.toShort()
                },
                currentIdentity: { sender },
                sendEvent: probe.record(event:)
            )
        )

        do {
            _ = try transport.sendPrivateMessageAndReturnTransport(
                "must remain pairwise",
                to: peerID,
                recipientNickname: "Pinned",
                messageID: "pm-gate-off-pin"
            )
            Issue.record("Expected a pinned gate-off send to fail closed")
        } catch let error as NostrTransport.OutboundPrivateMessageError {
            guard case .ndrSessionFailure = error else {
                Issue.record("Unexpected transport error: \(error)")
                return
            }
        }

        #expect(probe.sentEvents.isEmpty)
        #expect(relay.sentEvents.isEmpty)
    }

    @Test("A pairwise session is send-ready without a device roster")
    @MainActor
    func sendPrivateMessageDoesNotRequireDeviceRoster() throws {
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
            rolloutEnabled: true,
            storageDirectoryProvider: { senderStorage }
        )
        let recipientNdr = NdrNostrService(
            relayManager: recipientRelay,
            rolloutEnabled: true,
            storageDirectoryProvider: { recipientStorage }
        )
        senderNdr.configureIfNeeded(identity: sender)
        recipientNdr.configureIfNeeded(identity: recipient)
        try establishMutualSession(
            senderNdr,
            recipientNdr,
            senderIdentity: sender,
            recipientIdentity: recipient,
            senderRelay: senderRelay,
            recipientRelay: recipientRelay
        )
        #expect(!senderRelay.sentEvents.contains { $0.kind == 37368 })
        #expect(!recipientRelay.sentEvents.contains { $0.kind == 37368 })
        #expect(!senderRelay.subscriptions.contains { $0.filter.kinds?.contains(37368) == true })
        #expect(!recipientRelay.subscriptions.contains { $0.filter.kinds?.contains(37368) == true })

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
            "pairwise ndr",
            to: fullPeerID,
            recipientNickname: "Queued",
            messageID: "pm-pairwise-ndr"
        )

        #expect(transportUsed == .ndr)
        #expect(probe.sentEvents.isEmpty)
        #expect(senderRelay.sentEvents.filter { $0.kind == 1060 }.count == 1)
    }

    @Test("An existing ratchet session never downgrades to legacy encryption")
    @MainActor
    func activeButNotSendReadySessionFailsClosed() throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let senderRelay = FakeRelayManager()
        let recipientRelay = FakeRelayManager()
        let senderNdr = NdrNostrService(
            relayManager: senderRelay,
            rolloutEnabled: true,
            storageDirectoryProvider: {
                try makeTempDir(label: "fail-closed-sender")
            }
        )
        let recipientNdr = NdrNostrService(
            relayManager: recipientRelay,
            rolloutEnabled: true,
            storageDirectoryProvider: {
                try makeTempDir(label: "fail-closed-recipient")
            }
        )
        senderNdr.configureIfNeeded(identity: sender)
        recipientNdr.configureIfNeeded(identity: recipient)

        // Processing the response installs a receive path. Until its relay
        // bootstrap arrives, this is intentionally not a send-ready session.
        let senderInvite = try #require(senderNdr.currentInviteEventJson())
        let response = try #require(
            recipientNdr.processOutOfBandEventJson(
                senderInvite,
                expectedPeerPubkeyHex: sender.publicKeyHex,
                persistEstablishedBinding: { true }
            ).first
        )
        recipientNdr.completeOutOfBandAction(response, succeeded: true)
        _ = senderNdr.processOutOfBandEventJson(
            response.eventJson,
            expectedPeerPubkeyHex: recipient.publicKeyHex,
            persistEstablishedBinding: { true }
        )
        #expect(
            senderNdr.hasPairwiseSession(with: recipient.publicKeyHex)
        )

        let noiseKey = Data((88..<120).map(UInt8.init))
        let peerID = PeerID(hexData: noiseKey)
        let relationship = makeRelationship(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: recipient.npub,
            peerNickname: "Fail Closed"
        )
        let probe = NostrTransportProbe()
        let transport = NostrTransport(
            keychain: keychain,
            idBridge: idBridge,
            ndrService: senderNdr,
            dependencies: makeDependencies(
                favoriteStatusForNoiseKey: {
                    $0 == noiseKey ? relationship : nil
                },
                favoriteStatusForPeerID: { _ in nil },
                currentIdentity: { sender },
                sendEvent: probe.record(event:)
            )
        )
        transport.senderPeerID = PeerID(str: "0123456789abcdef")

        do {
            _ = try transport.sendPrivateMessageAndReturnTransport(
                "must not downgrade",
                to: peerID,
                recipientNickname: "Fail Closed",
                messageID: "pm-fail-closed"
            )
            Issue.record("Expected the non-send-ready NDR session to fail")
        } catch let error as NostrTransport.OutboundPrivateMessageError {
            guard case .ndrSessionFailure = error else {
                Issue.record("Unexpected transport error: \(error)")
                return
            }
        }

        #expect(probe.sentEvents.isEmpty)
        #expect(senderRelay.sentEvents.allSatisfy { $0.kind == 1060 })
    }

    @Test("An NDR storage-open failure never falls back to legacy encryption")
    @MainActor
    func ndrConfigurationFailureFailsClosed() throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let relay = FakeRelayManager()
        let ndrService = NdrNostrService(
            relayManager: relay,
            rolloutEnabled: true,
            storageDirectoryProvider: {
                throw NostrTransportTestError.storageUnavailable
            }
        )
        let noiseKey = Data((96..<128).map(UInt8.init))
        let peerID = PeerID(hexData: noiseKey)
        let relationship = makeRelationship(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: recipient.npub,
            peerNickname: "Corrupt State"
        )
        let probe = NostrTransportProbe()
        let transport = NostrTransport(
            keychain: keychain,
            idBridge: idBridge,
            ndrService: ndrService,
            dependencies: makeDependencies(
                favoriteStatusForNoiseKey: {
                    $0 == noiseKey ? relationship : nil
                },
                favoriteStatusForPeerID: { _ in nil },
                currentIdentity: { sender },
                sendEvent: probe.record(event:)
            )
        )
        transport.senderPeerID = PeerID(str: "0123456789abcdef")

        for _ in 0..<2 {
            do {
                _ = try transport.sendPrivateMessageAndReturnTransport(
                    "must remain failed",
                    to: peerID,
                    recipientNickname: "Corrupt State",
                    messageID: UUID().uuidString
                )
                Issue.record("Expected NDR configuration failure")
            } catch let error as NostrTransport.OutboundPrivateMessageError {
                guard case .ndrSessionFailure = error else {
                    Issue.record("Unexpected transport error: \(error)")
                    return
                }
            }
        }

        #expect(probe.sentEvents.isEmpty)
        #expect(relay.sentEvents.isEmpty)
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

        let didSend = await TestHelpers.waitUntil({ probe.sentEvents.count == 1 }, timeout: TestConstants.settleTimeout)
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

        let didSend = await TestHelpers.waitUntil({ probe.sentEvents.count == 1 }, timeout: TestConstants.settleTimeout)
        #expect(didSend)
        let result = try decodeEmbeddedPayload(from: probe.sentEvents[0], recipient: recipient)

        #expect(result.payload.type == .delivered)
        #expect(String(data: result.payload.data, encoding: .utf8) == "ack-1")
        #expect(result.packet.recipientID == fullPeerID.toShort().routingData)
    }

    @Test("Direct delivery and read ACKs stay on an established NDR session")
    @MainActor
    func directAcksUseNdrWhenSessionExists() async throws {
        let keychain = MockKeychain()
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let senderRelay = FakeRelayManager()
        let recipientRelay = FakeRelayManager()
        let senderNdr = NdrNostrService(
            relayManager: senderRelay,
            rolloutEnabled: true,
            storageDirectoryProvider: {
                try makeTempDir(label: "direct-ack-ndr-sender")
            }
        )
        let recipientNdr = NdrNostrService(
            relayManager: recipientRelay,
            rolloutEnabled: true,
            storageDirectoryProvider: {
                try makeTempDir(label: "direct-ack-ndr-recipient")
            }
        )
        senderNdr.configureIfNeeded(identity: sender)
        recipientNdr.configureIfNeeded(identity: recipient)
        try establishMutualSession(
            senderNdr,
            recipientNdr,
            senderIdentity: sender,
            recipientIdentity: recipient,
            senderRelay: senderRelay,
            recipientRelay: recipientRelay
        )
        senderRelay.resetSentEvents()

        let noiseKey = Data((144..<176).map(UInt8.init))
        let peerID = PeerID(hexData: noiseKey)
        let relationship = makeRelationship(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: recipient.npub,
            peerNickname: "Ack peer"
        )
        let legacyProbe = NostrTransportProbe()
        let transport = NostrTransport(
            keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: keychain),
            ndrService: senderNdr,
            dependencies: makeDependencies(
                favoriteStatusForNoiseKey: {
                    $0 == noiseKey ? relationship : nil
                },
                isNdrFallbackBlockedForPeerID: {
                    $0.toShort() == peerID.toShort()
                },
                currentIdentity: { sender },
                sendEvent: legacyProbe.record(event:),
                scheduleAfter: { delay, action in
                    legacyProbe.enqueueScheduledAction(
                        delay: delay,
                        action: action
                    )
                }
            )
        )
        transport.senderPeerID = PeerID(str: "0123456789abcdef")
        var decryptedMessages: [NdrDecryptedMessage] = []
        recipientNdr.onDecryptedMessage = { message, completion in
            decryptedMessages.append(message)
            completion(.consumed)
        }

        transport.sendDeliveryAck(for: "ndr-delivered-1", to: peerID)
        let deliveredSent = await TestHelpers.waitUntil({
            senderRelay.sentEvents.filter { $0.kind == 1060 }.count == 1
        })
        #expect(deliveredSent)
        let deliveredOuter = try #require(
            senderRelay.sentEvents.first { $0.kind == 1060 }
        )
        recipientNdr.processInboundRelayEvent(deliveredOuter)

        let receipt = ReadReceipt(
            originalMessageID: "ndr-read-1",
            readerID: transport.myPeerID,
            readerNickname: "me"
        )
        transport.sendReadReceipt(receipt, to: peerID)
        let readQueued = await TestHelpers.waitUntil({
            legacyProbe.scheduledActionCount == 1
        })
        #expect(readQueued)
        #expect(legacyProbe.runNextScheduledAction())
        let readSent = await TestHelpers.waitUntil({
            senderRelay.sentEvents.filter { $0.kind == 1060 }.count == 2
        })
        #expect(readSent)
        let readOuter = try #require(
            senderRelay.sentEvents.filter { $0.kind == 1060 }.last
        )
        recipientNdr.processInboundRelayEvent(readOuter)

        #expect(legacyProbe.sentEvents.isEmpty)
        #expect(decryptedMessages.count == 2)
        let deliveredPayload = try decodeNdrEmbeddedPayload(
            from: decryptedMessages[0].event.content
        )
        #expect(deliveredPayload.type == .delivered)
        #expect(
            String(data: deliveredPayload.data, encoding: .utf8)
                == "ndr-delivered-1"
        )
        let readPayload = try decodeNdrEmbeddedPayload(
            from: decryptedMessages[1].event.content
        )
        #expect(readPayload.type == .readReceipt)
        #expect(
            String(data: readPayload.data, encoding: .utf8)
                == "ndr-read-1"
        )
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

        let didSend = await TestHelpers.waitUntil({ probe.sentEvents.count == 1 }, timeout: TestConstants.settleTimeout)
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

        let readReceiptTimeout: TimeInterval = 5.0
        let sentFirst = await TestHelpers.waitUntil({ probe.sentEvents.count >= 1 }, timeout: readReceiptTimeout)
        try #require(sentFirst, "Expected first queued read receipt event")
        let scheduledThrottle = await TestHelpers.waitUntil({ probe.scheduledActionCount == 1 }, timeout: readReceiptTimeout)
        try #require(scheduledThrottle, "Expected queued throttle action after first read receipt")
        let firstEvent = try #require(probe.sentEvents.first, "Expected first queued read receipt event")
        let firstPayload = try decodeEmbeddedPayload(from: firstEvent, recipient: recipient).payload
        #expect(firstPayload.type == .readReceipt)
        #expect(String(data: firstPayload.data, encoding: .utf8) == "read-1")

        try #require(probe.runNextScheduledAction(), "Expected queued throttle action after first read receipt")

        let sentSecond = await TestHelpers.waitUntil({ probe.sentEvents.count >= 2 }, timeout: readReceiptTimeout)
        try #require(sentSecond, "Expected second read receipt after running throttle action")
        let secondEvent = try #require(probe.sentEvents.last, "Expected second queued read receipt event")
        let secondPayload = try decodeEmbeddedPayload(from: secondEvent, recipient: recipient).payload
        #expect(secondPayload.type == .readReceipt)
        #expect(String(data: secondPayload.data, encoding: .utf8) == "read-2")
        withExtendedLifetime(transport) {}
    }

    // These thread-safety tests must hammer from the dispatch pool
    // (concurrentPerform), NOT a task group: transport calls block in
    // queue.sync, and a 100-task group runs them on the Swift Concurrency
    // cooperative pool — one thread per core, just 3 on CI runners. Parking
    // every cooperative thread in a blocking sync violates the forward
    // progress contract and wedged dispatch on the CI runners' macOS,
    // deadlocking the whole app suite into the 15-minute job timeout
    // (watchdog stacks: NostrTransport.isPeerReachable syncs holding all
    // pool threads). Blocking is legal on dispatch worker threads.
    @Test("Concurrent read receipt enqueue does not crash")
    @MainActor
    func concurrentReadReceiptEnqueue() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let ndrService = try makeNdrService(label: "concurrent-read")
        let transport = NostrTransport(keychain: keychain, idBridge: idBridge, ndrService: ndrService)
        let iterations = 100

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                DispatchQueue.concurrentPerform(iterations: iterations) { i in
                    let receipt = ReadReceipt(
                        originalMessageID: UUID().uuidString,
                        readerID: PeerID(str: String(format: "%016x", i)),
                        readerNickname: "Reader\(i)"
                    )
                    let peerID = PeerID(str: String(format: "%016x", i))
                    transport.sendReadReceipt(receipt, to: peerID)
                }
                continuation.resume()
            }
        }
        withExtendedLifetime(transport) {}
    }

    @Test("isPeerReachable is thread safe")
    @MainActor
    func isPeerReachableThreadSafety() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let ndrService = try makeNdrService(label: "reachable-thread-safety")
        let transport = NostrTransport(keychain: keychain, idBridge: idBridge, ndrService: ndrService)
        let iterations = 100

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                DispatchQueue.concurrentPerform(iterations: iterations) { i in
                    let peerID = PeerID(str: String(format: "%016x", i))
                    #expect(transport.isPeerReachable(peerID) == false)
                }
                continuation.resume()
            }
        }
        withExtendedLifetime(transport) {}
    }

    @MainActor
    private func makeDependencies(
        notificationCenter: NotificationCenter = NotificationCenter(),
        loadFavorites: @escaping @MainActor () -> [Data: FavoriteRelationship] = { [:] },
        favoriteStatusForNoiseKey: @escaping @MainActor (Data) -> FavoriteRelationship? = { _ in nil },
        favoriteStatusForPeerID: @escaping @MainActor (PeerID) -> FavoriteRelationship? = { _ in nil },
        canUseNdrBindingForPeerID: @escaping @MainActor (PeerID) -> Bool = { _ in true },
        isNdrFallbackBlockedForPeerID: @escaping @MainActor (PeerID) -> Bool = { _ in false },
        currentIdentity: @escaping @MainActor () throws -> NostrIdentity? = { nil },
        registerPendingGiftWrap: @escaping @MainActor (String) -> Void = { _ in },
        sendEvent: @escaping @MainActor (NostrEvent) -> Void = { _ in },
        scheduleAfter: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void = { _, _ in },
        relayConnectivity: @escaping @MainActor () -> AnyPublisher<Bool, Never> = { Just(false).eraseToAnyPublisher() }
    ) -> NostrTransport.Dependencies {
        NostrTransport.Dependencies(
            notificationCenter: notificationCenter,
            loadFavorites: loadFavorites,
            favoriteStatusForNoiseKey: favoriteStatusForNoiseKey,
            favoriteStatusForPeerID: favoriteStatusForPeerID,
            canUseNdrBindingForPeerID:
                canUseNdrBindingForPeerID,
            isNdrFallbackBlockedForPeerID:
                isNdrFallbackBlockedForPeerID,
            currentIdentity: currentIdentity,
            registerPendingGiftWrap: registerPendingGiftWrap,
            sendEvent: sendEvent,
            scheduleAfter: scheduleAfter,
            relayConnectivity: relayConnectivity
        )
    }

    @MainActor
    private func makeNdrService(label: String) throws -> NdrNostrService {
        let storage = try makeTempDir(label: label)
        return NdrNostrService(
            relayManager: FakeRelayManager(),
            rolloutEnabled: true,
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
        recipientIdentity: NostrIdentity,
        senderRelay: FakeRelayManager,
        recipientRelay: FakeRelayManager
    ) throws {
        let senderRelayIndex = senderRelay.sentEvents.count
        let recipientRelayIndex = recipientRelay.sentEvents.count
        let senderInvite = try #require(
            senderService.currentInviteEventJson()
        )
        let recipientInvite = try #require(
            recipientService.currentInviteEventJson()
        )
        let generatedByRecipient =
            recipientService.processOutOfBandEventJson(
                senderInvite,
                expectedPeerPubkeyHex: senderIdentity.publicKeyHex,
                persistEstablishedBinding: { true }
            )
        let generatedBySender =
            senderService.processOutOfBandEventJson(
                recipientInvite,
                expectedPeerPubkeyHex: recipientIdentity.publicKeyHex,
                persistEstablishedBinding: { true }
            )

        for response in generatedByRecipient {
            recipientService.completeOutOfBandAction(
                response,
                succeeded: true
            )
            _ = senderService.processOutOfBandEventJson(
                response.eventJson,
                expectedPeerPubkeyHex: recipientIdentity.publicKeyHex,
                persistEstablishedBinding: { true }
            )
        }
        for response in generatedBySender {
            senderService.completeOutOfBandAction(
                response,
                succeeded: true
            )
            _ = recipientService.processOutOfBandEventJson(
                response.eventJson,
                expectedPeerPubkeyHex: senderIdentity.publicKeyHex,
                persistEstablishedBinding: { true }
            )
        }

        for event in senderRelay.sentEvents
            .dropFirst(senderRelayIndex)
        where event.kind == 1060
        {
            recipientService.processInboundRelayEvent(event)
        }
        for event in recipientRelay.sentEvents
            .dropFirst(recipientRelayIndex)
        where event.kind == 1060
        {
            senderService.processInboundRelayEvent(event)
        }

        guard senderService.hasActiveSession(
            with: recipientIdentity.publicKeyHex
        ),
            recipientService.hasActiveSession(
                with: senderIdentity.publicKeyHex
            )
        else {
            throw NostrTransportTestError.failedToEstablishNdrSession
        }
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

    private func decodeNdrEmbeddedPayload(
        from content: String
    ) throws -> NoisePayload {
        guard content.hasPrefix("bitchat1:") else {
            throw NostrTransportTestError.invalidEmbeddedContent
        }
        let encoded = String(content.dropFirst("bitchat1:".count))
        guard let packetData = base64URLDecode(encoded),
              let packet = BitchatPacket.from(packetData),
              let payload = NoisePayload.decode(packet.payload) else {
            throw NostrTransportTestError.invalidPacket
        }
        return payload
    }

    private func decodePrivateMessage(from payload: NoisePayload) throws -> PrivateMessagePacket {
        guard payload.type == .privateMessage,
              let message = PrivateMessagePacket.decode(from: payload.data) else {
            throw NostrTransportTestError.invalidPrivateMessage
        }
        return message
    }

}

private enum NostrTransportTestError: Error {
    case invalidEmbeddedContent
    case invalidPacket
    case invalidPrivateMessage
    case failedToEstablishNdrSession
    case storageUnavailable
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

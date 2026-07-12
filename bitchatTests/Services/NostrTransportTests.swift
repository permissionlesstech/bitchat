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
        let recipient = try NostrIdentity.generate()
        let noiseKey = Data((32..<64).map(UInt8.init))
        let peerID = PeerID(hexData: noiseKey).toShort()
        let notificationCenter = NotificationCenter()
        var favorites: [Data: FavoriteRelationship] = [:]

        let transport = NostrTransport(
            keychain: keychain,
            idBridge: idBridge,
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

    @Test("Private message resolves short peer ID and emits both migration formats")
    @MainActor
    func sendPrivateMessageResolvesShortPeerID() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
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
            dependencies: makeDependencies(
                favoriteStatusForNoiseKey: { _ in nil },
                favoriteStatusForPeerID: { $0 == shortPeerID ? relationship : nil },
                currentIdentity: { sender },
                registerPendingPrivateEnvelope: probe.recordPendingPrivateEnvelope(id:),
                sendPrivateEnvelopeBatch: { events, _ in probe.record(batch: events) },
                scheduleAfter: { delay, action in
                    probe.enqueueScheduledAction(delay: delay, action: action)
                }
            )
        )
        transport.senderPeerID = PeerID(str: "0123456789abcdef")

        transport.sendPrivateMessage("hello over nostr", to: shortPeerID, recipientNickname: "Carol", messageID: "pm-1")

        let didSend = await TestHelpers.waitUntil({ probe.sentEvents.count == 2 }, timeout: 5.0)
        #expect(didSend)
        #expect(probe.sentEvents.map(\.kind) == [
            NostrProtocol.EventKind.privateEnvelope.rawValue,
            NostrProtocol.EventKind.legacyNIP59GiftWrap.rawValue
        ])
        let result = try decodeEmbeddedPayload(from: probe.sentEvents[0], recipient: recipient)
        let privateMessage = try decodePrivateMessage(from: result.payload)

        #expect(result.senderPubkey == sender.publicKeyHex)
        #expect(privateMessage.messageID == "pm-1")
        #expect(privateMessage.content == "hello over nostr")
        #expect(result.packet.recipientID == shortPeerID.routingData)
        #expect(probe.pendingPrivateEnvelopeIDs.isEmpty)
    }

    @Test("Coordinated migration always publishes primary and compatibility envelopes")
    @MainActor
    func migrationAlwaysDualPublishes() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let noiseKey = Data((192..<224).map(UInt8.init))
        let peerID = PeerID(hexData: noiseKey)
        let relationship = makeRelationship(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: recipient.npub,
            peerNickname: "Migration peer"
        )

        let migrationProbe = NostrTransportProbe()
        let migrationTransport = NostrTransport(
            keychain: keychain,
            idBridge: idBridge,
            dependencies: makeDependencies(
                favoriteStatusForNoiseKey: { $0 == noiseKey ? relationship : nil },
                currentIdentity: { sender },
                sendPrivateEnvelopeBatch: { events, _ in migrationProbe.record(batch: events) }
            )
        )
        migrationTransport.senderPeerID = PeerID(str: "0123456789abcdef")
        migrationTransport.sendPrivateMessage(
            "migration payload",
            to: peerID,
            recipientNickname: "Migration peer",
            messageID: "migration-pm"
        )

        let sentPair = await TestHelpers.waitUntil(
            { migrationProbe.sentEvents.count == 2 },
            timeout: 5.0
        )
        #expect(sentPair)
        #expect(migrationProbe.sentEvents.map(\.kind) == [
            NostrProtocol.EventKind.privateEnvelope.rawValue,
            NostrProtocol.EventKind.legacyNIP59GiftWrap.rawValue
        ])
        for event in migrationProbe.sentEvents {
            let result = try decodeEmbeddedPayload(from: event, recipient: recipient)
            let message = try decodePrivateMessage(from: result.payload)
            #expect(message.messageID == "migration-pm")
            #expect(message.content == "migration payload")
        }
    }

    @Test("Rejected migration batch does not register half-delivery state")
    @MainActor
    func rejectedMigrationBatchRegistersNothing() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let probe = NostrTransportProbe()
        var rejectedKinds: [Int] = []
        let transport = NostrTransport(
            keychain: keychain,
            idBridge: idBridge,
            dependencies: makeDependencies(
                currentIdentity: { sender },
                registerPendingPrivateEnvelope: probe.recordPendingPrivateEnvelope(id:),
                sendPrivateEnvelopeBatch: { events, _ in
                    rejectedKinds = events.map(\.kind)
                    return false
                }
            )
        )
        transport.senderPeerID = PeerID(str: "0123456789abcdef")

        transport.sendPrivateMessageGeohash(
            content: "must stay atomic",
            toRecipientHex: recipient.publicKeyHex,
            from: sender,
            messageID: "atomic-reject"
        )

        let attempted = await TestHelpers.waitUntil({ rejectedKinds.count == 2 }, timeout: 5.0)
        #expect(attempted)
        #expect(rejectedKinds == [
            NostrProtocol.EventKind.privateEnvelope.rawValue,
            NostrProtocol.EventKind.legacyNIP59GiftWrap.rawValue
        ])
        #expect(probe.pendingPrivateEnvelopeIDs.isEmpty)
    }

    @Test("Rejected user message emits a visible failed-delivery event")
    @MainActor
    func rejectedUserMessageEmitsFailureEvent() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let eventProbe = NostrTransportEventProbe()
        let transport = NostrTransport(
            keychain: keychain,
            idBridge: idBridge,
            dependencies: makeDependencies(
                currentIdentity: { sender },
                sendPrivateEnvelopeBatch: { _, _ in false }
            )
        )
        transport.senderPeerID = PeerID(str: "0123456789abcdef")
        transport.eventDelegate = eventProbe

        transport.sendPrivateMessageGeohash(
            content: "must fail visibly",
            toRecipientHex: recipient.publicKeyHex,
            from: sender,
            messageID: "visible-reject"
        )

        let reported = await TestHelpers.waitUntil(
            { eventProbe.failedMessageIDs == ["visible-reject"] },
            timeout: 5.0
        )
        #expect(reported)
    }

    @Test("Rejected favorite notification retains and retries the exact pair")
    @MainActor
    func rejectedFavoriteNotificationRetriesExactPair() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let noiseKey = Data((96..<128).map(UInt8.init))
        let fullPeerID = PeerID(hexData: noiseKey)
        let relationship = makeRelationship(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: recipient.npub,
            peerNickname: "Retry favorite"
        )
        let probe = NostrTransportProbe()
        var attempts: [[String]] = []
        weak var releasedTransport: NostrTransport?
        do {
            let transport = NostrTransport(
                keychain: keychain,
                idBridge: idBridge,
                dependencies: makeDependencies(
                    favoriteStatusForNoiseKey: { $0 == noiseKey ? relationship : nil },
                    currentIdentity: { sender },
                    sendPrivateEnvelopeBatch: { events, _ in
                        attempts.append(events.map(\.id))
                        return attempts.count > 1
                    },
                    scheduleAfter: { delay, action in
                        probe.enqueueScheduledAction(delay: delay, action: action)
                    }
                )
            )
            transport.senderPeerID = PeerID(str: "0123456789abcdef")
            releasedTransport = transport

            transport.sendFavoriteNotification(to: fullPeerID, isFavorite: true)
            let retryScheduled = await TestHelpers.waitUntil(
                { attempts.count == 1 && probe.scheduledActionCount == 1 },
                timeout: 5.0
            )
            #expect(retryScheduled)
        }
        #expect(releasedTransport == nil)
        #expect(probe.runNextScheduledAction())

        let retried = await TestHelpers.waitUntil({ attempts.count == 2 }, timeout: 5.0)
        #expect(retried)
        #expect(attempts[0] == attempts[1])
    }

    @Test("Rejected delivery acknowledgement remains queued for retry")
    @MainActor
    func rejectedDeliveryAckRetries() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let noiseKey = Data((128..<160).map(UInt8.init))
        let fullPeerID = PeerID(hexData: noiseKey)
        let relationship = makeRelationship(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: recipient.npub,
            peerNickname: "Retry ack"
        )
        let probe = NostrTransportProbe()
        var attempts: [[String]] = []
        let transport = NostrTransport(
            keychain: keychain,
            idBridge: idBridge,
            dependencies: makeDependencies(
                favoriteStatusForNoiseKey: { $0 == noiseKey ? relationship : nil },
                currentIdentity: { sender },
                sendPrivateEnvelopeBatch: { events, _ in
                    attempts.append(events.map(\.id))
                    return attempts.count > 1
                },
                scheduleAfter: { delay, action in
                    probe.enqueueScheduledAction(delay: delay, action: action)
                }
            )
        )
        transport.senderPeerID = PeerID(str: "0123456789abcdef")

        transport.sendDeliveryAck(for: "retry-ack", to: fullPeerID)
        let firstAttempt = await TestHelpers.waitUntil(
            { attempts.count == 1 && probe.scheduledActionCount >= 1 },
            timeout: 5.0
        )
        #expect(firstAttempt)

        for _ in 0..<3 where attempts.count < 2 {
            _ = probe.runNextScheduledAction()
            _ = await TestHelpers.waitUntil(
                { attempts.count == 2 || probe.scheduledActionCount > 0 },
                timeout: 1.0
            )
        }
        #expect(attempts.count == 2)
        #expect(attempts[0] == attempts[1])
    }

    @Test("Control retry queue is bounded and evicted callbacks are harmless")
    @MainActor
    func controlRetryQueueIsBounded() async throws {
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let events = try NostrProtocol.createPrivateEnvelopePublicationBatch(
            content: "bounded retry fixture",
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )
        let probe = NostrTransportProbe()
        var retryAttempts = 0
        let queue = NostrPrivateEnvelopeRetryQueue(
            sendPrivateEnvelopeBatch: { _, _ in
                retryAttempts += 1
                return false
            },
            registerPendingPrivateEnvelope: { _ in },
            scheduleAfter: { delay, action in
                probe.enqueueScheduledAction(delay: delay, action: action)
            }
        )

        for index in 0...TransportConfig.nostrPrivateEnvelopeRetryQueueCap {
            queue.enqueue(
                key: "control-\(index)",
                events: events,
                registerPending: false
            )
        }

        #expect(queue.debugPendingCount == TransportConfig.nostrPrivateEnvelopeRetryQueueCap)
        #expect(!queue.debugContains(key: "control-0"))
        #expect(queue.debugContains(key: "control-1"))

        // The oldest callback was scheduled before eviction. Running it must
        // observe the missing key and return without touching dependencies.
        #expect(probe.runNextScheduledAction())
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(retryAttempts == 0)

        queue.removeAll()
        #expect(queue.debugPendingCount == 0)
        #expect(probe.runNextScheduledAction())
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(retryAttempts == 0)
    }

    @Test("Multiple transports share one globally bounded control retry owner")
    @MainActor
    func multipleTransportsShareControlRetryQueue() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let events = try NostrProtocol.createPrivateEnvelopePublicationBatch(
            content: "shared retry fixture",
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )
        let probe = NostrTransportProbe()
        var retryAttempts = 0
        let sharedQueue = NostrPrivateEnvelopeRetryQueue(
            sendPrivateEnvelopeBatch: { _, _ in
                retryAttempts += 1
                return false
            },
            registerPendingPrivateEnvelope: { _ in },
            scheduleAfter: { delay, action in
                probe.enqueueScheduledAction(delay: delay, action: action)
            }
        )
        let first = NostrTransport(
            keychain: keychain,
            idBridge: idBridge,
            dependencies: makeDependencies(envelopeRetryQueue: sharedQueue)
        )
        let second = NostrTransport(
            keychain: keychain,
            idBridge: idBridge,
            dependencies: makeDependencies(envelopeRetryQueue: sharedQueue)
        )

        first.debugEnqueueControlRetry(key: "shared", events: events)
        second.debugEnqueueControlRetry(key: "shared", events: events)
        #expect(first.debugControlRetryCount == 1)
        #expect(second.debugControlRetryCount == 1)

        for index in 0...TransportConfig.nostrPrivateEnvelopeRetryQueueCap {
            let transport = index.isMultiple(of: 2) ? first : second
            transport.debugEnqueueControlRetry(key: "global-\(index)", events: events)
        }
        #expect(first.debugControlRetryCount == TransportConfig.nostrPrivateEnvelopeRetryQueueCap)
        #expect(second.debugControlRetryCount == TransportConfig.nostrPrivateEnvelopeRetryQueueCap)

        // The first scheduled callback belongs to the now-evicted shared key.
        #expect(probe.runNextScheduledAction())
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(retryAttempts == 0)
    }

    @Test("Favorite notification embeds current npub")
    @MainActor
    func sendFavoriteNotificationEmbedsCurrentIdentity() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
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
            dependencies: makeDependencies(
                favoriteStatusForNoiseKey: { $0 == noiseKey ? relationship : nil },
                favoriteStatusForPeerID: { _ in nil },
                currentIdentity: { sender },
                registerPendingPrivateEnvelope: probe.recordPendingPrivateEnvelope(id:),
                sendPrivateEnvelopeBatch: { events, _ in probe.record(batch: events) },
                scheduleAfter: { delay, action in
                    probe.enqueueScheduledAction(delay: delay, action: action)
                }
            )
        )
        transport.senderPeerID = PeerID(str: "0123456789abcdef")

        transport.sendFavoriteNotification(to: fullPeerID, isFavorite: true)

        let didSend = await TestHelpers.waitUntil({ probe.sentEvents.count == 2 }, timeout: 5.0)
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
            dependencies: makeDependencies(
                favoriteStatusForNoiseKey: { $0 == noiseKey ? relationship : nil },
                favoriteStatusForPeerID: { _ in nil },
                currentIdentity: { sender },
                registerPendingPrivateEnvelope: probe.recordPendingPrivateEnvelope(id:),
                sendPrivateEnvelopeBatch: { events, _ in probe.record(batch: events) },
                scheduleAfter: { delay, action in
                    probe.enqueueScheduledAction(delay: delay, action: action)
                }
            )
        )
        transport.senderPeerID = PeerID(str: "0123456789abcdef")

        transport.sendDeliveryAck(for: "ack-1", to: fullPeerID)

        let didSend = await TestHelpers.waitUntil({ probe.sentEvents.count == 2 }, timeout: 5.0)
        #expect(didSend)
        let result = try decodeEmbeddedPayload(from: probe.sentEvents[0], recipient: recipient)

        #expect(result.payload.type == .delivered)
        #expect(String(data: result.payload.data, encoding: .utf8) == "ack-1")
        #expect(result.packet.recipientID == fullPeerID.toShort().routingData)
    }

    @Test("Geohash private message registers pending private envelope")
    @MainActor
    func sendPrivateMessageGeohashRegistersPendingPrivateEnvelope() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let probe = NostrTransportProbe()
        let transport = NostrTransport(
            keychain: keychain,
            idBridge: idBridge,
            dependencies: makeDependencies(
                currentIdentity: { sender },
                registerPendingPrivateEnvelope: probe.recordPendingPrivateEnvelope(id:),
                sendPrivateEnvelopeBatch: { events, _ in probe.record(batch: events) },
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

        let didSend = await TestHelpers.waitUntil({ probe.sentEvents.count == 2 }, timeout: 5.0)
        #expect(didSend)
        let event = probe.sentEvents[0]
        let result = try decodeEmbeddedPayload(from: event, recipient: recipient)
        let privateMessage = try decodePrivateMessage(from: result.payload)

        #expect(privateMessage.messageID == "geo-1")
        #expect(privateMessage.content == "geo hello")
        #expect(result.packet.recipientID == nil)
        #expect(probe.pendingPrivateEnvelopeIDs == probe.sentEvents.map(\.id))
    }

    @Test("Read receipt queue sends in order and waits for scheduler")
    @MainActor
    func readReceiptQueueThrottlesSequentially() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
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
            dependencies: makeDependencies(
                favoriteStatusForNoiseKey: { $0 == noiseKey ? relationship : nil },
                favoriteStatusForPeerID: { _ in nil },
                currentIdentity: { sender },
                registerPendingPrivateEnvelope: probe.recordPendingPrivateEnvelope(id:),
                sendPrivateEnvelopeBatch: { events, _ in probe.record(batch: events) },
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
        let sentFirst = await TestHelpers.waitUntil({ probe.sentEvents.count == 2 }, timeout: readReceiptTimeout)
        try #require(sentFirst, "Expected first queued read receipt pair")
        let scheduledThrottle = await TestHelpers.waitUntil({ probe.scheduledActionCount == 1 }, timeout: readReceiptTimeout)
        try #require(scheduledThrottle, "Expected queued throttle action after first read receipt")
        let firstEvent = try #require(probe.sentEvents.first, "Expected first queued read receipt pair")
        let firstPayload = try decodeEmbeddedPayload(from: firstEvent, recipient: recipient).payload
        #expect(firstPayload.type == .readReceipt)
        #expect(String(data: firstPayload.data, encoding: .utf8) == "read-1")

        try #require(probe.runNextScheduledAction(), "Expected queued throttle action after first read receipt")

        let sentSecond = await TestHelpers.waitUntil({ probe.sentEvents.count == 4 }, timeout: readReceiptTimeout)
        try #require(sentSecond, "Expected second read receipt pair after running throttle action")
        let secondEvent = probe.sentEvents[2]
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
        let transport = NostrTransport(keychain: keychain, idBridge: idBridge)
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
        let transport = NostrTransport(keychain: keychain, idBridge: idBridge)
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
        currentIdentity: @escaping @MainActor () throws -> NostrIdentity? = { nil },
        registerPendingPrivateEnvelope: @escaping @MainActor (String) -> Void = { _ in },
        sendPrivateEnvelopeBatch: @escaping @MainActor (
            [NostrEvent],
            @escaping @MainActor () -> Void
        ) -> Bool = { _, _ in true },
        scheduleAfter: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void = { _, _ in },
        relayConnectivity: @escaping @MainActor () -> AnyPublisher<Bool, Never> = { Just(false).eraseToAnyPublisher() },
        envelopeRetryQueue: NostrPrivateEnvelopeRetryQueue? = nil
    ) -> NostrTransport.Dependencies {
        NostrTransport.Dependencies(
            notificationCenter: notificationCenter,
            loadFavorites: loadFavorites,
            favoriteStatusForNoiseKey: favoriteStatusForNoiseKey,
            favoriteStatusForPeerID: favoriteStatusForPeerID,
            currentIdentity: currentIdentity,
            registerPendingPrivateEnvelope: registerPendingPrivateEnvelope,
            sendPrivateEnvelopeBatch: sendPrivateEnvelopeBatch,
            scheduleAfter: scheduleAfter,
            relayConnectivity: relayConnectivity,
            envelopeRetryQueue: envelopeRetryQueue
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

    private func decodeEmbeddedPayload(
        from event: NostrEvent,
        recipient: NostrIdentity
    ) throws -> (packet: BitchatPacket, payload: NoisePayload, senderPubkey: String) {
        let (content, senderPubkey, _) = try NostrProtocol.decryptPrivateEnvelope(
            envelope: event,
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
}

private enum NostrTransportTestError: Error {
    case invalidEmbeddedContent
    case invalidPacket
    case invalidPrivateMessage
}

@MainActor
private final class NostrTransportEventProbe: TransportEventDelegate {
    private(set) var failedMessageIDs: [String] = []

    func didReceiveTransportEvent(_ event: TransportEvent) {
        guard case .messageDeliveryStatusUpdated(let messageID, let status) = event,
              case .failed = status else { return }
        failedMessageIDs.append(messageID)
    }
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
    private var pendingPrivateEnvelopeIDsStorage: [String] = []
    private var scheduledActionsStorage: [(@Sendable () -> Void)] = []

    var sentEvents: [NostrEvent] {
        lock.lock()
        defer { lock.unlock() }
        return sentEventsStorage
    }

    var pendingPrivateEnvelopeIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return pendingPrivateEnvelopeIDsStorage
    }

    var scheduledActionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return scheduledActionsStorage.count
    }

    func record(batch: [NostrEvent]) -> Bool {
        lock.lock()
        sentEventsStorage.append(contentsOf: batch)
        lock.unlock()
        return true
    }

    func recordPendingPrivateEnvelope(id: String) {
        lock.lock()
        pendingPrivateEnvelopeIDsStorage.append(id)
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

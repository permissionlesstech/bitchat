//
// MessageRouterTests.swift
// bitchatTests
//
// Tests for MessageRouter transport selection and outbox behavior.
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

struct MessageRouterTests {

    @Test @MainActor
    func sendPrivate_usesReachableTransport() async {
        let peerID = PeerID(str: "0000000000000001")
        let transportA = MockTransport()
        let transportB = MockTransport()
        transportB.reachablePeers.insert(peerID)

        let router = MessageRouter(transports: [transportA, transportB])
        router.sendPrivate("Hello", to: peerID, recipientNickname: "Peer", messageID: "m1")

        #expect(transportA.sentPrivateMessages.isEmpty)
        #expect(transportB.sentPrivateMessages.count == 1)
    }

    @Test @MainActor
    func sendPrivate_queuesThenFlushesWhenReachable() async {
        let peerID = PeerID(str: "0000000000000002")
        let transport = MockTransport()

        let router = MessageRouter(transports: [transport])
        router.sendPrivate("Queued", to: peerID, recipientNickname: "Peer", messageID: "m2")

        #expect(transport.sentPrivateMessages.isEmpty)

        transport.reachablePeers.insert(peerID)
        router.flushOutbox(for: peerID)

        #expect(transport.sentPrivateMessages.count == 1)
    }

    @Test @MainActor
    func sendPrivate_prefersConnectedTransportOverEarlierReachableOne() async {
        let peerID = PeerID(str: "0000000000000005")
        let reachableOnly = MockTransport()
        reachableOnly.reachablePeers.insert(peerID)
        let connected = MockTransport()
        connected.connectedPeers.insert(peerID)
        connected.reachablePeers.insert(peerID)

        let router = MessageRouter(transports: [reachableOnly, connected])
        router.sendPrivate("Hello", to: peerID, recipientNickname: "Peer", messageID: "m5")

        #expect(reachableOnly.sentPrivateMessages.isEmpty)
        #expect(connected.sentPrivateMessages.count == 1)
    }

    @Test @MainActor
    func sendPrivate_reachableOnlySendRetainsUntilDeliveryAck() async {
        let peerID = PeerID(str: "0000000000000006")
        let transport = MockTransport()
        transport.reachablePeers.insert(peerID)

        let router = MessageRouter(transports: [transport])
        router.sendPrivate("Hello", to: peerID, recipientNickname: "Peer", messageID: "m6")
        #expect(transport.sentPrivateMessages.count == 1)

        // No ack yet: a flush retries over the weak signal.
        router.flushOutbox(for: peerID)
        #expect(transport.sentPrivateMessages.count == 2)

        // Ack clears the retained copy; later flushes stop resending.
        router.markDelivered("m6")
        router.flushOutbox(for: peerID)
        #expect(transport.sentPrivateMessages.count == 2)
    }

    @Test @MainActor
    func sendPrivate_connectedSendIsNotRetained() async {
        let peerID = PeerID(str: "0000000000000007")
        let transport = MockTransport()
        transport.connectedPeers.insert(peerID)
        transport.reachablePeers.insert(peerID)

        let router = MessageRouter(transports: [transport])
        router.sendPrivate("Hello", to: peerID, recipientNickname: "Peer", messageID: "m7")
        #expect(transport.sentPrivateMessages.count == 1)

        router.flushOutbox(for: peerID)
        #expect(transport.sentPrivateMessages.count == 1)
    }

    @Test @MainActor
    func flushOutbox_dropsUnackedMessageAfterAttemptCap() async {
        let peerID = PeerID(str: "0000000000000008")
        let transport = MockTransport()
        transport.reachablePeers.insert(peerID)

        let router = MessageRouter(transports: [transport])
        router.sendPrivate("Hello", to: peerID, recipientNickname: "Peer", messageID: "m8")

        for _ in 0..<10 {
            router.flushOutbox(for: peerID)
        }

        // Initial send plus capped resends; never unbounded.
        #expect(transport.sentPrivateMessages.count == 8)
    }

    // MARK: - Drop visibility (onMessageDropped)

    @Test @MainActor
    func flushOutbox_attemptCapDropInvokesOnMessageDropped() async {
        let peerID = PeerID(str: "0000000000000009")
        let transport = MockTransport()
        transport.reachablePeers.insert(peerID)

        let router = MessageRouter(transports: [transport])
        var dropped: [(messageID: String, peerID: PeerID)] = []
        router.onMessageDropped = { dropped.append(($0, $1)) }

        router.sendPrivate("Hello", to: peerID, recipientNickname: "Peer", messageID: "m9")
        for _ in 0..<10 {
            router.flushOutbox(for: peerID)
        }

        #expect(dropped.count == 1)
        #expect(dropped.first?.messageID == "m9")
        #expect(dropped.first?.peerID == peerID)
    }

    @Test @MainActor
    func flushOutbox_ttlExpiryInvokesOnMessageDroppedAndDoesNotResend() async {
        let peerID = PeerID(str: "000000000000000a")
        let transport = MockTransport()
        let clock = MutableTestClock()

        let router = MessageRouter(transports: [transport], now: { clock.now })
        var dropped: [String] = []
        router.onMessageDropped = { messageID, _ in dropped.append(messageID) }

        // No reachable transport: the message is queued, never sent.
        router.sendPrivate("Hello", to: peerID, recipientNickname: "Peer", messageID: "m10")
        #expect(transport.sentPrivateMessages.isEmpty)

        // Past the 24h TTL the flush must drop it (visibly), not send it.
        clock.now = clock.now.addingTimeInterval(24 * 60 * 60 + 1)
        transport.reachablePeers.insert(peerID)
        router.flushOutbox(for: peerID)

        #expect(dropped == ["m10"])
        #expect(transport.sentPrivateMessages.isEmpty)

        // The drop is final: nothing is retained for later flushes.
        router.flushOutbox(for: peerID)
        #expect(dropped == ["m10"])
    }

    @Test @MainActor
    func cleanupExpiredMessages_invokesOnMessageDroppedForExpiredOnly() async {
        let peerID = PeerID(str: "000000000000000b")
        let transport = MockTransport()
        let clock = MutableTestClock()

        let router = MessageRouter(transports: [transport], now: { clock.now })
        var dropped: [String] = []
        router.onMessageDropped = { messageID, _ in dropped.append(messageID) }

        router.sendPrivate("Old", to: peerID, recipientNickname: "Peer", messageID: "m11-old")
        clock.now = clock.now.addingTimeInterval(24 * 60 * 60 - 60)
        router.sendPrivate("Fresh", to: peerID, recipientNickname: "Peer", messageID: "m11-fresh")
        clock.now = clock.now.addingTimeInterval(120)

        router.cleanupExpiredMessages()

        #expect(dropped == ["m11-old"])

        // The fresh message survived and still flushes once reachable.
        transport.reachablePeers.insert(peerID)
        router.flushOutbox(for: peerID)
        #expect(transport.sentPrivateMessages.map(\.messageID) == ["m11-fresh"])
    }

    @Test @MainActor
    func enqueue_perPeerOverflowEvictionInvokesOnMessageDropped() async {
        let peerID = PeerID(str: "000000000000000c")
        let transport = MockTransport()

        let router = MessageRouter(transports: [transport])
        var dropped: [String] = []
        router.onMessageDropped = { messageID, _ in dropped.append(messageID) }

        // No reachable transport: everything queues. The cap is 100 per peer,
        // so the 101st enqueue evicts the oldest.
        for i in 0...100 {
            router.sendPrivate("Hello \(i)", to: peerID, recipientNickname: "Peer", messageID: "q\(i)")
        }

        #expect(dropped == ["q0"])
    }

    @Test @MainActor
    func sendReadReceipt_usesReachableTransport() async {
        let peerID = PeerID(str: "0000000000000003")
        let transport = MockTransport()
        transport.reachablePeers.insert(peerID)

        let router = MessageRouter(transports: [transport])
        let receipt = ReadReceipt(originalMessageID: "m3", readerID: transport.myPeerID, readerNickname: "Me")
        router.sendReadReceipt(receipt, to: peerID)

        #expect(transport.sentReadReceipts.count == 1)
    }

    @Test @MainActor
    func sendFavoriteNotification_usesConnectedOrReachable() async {
        let peerID = PeerID(str: "0000000000000004")
        let transport = MockTransport()
        transport.reachablePeers.insert(peerID)

        let router = MessageRouter(transports: [transport])
        router.sendFavoriteNotification(to: peerID, isFavorite: true)

        #expect(transport.sentFavoriteNotifications.count == 1)
    }

    // MARK: - Courier deposits

    private static func snapshot(_ peerID: PeerID, key: Data, verified: Bool) -> TransportPeerSnapshot {
        TransportPeerSnapshot(
            peerID: peerID,
            nickname: "peer",
            isConnected: true,
            noisePublicKey: key,
            lastSeen: Date(),
            isVerified: verified
        )
    }

    /// Directory that resolves one offline recipient and treats a fixed key
    /// set as mutual favorites.
    private static func directory(recipient: PeerID, recipientKey: Data, favoriteKeys: Set<Data> = []) -> CourierDirectory {
        CourierDirectory(
            noiseKey: { peerID in peerID == recipient ? recipientKey : nil },
            isTrustedCourier: { favoriteKeys.contains($0) }
        )
    }

    @Test @MainActor
    func sendPrivate_depositsWithVerifiedStrangerWhenNoFavoriteAround() async {
        let recipient = PeerID(str: "00000000000000aa")
        let recipientKey = Data(repeating: 0xBB, count: 32)
        let courier = PeerID(str: "00000000000000cc")
        let courierKey = Data(repeating: 0xCC, count: 32)

        let transport = MockTransport()
        transport.connectedPeers.insert(courier)
        transport.updatePeerSnapshots([Self.snapshot(courier, key: courierKey, verified: true)])

        let router = MessageRouter(
            transports: [transport],
            courierDirectory: Self.directory(recipient: recipient, recipientKey: recipientKey)
        )
        router.sendPrivate("Hello", to: recipient, recipientNickname: "Peer", messageID: "cv1")

        #expect(transport.sentCourierMessages.count == 1)
        #expect(transport.sentCourierMessages.first?.couriers == [courier])
    }

    @Test @MainActor
    func sendPrivate_neverDepositsWithUnverifiedStranger() async {
        let recipient = PeerID(str: "00000000000000aa")
        let courier = PeerID(str: "00000000000000cc")

        let transport = MockTransport()
        transport.connectedPeers.insert(courier)
        transport.updatePeerSnapshots([Self.snapshot(courier, key: Data(repeating: 0xCC, count: 32), verified: false)])

        let router = MessageRouter(
            transports: [transport],
            courierDirectory: Self.directory(recipient: recipient, recipientKey: Data(repeating: 0xBB, count: 32))
        )
        router.sendPrivate("Hello", to: recipient, recipientNickname: "Peer", messageID: "cv2")

        #expect(transport.sentCourierMessages.isEmpty)
    }

    @Test @MainActor
    func sendPrivate_prefersFavoriteCouriersOverVerifiedOnes() async {
        let recipient = PeerID(str: "00000000000000aa")
        let recipientKey = Data(repeating: 0xBB, count: 32)
        let favorite = PeerID(str: "00000000000000f0")
        let favoriteKey = Data(repeating: 0xF0, count: 32)
        var snapshots = [Self.snapshot(favorite, key: favoriteKey, verified: false)]
        let transport = MockTransport()
        transport.connectedPeers.insert(favorite)
        // Three verified strangers compete for the three courier slots.
        for byte: UInt8 in [0xC1, 0xC2, 0xC3] {
            let peer = PeerID(str: String(format: "00000000000000%02x", byte))
            transport.connectedPeers.insert(peer)
            snapshots.append(Self.snapshot(peer, key: Data(repeating: byte, count: 32), verified: true))
        }
        transport.updatePeerSnapshots(snapshots)

        let router = MessageRouter(
            transports: [transport],
            courierDirectory: Self.directory(recipient: recipient, recipientKey: recipientKey, favoriteKeys: [favoriteKey])
        )
        router.sendPrivate("Hello", to: recipient, recipientNickname: "Peer", messageID: "cv3")

        let couriers = transport.sentCourierMessages.first?.couriers ?? []
        #expect(couriers.count == 3)
        #expect(couriers.contains(favorite))
    }

    /// Residual gap after the rotation-heal containment: a replayed "direct"
    /// announce (TTL is unsigned) can bind an absent victim's peer ID to the
    /// replayer's link, leaving the victim "connected" on a link whose Noise
    /// handshake can never complete. The connected fast-path must not trust
    /// that outright: the send still goes out (a genuine link finishes the
    /// handshake), but a copy is retained and a sealed copy goes to couriers
    /// so nothing is silently lost.
    @Test @MainActor
    func sendPrivate_connectedWithoutSecureSessionRetainsAndDepositsWithCourier() async {
        let victim = PeerID(str: "00000000000000aa")
        let victimKey = Data(repeating: 0xBB, count: 32)
        let courier = PeerID(str: "00000000000000cc")
        let courierKey = Data(repeating: 0xCC, count: 32)

        let transport = MockTransport()
        transport.connectedPeers.insert(victim)
        transport.connectedPeers.insert(courier)
        transport.securePeers = [] // no established Noise session with anyone
        transport.updatePeerSnapshots([Self.snapshot(courier, key: courierKey, verified: true)])

        let router = MessageRouter(
            transports: [transport],
            courierDirectory: Self.directory(recipient: victim, recipientKey: victimKey)
        )
        router.sendPrivate("Hello", to: victim, recipientNickname: "Peer", messageID: "cs1")

        // The send is still attempted (it kicks the handshake on a genuine
        // link) but not trusted outright: a courier gets a sealed copy now …
        #expect(transport.sentPrivateMessages.map(\.messageID) == ["cs1"])
        #expect(transport.sentCourierMessages.count == 1)
        #expect(transport.sentCourierMessages.first?.messageID == "cs1")
        #expect(transport.sentCourierMessages.first?.recipientNoiseKey == victimKey)
        #expect(transport.sentCourierMessages.first?.couriers == [courier])

        // … and the retained copy keeps flushing until a delivery ack — a
        // flush over the insecure link must resend without dropping it.
        router.flushOutbox(for: victim)
        router.flushOutbox(for: victim)
        #expect(transport.sentPrivateMessages.count == 3)
        router.markDelivered("cs1")
        router.flushOutbox(for: victim)
        #expect(transport.sentPrivateMessages.count == 3)
    }

    /// Flushes over a connected-but-insecure link never count toward the
    /// attempt-cap drop: the message was actually transmitted over a live
    /// link, so a peer whose Noise handshake stalls across reconnect flapping
    /// must not burn through the cap and lose the store-and-forward copy the
    /// secure-session gate exists to preserve. Retention stays bounded by
    /// the 24h outbox TTL and the per-peer FIFO cap; an ack clears it.
    @Test @MainActor
    func flushOutbox_connectedInsecureFlushesNeverDropTheRetainedCopy() async {
        let peerID = PeerID(str: "00000000000000ac")
        let transport = MockTransport()
        transport.connectedPeers.insert(peerID)
        transport.securePeers = [] // handshake never completes

        let router = MessageRouter(transports: [transport])
        var dropped: [String] = []
        router.onMessageDropped = { messageID, _ in dropped.append(messageID) }

        router.sendPrivate("Hello", to: peerID, recipientNickname: "Peer", messageID: "ci1")

        // Well past maxSendAttempts (8): every flush resends, none drops.
        for _ in 0..<10 {
            router.flushOutbox(for: peerID)
        }
        #expect(dropped.isEmpty)
        #expect(transport.sentPrivateMessages.count == 11)

        // The copy is still retained and an ack still clears it.
        router.markDelivered("ci1")
        router.flushOutbox(for: peerID)
        #expect(transport.sentPrivateMessages.count == 11)
    }

    /// With an established secure session the connected fast-path stays
    /// exactly as before: trusted outright, no retained copy, no courier.
    @Test @MainActor
    func sendPrivate_connectedWithSecureSessionIsTrustedOutright() async {
        let peerID = PeerID(str: "00000000000000ab")
        let peerKey = Data(repeating: 0xAB, count: 32)
        let courier = PeerID(str: "00000000000000cc")

        let transport = MockTransport()
        transport.connectedPeers.insert(peerID)
        transport.connectedPeers.insert(courier)
        transport.securePeers = [peerID]
        transport.updatePeerSnapshots([Self.snapshot(courier, key: Data(repeating: 0xCC, count: 32), verified: true)])

        let router = MessageRouter(
            transports: [transport],
            courierDirectory: Self.directory(recipient: peerID, recipientKey: peerKey)
        )
        router.sendPrivate("Hello", to: peerID, recipientNickname: "Peer", messageID: "cs2")

        #expect(transport.sentPrivateMessages.map(\.messageID) == ["cs2"])
        #expect(transport.sentCourierMessages.isEmpty)
        router.flushOutbox(for: peerID)
        #expect(transport.sentPrivateMessages.count == 1)
    }

    @Test @MainActor
    func courierBecameAvailable_retriesDepositOnceWithoutDoubleBurn() async {
        let recipient = PeerID(str: "00000000000000aa")
        let recipientKey = Data(repeating: 0xBB, count: 32)
        let courier = PeerID(str: "00000000000000cc")
        let courierKey = Data(repeating: 0xCC, count: 32)

        let transport = MockTransport()
        let router = MessageRouter(
            transports: [transport],
            courierDirectory: Self.directory(recipient: recipient, recipientKey: recipientKey)
        )
        // Nobody around at send time: the message just queues.
        router.sendPrivate("Hello", to: recipient, recipientNickname: "Peer", messageID: "cr1")
        #expect(transport.sentCourierMessages.isEmpty)

        // A verified courier appears later: the deposit retries.
        transport.connectedPeers.insert(courier)
        transport.updatePeerSnapshots([Self.snapshot(courier, key: courierKey, verified: true)])
        router.courierBecameAvailable(courier)
        #expect(transport.sentCourierMessages.count == 1)
        #expect(transport.sentCourierMessages.first?.couriers == [courier])

        // The same courier reconnecting does not receive the same mail twice.
        router.courierBecameAvailable(courier)
        #expect(transport.sentCourierMessages.count == 1)
    }

    @Test @MainActor
    func enqueueReplacementCarriesOverDepositedCourierKeys() async {
        // Re-sending a queued message ID replaces the outbox entry; the
        // replacement must inherit which couriers already carry the message,
        // or the deposit retry re-burns the same courier slots (duplicate
        // sealed copies to the same peer).
        let recipient = PeerID(str: "00000000000000aa")
        let recipientKey = Data(repeating: 0xBB, count: 32)
        let courier = PeerID(str: "00000000000000cc")
        let courierKey = Data(repeating: 0xCC, count: 32)

        let transport = MockTransport()
        transport.connectedPeers.insert(courier)
        transport.updatePeerSnapshots([Self.snapshot(courier, key: courierKey, verified: true)])

        let router = MessageRouter(
            transports: [transport],
            courierDirectory: Self.directory(recipient: recipient, recipientKey: recipientKey)
        )
        router.sendPrivate("Hello", to: recipient, recipientNickname: "Peer", messageID: "ck1")
        #expect(transport.sentCourierMessages.count == 1)

        // Same message ID re-sent (e.g. a resend while still queued): the
        // courier already carrying it must not receive a second copy.
        router.sendPrivate("Hello", to: recipient, recipientNickname: "Peer", messageID: "ck1")
        #expect(transport.sentCourierMessages.count == 1)
    }

    @Test @MainActor
    func courierBecameAvailable_ignoresTheRecipientThemselves() async {
        let recipient = PeerID(str: "00000000000000aa")
        let recipientKey = Data(repeating: 0xBB, count: 32)

        let transport = MockTransport()
        let router = MessageRouter(
            transports: [transport],
            courierDirectory: Self.directory(recipient: recipient, recipientKey: recipientKey)
        )
        router.sendPrivate("Hello", to: recipient, recipientNickname: "Peer", messageID: "cr2")

        // The recipient connecting is a flush, not a courier opportunity.
        transport.connectedPeers.insert(recipient)
        transport.updatePeerSnapshots([Self.snapshot(recipient, key: recipientKey, verified: true)])
        router.courierBecameAvailable(recipient)
        #expect(transport.sentCourierMessages.isEmpty)
    }

    @Test @MainActor
    func bridgeDepositCarriesOnlyAfterConfirmedSendAndRetriesFailure() async {
        let recipient = PeerID(str: "00000000000000ba")
        let recipientKey = Data(repeating: 0xBA, count: 32)
        let transport = MockTransport()
        let router = MessageRouter(
            transports: [transport],
            courierDirectory: Self.directory(recipient: recipient, recipientKey: recipientKey)
        )
        var completions: [@MainActor (Bool) -> Void] = []
        router.bridgeCourierDeposit = { _, _, _, completion in
            completions.append(completion)
        }
        var carried: [String] = []
        router.onMessageCarried = { messageID, _ in carried.append(messageID) }

        router.sendPrivate("Hello", to: recipient, recipientNickname: "Peer", messageID: "bridge-ack")
        #expect(completions.count == 1)
        #expect(carried.isEmpty)

        // Sweeps while the WebSocket write is pending must not duplicate it.
        router.retryBridgeCourierDeposits()
        #expect(completions.count == 1)

        completions.removeFirst()(false)
        #expect(carried.isEmpty)

        // A failed socket write releases the in-flight slot for a real retry.
        router.retryBridgeCourierDeposits()
        #expect(completions.count == 1)
        completions.removeFirst()(true)
        #expect(carried == ["bridge-ack"])
    }

    // MARK: - Outbox persistence

    @Test @MainActor
    func queuedMessagesSurviveRouterRestart() async {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("router-outbox-\(UUID().uuidString).sealed")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let keychain = MockKeychain()
        let peerID = PeerID(str: "00000000000000dd")

        let transport = MockTransport()
        let router = MessageRouter(
            transports: [transport],
            outboxStore: MessageOutboxStore(keychain: keychain, fileURL: fileURL)
        )
        router.sendPrivate("Survive", to: peerID, recipientNickname: "Peer", messageID: "p1")
        #expect(transport.sentPrivateMessages.isEmpty)

        // "App restart": a fresh router over the same store, peer now around.
        let transport2 = MockTransport()
        transport2.reachablePeers.insert(peerID)
        let router2 = MessageRouter(
            transports: [transport2],
            outboxStore: MessageOutboxStore(keychain: keychain, fileURL: fileURL)
        )
        router2.flushOutbox(for: peerID)
        #expect(transport2.sentPrivateMessages.map(\.messageID) == ["p1"])
    }

    @Test @MainActor
    func deliveredMessagesDoNotResurrectAfterRestart() async {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("router-outbox-\(UUID().uuidString).sealed")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let keychain = MockKeychain()
        let peerID = PeerID(str: "00000000000000de")

        let transport = MockTransport()
        let router = MessageRouter(
            transports: [transport],
            outboxStore: MessageOutboxStore(keychain: keychain, fileURL: fileURL)
        )
        router.sendPrivate("Once", to: peerID, recipientNickname: "Peer", messageID: "p2")
        router.markDelivered("p2")

        let transport2 = MockTransport()
        transport2.reachablePeers.insert(peerID)
        let router2 = MessageRouter(
            transports: [transport2],
            outboxStore: MessageOutboxStore(keychain: keychain, fileURL: fileURL)
        )
        router2.flushOutbox(for: peerID)
        #expect(transport2.sentPrivateMessages.isEmpty)
    }

    @Test @MainActor
    func protectedDataRecoveryMergesDurableAndLockedWakeMessagesIntoRouter() async {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("router-protected-data-\(UUID().uuidString).sealed")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let keychain = MockKeychain()
        let peerID = PeerID(str: "00000000000000df")

        let durable = MessageOutboxStore.QueuedMessage(
            content: "Before reboot",
            nickname: "Peer",
            messageID: "durable",
            timestamp: Date()
        )
        MessageOutboxStore(keychain: keychain, fileURL: fileURL).save([peerID: [durable]])

        var protectedDataUnavailable = true
        let restoredStore = MessageOutboxStore(
            keychain: keychain,
            fileURL: fileURL,
            readData: { url in
                if protectedDataUnavailable {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
                }
                return try Data(contentsOf: url)
            }
        )
        let transport = MockTransport()
        let router = MessageRouter(transports: [transport], outboxStore: restoredStore)
        router.sendPrivate("During wake", to: peerID, recipientNickname: "Peer", messageID: "wake")

        transport.reachablePeers.insert(peerID)
        protectedDataUnavailable = false
        restoredStore.retryDeferredLoad()
        // Recovery is delivered to the main actor without blocking the
        // protected-data notification callback.
        await Task.yield()
        await Task.yield()

        #expect(Set(transport.sentPrivateMessages.map(\.messageID)) == ["durable", "wake"])
    }

    @Test @MainActor
    func ackWhileColdLoadIsLockedDoesNotResurrectUnseenDurableMessage() async {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("router-locked-ack-\(UUID().uuidString).sealed")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let keychain = MockKeychain()
        let peerID = PeerID(str: "00000000000000e0")
        let durable = MessageOutboxStore.QueuedMessage(
            content: "Already delivered",
            nickname: "Peer",
            messageID: "acked-while-locked",
            timestamp: Date()
        )
        MessageOutboxStore(keychain: keychain, fileURL: fileURL).save([peerID: [durable]])

        var protectedDataUnavailable = true
        let restoredStore = MessageOutboxStore(
            keychain: keychain,
            fileURL: fileURL,
            readData: { url in
                if protectedDataUnavailable {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
                }
                return try Data(contentsOf: url)
            }
        )
        let transport = MockTransport()
        transport.reachablePeers.insert(peerID)
        let router = MessageRouter(transports: [transport], outboxStore: restoredStore)

        // The router's locked cold-load view is empty, but the ack still has
        // to suppress the durable message hidden on disk.
        router.markDelivered("acked-while-locked")
        protectedDataUnavailable = false
        restoredStore.retryDeferredLoad()
        await Task.yield()
        await Task.yield()

        #expect(transport.sentPrivateMessages.isEmpty)
        #expect(MessageOutboxStore(keychain: keychain, fileURL: fileURL).load().isEmpty)
    }

    @Test @MainActor
    func ackAfterRecoveryCaptureBeforeMainActorMergeCannotResurrectMessage() async {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("router-recovery-gap-ack-\(UUID().uuidString).sealed")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let keychain = MockKeychain()
        let peerID = PeerID(str: "00000000000000e1")
        let durable = MessageOutboxStore.QueuedMessage(
            content: "Captured then acked",
            nickname: "Peer",
            messageID: "recovery-gap-ack",
            timestamp: Date()
        )
        MessageOutboxStore(keychain: keychain, fileURL: fileURL).save([peerID: [durable]])

        var protectedDataUnavailable = true
        let restoredStore = MessageOutboxStore(
            keychain: keychain,
            fileURL: fileURL,
            readData: { url in
                if protectedDataUnavailable {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
                }
                return try Data(contentsOf: url)
            }
        )
        let transport = MockTransport()
        transport.reachablePeers.insert(peerID)
        let router = MessageRouter(transports: [transport], outboxStore: restoredStore)

        protectedDataUnavailable = false
        restoredStore.retryDeferredLoad() // captures recovery and queues MainActor merge
        router.markDelivered("recovery-gap-ack") // runs before that queued Task
        await Task.yield()
        await Task.yield()

        #expect(transport.sentPrivateMessages.isEmpty)
        #expect(MessageOutboxStore(keychain: keychain, fileURL: fileURL).load().isEmpty)
    }

    @Test @MainActor
    func enqueueAfterRecoveryCapturePreservesUnseenDurableAndNewMessages() async {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("router-recovery-gap-enqueue-\(UUID().uuidString).sealed")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let keychain = MockKeychain()
        let peerID = PeerID(str: "00000000000000e2")
        let durable = MessageOutboxStore.QueuedMessage(
            content: "Before unlock",
            nickname: "Peer",
            messageID: "recovery-gap-durable",
            timestamp: Date()
        )
        MessageOutboxStore(keychain: keychain, fileURL: fileURL).save([peerID: [durable]])

        var protectedDataUnavailable = true
        let restoredStore = MessageOutboxStore(
            keychain: keychain,
            fileURL: fileURL,
            readData: { url in
                if protectedDataUnavailable {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
                }
                return try Data(contentsOf: url)
            }
        )
        let transport = MockTransport()
        let router = MessageRouter(transports: [transport], outboxStore: restoredStore)

        protectedDataUnavailable = false
        restoredStore.retryDeferredLoad() // queues merge of the durable message
        router.sendPrivate("During gap", to: peerID, recipientNickname: "Peer", messageID: "recovery-gap-new")
        transport.reachablePeers.insert(peerID)
        await Task.yield()
        await Task.yield()

        #expect(Set(transport.sentPrivateMessages.map(\.messageID)) == ["recovery-gap-durable", "recovery-gap-new"])
        let relaunched = MessageOutboxStore(keychain: keychain, fileURL: fileURL).load()
        #expect(Set(relaunched[peerID]?.map(\.messageID) ?? []) == ["recovery-gap-durable", "recovery-gap-new"])
    }

    @Test @MainActor
    func removingKnownWakeMessageInRecoveryGapPreservesOnlyUnseenDurableState() async {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("router-recovery-gap-known-removal-\(UUID().uuidString).sealed")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let keychain = MockKeychain()
        let peerID = PeerID(str: "00000000000000e3")
        let durable = MessageOutboxStore.QueuedMessage(
            content: "Unseen durable",
            nickname: "Peer",
            messageID: "recovery-gap-unseen",
            timestamp: Date()
        )
        MessageOutboxStore(keychain: keychain, fileURL: fileURL).save([peerID: [durable]])

        var protectedDataUnavailable = true
        let restoredStore = MessageOutboxStore(
            keychain: keychain,
            fileURL: fileURL,
            readData: { url in
                if protectedDataUnavailable {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
                }
                return try Data(contentsOf: url)
            }
        )
        let transport = MockTransport()
        let router = MessageRouter(transports: [transport], outboxStore: restoredStore)
        router.sendPrivate("Known wake", to: peerID, recipientNickname: "Peer", messageID: "recovery-gap-known")

        protectedDataUnavailable = false
        restoredStore.retryDeferredLoad() // captures unseen durable + known wake

        // Secure direct flush removes the wake message before recovery's
        // MainActor merge. It must remain removed, while the unseen durable
        // message still arrives through the pending recovery claim.
        transport.connectedPeers.insert(peerID)
        transport.securePeers = [peerID]
        router.flushOutbox(for: peerID)
        await Task.yield()
        await Task.yield()

        let sentIDs = transport.sentPrivateMessages.map(\.messageID)
        #expect(sentIDs.filter { $0 == "recovery-gap-known" }.count == 1)
        #expect(sentIDs.filter { $0 == "recovery-gap-unseen" }.count == 1)
    }

    @Test @MainActor
    func failedRecoveryWriteStillPreservesUnseenDurableStateAcrossGapRemoval() async {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("router-recovery-write-failure-\(UUID().uuidString).sealed")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let keychain = MockKeychain()
        let peerID = PeerID(str: "00000000000000e4")
        let durable = MessageOutboxStore.QueuedMessage(
            content: "Unseen before unlock",
            nickname: "Peer",
            messageID: "recovery-write-failure-unseen",
            timestamp: Date()
        )
        MessageOutboxStore(keychain: keychain, fileURL: fileURL).save([peerID: [durable]])

        var protectedDataUnavailable = true
        var failWrites = false
        var injectedFailureCount = 0
        let restoredStore = MessageOutboxStore(
            keychain: keychain,
            fileURL: fileURL,
            readData: { url in
                if protectedDataUnavailable {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
                }
                return try Data(contentsOf: url)
            },
            writeData: { data, url, options in
                if failWrites {
                    injectedFailureCount += 1
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
                }
                try data.write(to: url, options: options)
            }
        )
        let transport = MockTransport()
        let router = MessageRouter(transports: [transport], outboxStore: restoredStore)
        router.sendPrivate(
            "Known wake",
            to: peerID,
            recipientNickname: "Peer",
            messageID: "recovery-write-failure-known"
        )

        // The first post-unlock save reads durable D and knows router state W,
        // but its D+W write fails. A later retry must retain the original
        // unseen-D classification instead of mistaking the cached union for
        // a fully router-known snapshot.
        protectedDataUnavailable = false
        failWrites = true
        router.sendPrivate(
            "Known wake",
            to: peerID,
            recipientNickname: "Peer",
            messageID: "recovery-write-failure-known"
        )
        failWrites = false
        #expect(injectedFailureCount == 1)

        restoredStore.retryDeferredLoad() // persists D+W and queues recovery
        transport.connectedPeers.insert(peerID)
        transport.securePeers = [peerID]
        router.flushOutbox(for: peerID) // removes W before queued callback

        // The gap save may remove W, but it must leave unseen D durable until
        // MessageRouter receives the pending recovery callback.
        let gapSnapshot = MessageOutboxStore(keychain: keychain, fileURL: fileURL).load()
        #expect(gapSnapshot[peerID]?.map(\.messageID) == ["recovery-write-failure-unseen"])

        await Task.yield()
        await Task.yield()

        let sentIDs = transport.sentPrivateMessages.map(\.messageID)
        #expect(sentIDs.filter { $0 == "recovery-write-failure-known" }.count == 1)
        #expect(sentIDs.filter { $0 == "recovery-write-failure-unseen" }.count == 1)
    }
}

/// Mutable wall clock injected into `MessageRouter` so TTL expiry is testable
/// without real waiting.
private final class MutableTestClock {
    var now = Date(timeIntervalSince1970: 1_700_000_000)
}

import BitFoundation
import Foundation
import Testing
@testable import bitchat

@Suite(.serialized)
struct BLEReceiptRoutingTests {
    @Test(arguments: [false, true], [false, true])
    func establishedSessionDeliversReceipt(fullKey: Bool, readReceipt: Bool) async throws {
        let (mesh, a, b) = await onReceiptMeshQueue {
            let mesh = makeSerializedReceiptMesh()
            let a = mesh.addNode(nickname: "receipt-alpha")
            let b = mesh.addNode(nickname: "receipt-beta")
            mesh.connect(0, 1)
            mesh.announceAll()
            mesh.settleUntil {
                a.service.canDeliverSecurely(to: b.service.myPeerID)
                    && b.service.canDeliverSecurely(to: a.service.myPeerID)
            }
            return (mesh, a, b)
        }
        let full = PeerID(hexData: b.service.noiseStaticPublicKeyData())
        #expect(full.toShort() == b.service.myPeerID)
        let destination = fullKey ? full : b.service.myPeerID
        #expect(a.service.isPeerReachable(destination))
        #expect(a.service.canDeliverSecurely(to: destination))
        let capture = BLEReceiptCapture()
        b.service.eventDelegate = capture
        let id = "synthetic-established-receipt"
        if readReceipt {
            let handedOff = await MainActor.run {
                let router = MessageRouter(transports: [a.service], courierDirectory: CourierDirectory(noiseKey: { _ in nil }, isTrustedCourier: { _ in false }))
                return router.sendReadReceipt(ReadReceipt(originalMessageID: id, readerID: a.service.myPeerID, readerNickname: "receipt-alpha"), to: destination)
            }
            #expect(handedOff)
        } else {
            a.service.sendDeliveryAck(for: id, to: destination)
        }
        let received = await pumpReceiptMesh(mesh) { capture.contains(id, read: readReceipt, from: a.service.myPeerID) }
        #expect(received, "Receipt must reach the other service through its Noise receive handler")
    }

    @Test(arguments: [false, true])
    func openingStoredChatDeliversReadReceipt(fullKey: Bool) async throws {
        let (mesh, a, b) = await onReceiptMeshQueue {
            let mesh = makeSerializedReceiptMesh()
            let a = mesh.addNode(nickname: "chat-alpha")
            let b = mesh.addNode(nickname: "chat-beta")
            mesh.connect(0, 1)
            mesh.announceAll()
            mesh.settleUntil {
                a.service.canDeliverSecurely(to: b.service.myPeerID)
                    && b.service.canDeliverSecurely(to: a.service.myPeerID)
            }
            return (mesh, a, b)
        }
        let full = PeerID(hexData: b.service.noiseStaticPublicKeyData())
        let destination = fullKey ? full : b.service.myPeerID
        #expect(a.service.isPeerReachable(destination))
        #expect(a.service.canDeliverSecurely(to: destination))
        let capture = BLEReceiptCapture()
        b.service.eventDelegate = capture
        let id = "synthetic-stored-message"
        let (manager, router, store) = await MainActor.run {
            let store = ConversationStore()
            let router = MessageRouter(transports: [a.service], courierDirectory: CourierDirectory(noiseKey: { _ in nil }, isTrustedCourier: { _ in false }))
            let manager = PrivateChatManager(meshService: a.service, conversationStore: store)
            manager.messageRouter = router
            store.append(BitchatMessage(id: id, sender: "chat-beta", content: "synthetic message", timestamp: Date(), isRelay: false, isPrivate: true, recipientNickname: "chat-alpha", senderPeerID: destination), to: .directPeer(destination))
            store.markUnread(.directPeer(destination))
            manager.startChat(with: destination)
            return (manager, router, store)
        }
        let received = await pumpReceiptMesh(mesh) { capture.contains(id, read: true, from: a.service.myPeerID) }
        let claimed = await MainActor.run { manager.sentReadReceipts.contains(id) }
        #expect(claimed)
        #expect(received, "Opening the stored chat must deliver the receipt, not just mark it sent locally")
        withExtendedLifetime((manager, router, store)) {}
    }

    @Test @MainActor
    func courierReceiptUpdatesSenderStatusAfterConnectionAndChatOpen() async throws {
        let (mesh, a, b) = await onReceiptMeshQueue {
            let mesh = makeSerializedReceiptMesh()
            return (mesh, mesh.addNode(nickname: "courier-alpha"), mesh.addNode(nickname: "courier-beta"))
        }
        let sender = makeReceiptViewModel(transport: a.service)
        let receiver = makeReceiptViewModel(transport: b.service)
        let senderFullID = PeerID(hexData: a.service.noiseStaticPublicKeyData())
        let receiverFullID = PeerID(hexData: b.service.noiseStaticPublicKeyData())
        let id = "synthetic-courier-status"
        let content = "synthetic courier message"
        sender.seedPrivateChat([BitchatMessage(
            id: id, sender: sender.nickname, content: content, timestamp: Date(),
            isRelay: false, isPrivate: true, recipientNickname: receiver.nickname,
            senderPeerID: a.service.myPeerID, deliveryStatus: .sent
        )], for: receiverFullID)

        let envelope = try #require(a.service.sealBridgeCourierEnvelope(
            content, messageID: id, recipientNoiseKey: b.service.noiseStaticPublicKeyData()
        ))
        #expect(b.service.openBridgedCourierEnvelope(envelope))
        let stored = await pumpReceiptMesh(mesh) {
            receiver.privateChats[senderFullID]?.contains { $0.id == id && $0.senderPeerID == senderFullID } == true
        }
        try #require(stored, "The courier receive path should store the authenticated sender's full-key identity")
        #expect(!b.service.canDeliverSecurely(to: senderFullID))
        #expect(sender.conversations.deliveryStatus(forMessageID: id) == .sent)

        await onReceiptMeshQueue {
            mesh.connect(0, 1)
            mesh.announceAll()
            mesh.settleUntil {
                a.service.canDeliverSecurely(to: b.service.myPeerID)
                    && b.service.canDeliverSecurely(to: a.service.myPeerID)
            }
        }
        let delivered = await pumpReceiptMesh(mesh) {
            if case .delivered = sender.conversations.deliveryStatus(forMessageID: id) { return true }
            return false
        }
        #expect(delivered, "The queued courier delivery receipt should update the sender's message")

        receiver.startPrivateChat(with: senderFullID)
        let read = await pumpReceiptMesh(mesh) {
            if case .read = sender.conversations.deliveryStatus(forMessageID: id) { return true }
            return false
        }
        #expect(read, "Opening the received conversation should update the sender's message to read")
        withExtendedLifetime((sender, receiver)) {}
    }

    @Test @MainActor
    func unreachableBLEPreservesFullKeyForAlternateTransport() {
        let keychain = MockKeychain()
        let ble = BLEService(
            keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: MockIdentityManager(keychain),
            initializeBluetoothManagers: false
        )
        let fullKey = PeerID(hexData: Data(repeating: 0x42, count: 32))
        let alternate = MockTransport()
        alternate.reachablePeers.insert(fullKey)
        let router = MessageRouter(transports: [ble, alternate])
        let receipt = ReadReceipt(originalMessageID: "alternate-receipt", readerID: ble.myPeerID, readerNickname: "reader")
        #expect(!ble.isPeerReachable(fullKey))
        #expect(router.sendReadReceipt(receipt, to: fullKey))
        #expect(alternate.sentReadReceipts.count == 1)
        #expect(alternate.sentReadReceipts.first?.peerID == fullKey)
    }

    @Test(arguments: [false, true], [false, true])
    func queuedReceiptDrainsAfterHandshake(fullKey: Bool, readReceipt: Bool) async throws {
        let (mesh, a, b) = await onReceiptMeshQueue {
            let mesh = makeSerializedReceiptMesh()
            let a = mesh.addNode(nickname: "queued-alpha")
            let b = mesh.addNode(nickname: "queued-beta")
            return (mesh, a, b)
        }
        let full = PeerID(hexData: b.service.noiseStaticPublicKeyData())
        #expect(full.toShort() == b.service.myPeerID)
        let destination = fullKey ? full : b.service.myPeerID
        #expect(!a.service.canDeliverSecurely(to: destination))
        let capture = BLEReceiptCapture()
        b.service.eventDelegate = capture
        let id = "synthetic-queued-receipt"
        if readReceipt {
            a.service.sendReadReceipt(ReadReceipt(originalMessageID: id, readerID: a.service.myPeerID, readerNickname: "queued-alpha"), to: destination)
        } else {
            a.service.sendDeliveryAck(for: id, to: destination)
        }
        await onReceiptMeshQueue { mesh.pump() }
        #expect(!capture.contains(id, read: readReceipt, from: a.service.myPeerID))
        await onReceiptMeshQueue {
            mesh.connect(0, 1)
            mesh.announceAll()
            mesh.settleUntil {
                a.service.canDeliverSecurely(to: b.service.myPeerID)
                    && b.service.canDeliverSecurely(to: a.service.myPeerID)
            }
        }
        #expect(a.service.canDeliverSecurely(to: destination))
        #expect(b.service.canDeliverSecurely(to: a.service.myPeerID))
        let received = await pumpReceiptMesh(mesh) { capture.contains(id, read: readReceipt, from: a.service.myPeerID) }
        #expect(received, "Queued receipt must drain when the real peer session establishes")
    }
}

private final class BLEReceiptCapture: TransportEventDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var receipts: [(String, Bool, PeerID)] = []
    func didReceiveTransportEvent(_ event: TransportEvent) {
        guard case let .noisePayloadReceived(peerID, type, payload, _) = event,
              type == .readReceipt || type == .delivered,
              let id = String(data: payload, encoding: .utf8) else { return }
        lock.lock()
        receipts.append((id, type == .readReceipt, peerID))
        lock.unlock()
    }
    func contains(_ id: String, read: Bool, from peerID: PeerID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return receipts.contains { $0.0 == id && $0.1 == read && $0.2 == peerID }
    }
}

private func onReceiptMeshQueue<T>(_ operation: @escaping () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: operation())
        }
    }
}

@MainActor
private func pumpReceiptMesh(_ mesh: SimulatedMesh, until condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(TestConstants.settleTimeout)
    repeat {
        // Routing can enqueue after an earlier pump; wait for the observed outcome.
        await onReceiptMeshQueue { mesh.pump() }
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    } while Date() < deadline
    return condition()
}

@MainActor
private func makeReceiptViewModel(transport: BLEService) -> ChatViewModel {
    let keychain = MockKeychain()
    return ChatViewModel(
        keychain: keychain,
        idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
        identityManager: MockIdentityManager(keychain),
        transport: transport
    )
}

private func makeSerializedReceiptMesh() -> SimulatedMesh {
    SimulatedMesh(packetTransform: { packet in
        do {
            let data = try #require(packet.toBinaryData(
                padding: BLEOutboundPacketPolicy.padsBLEFrame(for: packet.type)
            ))
            let decoded: BitchatPacket = try #require(BitchatPacket.from(data))
            return decoded
        } catch {
            return nil
        }
    })
}

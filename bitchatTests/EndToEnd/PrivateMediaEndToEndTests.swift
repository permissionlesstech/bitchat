import BitFoundation
import Combine
import CoreBluetooth
import Foundation
import Testing
@testable import bitchat

/// Wire-level coverage for finalized DM media. The sender encrypts one typed
/// private-file payload, relays see only the outer Noise packet/fragments, and
/// the receiver reassembles, decrypts, validates, persists, and delivers it.
@Suite("Private media end to end", .serialized)
struct PrivateMediaEndToEndTests {
    @Test
    func peerWithoutPrivateMediaCapabilityIsRejectedBeforeWireSend() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-media-capability-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let alice = makeService(baseDirectory: root.appendingPathComponent("alice", isDirectory: true))
        let bob = makeService(baseDirectory: root.appendingPathComponent("bob", isDirectory: true))
        alice._test_seedConnectedPeer(bob.myPeerID, nickname: "Old Bob", capabilities: [])
        bob._test_seedConnectedPeer(alice.myPeerID, nickname: "Alice", capabilities: .privateMedia)
        try establishSession(alice: alice, bob: bob)

        let tap = PacketTap()
        alice._test_onOutboundPacket = tap.record
        let transferID = "unsupported-private-media-\(UUID().uuidString)"
        let cancellation = TransferCancellationRecorder(transferID: transferID)
        let cancellable = TransferProgressManager.shared.publisher.sink { cancellation.record($0) }
        let content = Data("%PDF-1.7\nprivate".utf8)
        alice.sendFilePrivate(
            BitchatFilePacket(
                fileName: "private.pdf",
                fileSize: UInt64(content.count),
                mimeType: "application/pdf",
                content: content
            ),
            to: bob.myPeerID,
            transferId: transferID
        )

        let rejected = await TestHelpers.waitUntil(
            { cancellation.wasCancelled },
            timeout: TestConstants.longTimeout
        )
        #expect(rejected)
        let mediaWireTypes: Set<UInt8> = [
            MessageType.noiseEncrypted.rawValue,
            MessageType.fileTransfer.rawValue,
            MessageType.fragment.rawValue
        ]
        #expect(tap.snapshot().allSatisfy { !mediaWireTypes.contains($0.type) })
        _ = cancellable
    }

    @Test
    func privateJPEGIsOpaqueBeforeFragmentationAndDelivers() async throws {
        let marker = Data("JPEG_PRIVATE_MARKER_7f5e5eacb86f4b9a".utf8)
        let content = Data([0xFF, 0xD8, 0xFF, 0xE0])
            + marker
            + Data(repeating: 0x4A, count: 6 * 1024)
        try await assertPrivateMediaRoundTrip(
            fileName: "private.jpg",
            mimeType: "image/jpeg",
            content: content,
            marker: marker,
            expectedMessagePrefix: "[image]"
        )
    }

    @Test
    func finalizedPrivateM4AIsOpaqueBeforeFragmentationAndDelivers() async throws {
        let marker = Data("M4A_PRIVATE_MARKER_e0cd431b61fb4a6c".utf8)
        let content = Data([0x00, 0x00, 0x00, 0x18])
            + Data("ftypM4A ".utf8)
            + marker
            + Data(repeating: 0x4D, count: 6 * 1024)
        try await assertPrivateMediaRoundTrip(
            fileName: "voice_0011223344556677.m4a",
            mimeType: "audio/mp4",
            content: content,
            marker: marker,
            expectedMessagePrefix: "[voice]"
        )
    }

    @Test
    func privatePDFIsOpaqueBeforeFragmentationAndDelivers() async throws {
        let marker = Data("PDF_PRIVATE_MARKER_b333f84b8fc7478d".utf8)
        let content = Data("%PDF-1.7\n".utf8)
            + marker
            + Data(repeating: 0x50, count: 6 * 1024)
        try await assertPrivateMediaRoundTrip(
            fileName: "private.pdf",
            mimeType: "application/pdf",
            content: content,
            marker: marker,
            expectedMessagePrefix: "[file]"
        )
    }

    @Test
    func privateMediaAboveOrdinaryNoiseLimitUsesV2OuterPacketAndDelivers() async throws {
        let marker = Data("LARGE_PRIVATE_MARKER_1ec63f261a7041ee".utf8)
        let content = Data("%PDF-1.7\n".utf8)
            + marker
            + Data(repeating: 0x4C, count: 70 * 1024)
        try await assertPrivateMediaRoundTrip(
            fileName: "large-private.pdf",
            mimeType: "application/pdf",
            content: content,
            marker: marker,
            expectedMessagePrefix: "[file]",
            expectedOuterVersion: 2
        )
    }

    private func assertPrivateMediaRoundTrip(
        fileName: String,
        mimeType: String,
        content: Data,
        marker: Data,
        expectedMessagePrefix: String,
        expectedOuterVersion: UInt8 = 2
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-media-e2e-\(UUID().uuidString)", isDirectory: true)
        let aliceRoot = root.appendingPathComponent("alice", isDirectory: true)
        let bobRoot = root.appendingPathComponent("bob", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let alice = makeService(baseDirectory: aliceRoot)
        let bob = makeService(baseDirectory: bobRoot)
        let tap = PacketTap()
        let delegate = MessageCaptureDelegate()
        alice._test_onOutboundPacket = tap.record
        bob.delegate = delegate

        alice._test_seedConnectedPeer(bob.myPeerID, nickname: "Bob", capabilities: .privateMedia)
        bob._test_seedConnectedPeer(alice.myPeerID, nickname: "Alice", capabilities: .privateMedia)
        try establishSession(alice: alice, bob: bob)

        let file = BitchatFilePacket(
            fileName: fileName,
            fileSize: UInt64(content.count),
            mimeType: mimeType,
            content: content
        )
        alice.sendFilePrivate(file, to: bob.myPeerID, transferId: "wire-\(UUID().uuidString)")

        let fragmented = await TestHelpers.waitUntil(
            { tap.hasCompleteFragmentTrain },
            timeout: 10
        )
        #expect(fragmented)

        let outbound = tap.snapshot()
        let encryptedPackets = outbound.filter { $0.type == MessageType.noiseEncrypted.rawValue }
        let fragments = outbound
            .filter { $0.type == MessageType.fragment.rawValue }
            .sorted { fragmentIndex($0) < fragmentIndex($1) }

        #expect(encryptedPackets.count == 1)
        #expect(encryptedPackets.first?.version == expectedOuterVersion)
        #expect(!fragments.isEmpty)
        #expect(outbound.allSatisfy { $0.type != MessageType.fileTransfer.rawValue })
        for packet in encryptedPackets + fragments {
            #expect(packet.payload.range(of: marker) == nil)
            #expect(packet.payload.range(of: content) == nil)
        }

        // Real BLE delivers the train at the scheduler's paced interval. Feed
        // bounded batches here instead of enqueuing hundreds of synthetic
        // callbacks at once, which can exhaust libdispatch worker threads as
        // they wait on the fragment-assembly barrier.
        for batchStart in stride(from: 0, to: fragments.count, by: 16) {
            let batchEnd = min(batchStart + 16, fragments.count)
            for fragment in fragments[batchStart..<batchEnd] {
                bob._test_handlePacket(fragment, fromPeerID: alice.myPeerID)
            }
            await bob._test_drainFragmentPipeline()
        }

        let delivered = await TestHelpers.waitUntil(
            { delegate.snapshot().count == 1 },
            timeout: TestConstants.longTimeout
        )
        #expect(delivered)

        let message = try #require(delegate.snapshot().first)
        #expect(message.isPrivate)
        #expect(message.senderPeerID == alice.myPeerID)
        #expect(message.content.hasPrefix(expectedMessagePrefix))

        let stored = recursivelyStoredFiles(under: bobRoot)
        #expect(stored.count == 1)
        let storedURL = try #require(stored.first)
        #expect(try Data(contentsOf: storedURL) == content)
    }

    private func makeService(baseDirectory: URL) -> BLEService {
        let keychain = MockKeychain()
        return BLEService(
            keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: MockIdentityManager(keychain),
            initializeBluetoothManagers: false,
            incomingFileStore: BLEIncomingFileStore(baseDirectory: baseDirectory)
        )
    }

    private func establishSession(alice: BLEService, bob: BLEService) throws {
        let first = try alice._test_noiseInitiateHandshake(with: bob.myPeerID)
        let second = try #require(
            try bob._test_noiseProcessHandshakeMessage(from: alice.myPeerID, message: first)
        )
        let third = try #require(
            try alice._test_noiseProcessHandshakeMessage(from: bob.myPeerID, message: second)
        )
        _ = try bob._test_noiseProcessHandshakeMessage(from: alice.myPeerID, message: third)
        #expect(alice.canDeliverSecurely(to: bob.myPeerID))
        #expect(bob.canDeliverSecurely(to: alice.myPeerID))
    }

    private func recursivelyStoredFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }

        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            return url
        }
    }
}

private func fragmentIndex(_ packet: BitchatPacket) -> Int {
    guard packet.payload.count >= 10 else { return .max }
    return (Int(packet.payload[8]) << 8) | Int(packet.payload[9])
}

private final class PacketTap: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [BitchatPacket] = []

    func record(_ packet: BitchatPacket) {
        lock.lock()
        packets.append(packet)
        lock.unlock()
    }

    func snapshot() -> [BitchatPacket] {
        lock.lock()
        defer { lock.unlock() }
        return packets
    }

    var hasCompleteFragmentTrain: Bool {
        let fragments = snapshot().filter { $0.type == MessageType.fragment.rawValue }
        guard let first = fragments.first, first.payload.count >= 12 else { return false }
        let total = (Int(first.payload[10]) << 8) | Int(first.payload[11])
        return total > 0 && fragments.count >= total
    }
}

private final class MessageCaptureDelegate: BitchatDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [BitchatMessage] = []

    func didReceiveMessage(_ message: BitchatMessage) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    func snapshot() -> [BitchatMessage] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }

    func didConnectToPeer(_ peerID: PeerID) {}
    func didDisconnectFromPeer(_ peerID: PeerID) {}
    func didUpdatePeerList(_ peers: [PeerID]) {}
    func didUpdateBluetoothState(_ state: CBManagerState) {}
}

private final class TransferCancellationRecorder: @unchecked Sendable {
    private let transferID: String
    private let lock = NSLock()
    private var cancelled = false

    init(transferID: String) {
        self.transferID = transferID
    }

    func record(_ event: TransferProgressManager.Event) {
        guard case .cancelled(let id, _, _) = event, id == transferID else { return }
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

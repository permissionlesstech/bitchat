//
// FragmentationTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
import CoreBluetooth
import BitFoundation
@testable import bitchat

@Suite("Fragmentation Tests", .serialized)
struct FragmentationTests {

    @Test("Reassembly from fragments delivers a public message")
    func reassemblyFromFragmentsDeliversPublicMessage() async throws {
        let ble = makeBLEService()
        let capture = CaptureDelegate()
        ble.delegate = capture

        // Construct a big SIGNED public packet (3KB) from a remote sender. Public
        // messages must carry a valid signature, so the reassembled packet is
        // signed and the sender's signing key is preseeded into the registry.
        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let signingKey = signer.getSigningPublicKeyData()
        let remoteShortID = PeerID(str: "1122334455667788")
        let original = try #require(
            signer.signPacket(makeLargePublicPacket(senderShortHex: remoteShortID, size: 3_000)),
            "Failed to sign public packet"
        )

        // Use a small fragment size to ensure multiple pieces
        let fragments = fragmentPacket(original, fragmentSize: 400)

        // Reverse deterministically to simulate out-of-order arrival without
        // making a failure depend on a random permutation.
        let outOfOrder = fragments.reversed()

        for fragment in outOfOrder {
            ble._test_handlePacket(fragment, fromPeerID: remoteShortID, signingPublicKey: signingKey)
        }

        await ble._test_drainFragmentPipeline()

        #expect(capture.publicMessages.count == 1)
        #expect(capture.publicMessages.first?.content.count == 3_000)
    }
    
    @Test("Duplicate fragment does not break reassembly")
    func duplicateFragmentDoesNotBreakReassembly() async throws {
        let ble = makeBLEService()
        let capture = CaptureDelegate()
        ble.delegate = capture

        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let signingKey = signer.getSigningPublicKeyData()
        let remoteShortID = PeerID(str: "A1B2C3D4E5F60708")
        let original = try #require(
            signer.signPacket(makeLargePublicPacket(senderShortHex: remoteShortID, size: 2048)),
            "Failed to sign public packet"
        )
        var frags = fragmentPacket(original, fragmentSize: 300)

        // Duplicate one fragment
        if let dup = frags.first {
            frags.insert(dup, at: 1)
        }

        for fragment in frags {
            ble._test_handlePacket(fragment, fromPeerID: remoteShortID, signingPublicKey: signingKey)
        }

        await ble._test_drainFragmentPipeline()

        #expect(capture.publicMessages.count == 1)
        #expect(capture.publicMessages.first?.content.count == 2048)
    }

    @Test("Max-sized file transfer survives reassembly")
    func maxSizedFileTransferSurvivesReassembly() async throws {
        let ble = makeBLEService()
        let capture = CaptureDelegate()
        ble.delegate = capture

        // Broadcast file transfers must carry a valid sender signature (same
        // gate as public messages), so sign the packet and preseed the
        // sender's signing key into the registry.
        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let signingKey = signer.getSigningPublicKeyData()
        let remoteID = PeerID(str: "CAFEBABECAFEBABE")
        let fileContent = Data(repeating: 0x42, count: FileTransferLimits.maxPayloadBytes)
        let filePacket = BitchatFilePacket(
            fileName: "limit.bin",
            fileSize: UInt64(fileContent.count),
            mimeType: "application/octet-stream",
            content: fileContent
        )
        let encoded = try #require(filePacket.encode(), "File packet encoding failed")

        let packet = try #require(
            signer.signPacket(BitchatPacket(
                type: MessageType.fileTransfer.rawValue,
                senderID: Data(hexString: remoteID.id) ?? Data(),
                recipientID: nil,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: encoded,
                signature: nil,
                ttl: 7,
                version: 2
            )),
            "Failed to sign file transfer packet"
        )

        let fragments = fragmentPacket(packet, fragmentSize: 4096, pad: false)
        #expect(!fragments.isEmpty)

        for fragment in fragments {
            ble._test_handlePacket(fragment, fromPeerID: remoteID, signingPublicKey: signingKey)
        }

        await ble._test_drainFragmentPipeline()

        let message = try #require(capture.receivedMessages.first, "Expected file transfer message")
        #expect(message.content.hasPrefix("[file]"))

        if let fileName = message.content.split(separator: " ").last {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let filesRoot = base.appendingPathComponent("files", isDirectory: true)
            let incoming = filesRoot.appendingPathComponent("files/incoming", isDirectory: true)
            let url = incoming.appendingPathComponent(String(fileName))
            try? FileManager.default.removeItem(at: url)
        }
    }
    
    @Test("Invalid fragment header is ignored")
    func invalidFragmentHeaderIsIgnored() async throws {
        let ble = makeBLEService()
        let capture = CaptureDelegate()
        ble.delegate = capture
        
        let remoteShortID = PeerID(str: "0011223344556677")
        let original = makeLargePublicPacket(senderShortHex: remoteShortID, size: 1000)
        let fragments = fragmentPacket(original, fragmentSize: 250)
        
        // Corrupt one fragment: make payload too short (header incomplete)
        var corrupted = fragments
        if !corrupted.isEmpty {
            var p = corrupted[0]
            p = BitchatPacket(
                type: p.type,
                senderID: p.senderID,
                recipientID: p.recipientID,
                timestamp: p.timestamp,
                payload: Data([0x00, 0x01, 0x02]), // invalid header
                signature: nil,
                ttl: p.ttl
            )
            corrupted[0] = p
        }
        
        for fragment in corrupted {
            ble._test_handlePacket(fragment, fromPeerID: remoteShortID)
        }

        await ble._test_drainFragmentPipeline()

        // Should not deliver since one fragment is invalid and reassembly can't complete
        #expect(capture.publicMessages.isEmpty)
    }
}

extension FragmentationTests {
    private func makeBLEService() -> BLEService {
        let mockKeychain = MockKeychain()
        let mockIdentityManager = MockIdentityManager(mockKeychain)
        let idBridge = NostrIdentityBridge(keychain: MockKeychainHelper())

        return BLEService(
            keychain: mockKeychain,
            idBridge: idBridge,
            identityManager: mockIdentityManager,
            initializeBluetoothManagers: false
        )
    }

    /// Thread-safe delegate that supports awaiting message delivery
    private final class CaptureDelegate: BitchatDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var _publicMessages: [(peerID: PeerID, nickname: String, content: String)] = []
        private var _receivedMessages: [BitchatMessage] = []

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        var publicMessages: [(peerID: PeerID, nickname: String, content: String)] {
            withLock { _publicMessages }
        }

        var receivedMessages: [BitchatMessage] {
            withLock { _receivedMessages }
        }

        func didReceiveMessage(_ message: BitchatMessage) {
            withLock { _receivedMessages.append(message) }
        }

        func didReceivePublicMessage(from peerID: PeerID, nickname: String, content: String, timestamp: Date, messageID: String?) {
            withLock { _publicMessages.append((peerID, nickname, content)) }
        }

        func didConnectToPeer(_ peerID: PeerID) {}
        func didDisconnectFromPeer(_ peerID: PeerID) {}
        func didUpdatePeerList(_ peers: [PeerID]) {}
        func isFavorite(fingerprint: String) -> Bool { false }
        func didUpdateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) {}
        func didReceiveNoisePayload(from peerID: PeerID, type: NoisePayloadType, payload: Data, timestamp: Date) {}
        func didUpdateBluetoothState(_ state: CBManagerState) {}
    }

    // Helper: build a large message packet (unencrypted public message)
    private func makeLargePublicPacket(senderShortHex: PeerID, size: Int) -> BitchatPacket {
        let content = String(repeating: "A", count: size)
        let payload = Data(content.utf8)
        let pkt = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data(hexString: senderShortHex.id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 7
        )
        return pkt
    }

    // Helper: fragment a packet using the same header format BLEService expects
    private func fragmentPacket(_ packet: BitchatPacket, fragmentSize: Int, fragmentID: Data? = nil, pad: Bool = true) -> [BitchatPacket] {
        guard let fullData = packet.toBinaryData(padding: pad) else { return [] }
        let fid = fragmentID ?? Data((0..<8).map { _ in UInt8.random(in: 0...255) })
        let chunks: [Data] = stride(from: 0, to: fullData.count, by: fragmentSize).map { off in
            Data(fullData[off..<min(off + fragmentSize, fullData.count)])
        }
        let total = UInt16(chunks.count)
        var packets: [BitchatPacket] = []
        for (i, chunk) in chunks.enumerated() {
            var payload = Data()
            payload.append(fid)
            var idxBE = UInt16(i).bigEndian
            var totBE = total.bigEndian
            withUnsafeBytes(of: &idxBE) { payload.append(contentsOf: $0) }
            withUnsafeBytes(of: &totBE) { payload.append(contentsOf: $0) }
            payload.append(packet.type)
            payload.append(chunk)
            let fpkt = BitchatPacket(
                type: MessageType.fragment.rawValue,
                senderID: packet.senderID,
                recipientID: packet.recipientID,
                timestamp: packet.timestamp,
                payload: payload,
                signature: nil,
                ttl: packet.ttl
            )
            packets.append(fpkt)
        }
        return packets
    }
}

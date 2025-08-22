//
// FragmentationTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import bitchat

final class FragmentationTests: XCTestCase {

    private final class CaptureDelegate: BitchatDelegate {
        var publicMessages: [(peerID: String, nickname: String, content: String)] = []
        func didReceiveMessage(_ message: BitchatMessage) {}
        func didConnectToPeer(_ peerID: String) {}
        func didDisconnectFromPeer(_ peerID: String) {}
        func didUpdatePeerList(_ peers: [String]) {}
        func isFavorite(fingerprint: String) -> Bool { false }
        func didUpdateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) {}
        func didReceiveNoisePayload(from peerID: String, type: NoisePayloadType, payload: Data, timestamp: Date) {}
        func didReceivePublicMessage(from peerID: String, nickname: String, content: String, timestamp: Date) {
            publicMessages.append((peerID, nickname, content))
        }
        func didReceiveRegionalPublicMessage(from peerID: String, nickname: String, content: String, timestamp: Date) {}
    }

    // Helper: build a large message packet (unencrypted public message)
    private func makeLargePublicPacket(senderShortHex: String, size: Int) -> BitchatPacket {
        let content = String(repeating: "A", count: size)
        let payload = Data(content.utf8)
        let pkt = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data(hexString: senderShortHex) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 7
        )
        return pkt
    }

    // Helper: fragment a packet using the same header format BLEService expects
    private func fragmentPacket(_ packet: BitchatPacket, fragmentSize: Int, fragmentID: Data? = nil) -> [BitchatPacket] {
        let fullData = packet.toBinaryData() ?? Data()
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

    func test_reassembly_from_fragments_delivers_public_message() {
        let ble = BLEService()
        let capture = CaptureDelegate()
        ble.delegate = capture

        // Construct a big packet (3KB) from a remote sender (not our own ID)
        let remoteShortID = "1122334455667788"
        let original = makeLargePublicPacket(senderShortHex: remoteShortID, size: 3_000)
        // Use a small fragment size to ensure multiple pieces
        let fragments = fragmentPacket(original, fragmentSize: 400)

        // Shuffle fragments to simulate out-of-order arrival
        let shuffled = fragments.shuffled()

        // Inject fragments spaced out to avoid concurrent mutation inside BLEService
        for (i, f) in shuffled.enumerated() {
            let delay = DispatchTime.now() + .milliseconds(5 * i)
            DispatchQueue.global().asyncAfter(deadline: delay) {
                ble._test_handlePacket(f, fromPeerID: remoteShortID)
            }
        }

        // Allow async processing
        let exp = expectation(description: "reassembled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(capture.publicMessages.count, 1)
        XCTAssertEqual(capture.publicMessages.first?.content.count, 3_000)
    }

    func test_duplicate_fragment_does_not_break_reassembly() {
        let ble = BLEService()
        let capture = CaptureDelegate()
        ble.delegate = capture

        let remoteShortID = "A1B2C3D4E5F60708"
        let original = makeLargePublicPacket(senderShortHex: remoteShortID, size: 2048)
        var frags = fragmentPacket(original, fragmentSize: 300)
        // Duplicate one fragment
        if let dup = frags.first { frags.insert(dup, at: 1) }

        for (i, f) in frags.enumerated() {
            let delay = DispatchTime.now() + .milliseconds(5 * i)
            DispatchQueue.global().asyncAfter(deadline: delay) {
                ble._test_handlePacket(f, fromPeerID: remoteShortID)
            }
        }

        let exp = expectation(description: "reassembled2")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(capture.publicMessages.count, 1)
        XCTAssertEqual(capture.publicMessages.first?.content.count, 2048)
    }

    func test_invalid_fragment_header_is_ignored() {
        let ble = BLEService()
        let capture = CaptureDelegate()
        ble.delegate = capture

        let remoteShortID = "0011223344556677"
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

        for (i, f) in corrupted.enumerated() {
            let delay = DispatchTime.now() + .milliseconds(5 * i)
            DispatchQueue.global().asyncAfter(deadline: delay) {
                ble._test_handlePacket(f, fromPeerID: remoteShortID)
            }
        }

        let exp = expectation(description: "no reassembly")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        // Should not deliver since one fragment is invalid and reassembly can't complete
        XCTAssertEqual(capture.publicMessages.count, 0)
    }
}

import BitFoundation
import XCTest
@testable import bitchat

final class AndroidInteropTests: XCTestCase {

    func testAndroidJPEGPayloadPassesValidation() throws {
        // Construct an Android-shaped JPEG packet:
        // fileName: "IMG_20260727_221600_12345678-1234-1234-1234-1234567890ab.jpg"
        // mimeType: "image/jpeg; charset=utf-8"
        // content: JPEG magic bytes + dummy data
        var content = Data([0xFF, 0xD8, 0xFF])
        content.append(contentsOf: Array(repeating: UInt8(0x00), count: 100))

        let filePacket = BitchatFilePacket(
            fileName: "IMG_20260727_221600_12345678-1234-1234-1234-1234567890ab.jpg",
            fileSize: UInt64(content.count),
            mimeType: "image/jpeg; charset=utf-8",
            content: content
        )

        guard let encoded = filePacket.encode() else {
            return XCTFail("Failed to encode JPEG file packet")
        }

        let result = BLEIncomingFileValidator.validate(payload: encoded)
        switch result {
        case .success(let acceptance):
            XCTAssertEqual(acceptance.mime, .jpeg)
            // Verify stableID resolves successfully
            let localPeer = PeerID(str: "8899aabbccddeeff")
            let senderPeer = PeerID(str: "0011223344556677")
            let stableID = PrivateMediaMessageIdentity.stableID(
                for: acceptance.filePacket,
                senderPeerID: senderPeer,
                recipientPeerID: localPeer
            )
            XCTAssertNotNil(stableID)
        case .failure(let error):
            XCTFail("Android JPEG validation failed: \(error)")
        }
    }

    func testAndroidOGGVoiceNotePayloadPassesValidation() throws {
        // Construct an Android-shaped OGG voice note packet:
        // fileName: "VOICE_20260727_221600_0123456789abcdef.ogg"
        // mimeType: "audio/ogg; codecs=opus"
        // content: OGG magic bytes + dummy data
        var content = Data([0x4F, 0x67, 0x67, 0x53])
        content.append(contentsOf: Array(repeating: UInt8(0x00), count: 200)) // Must be > 100 bytes for leniency check? Wait, ogg doesn't need > 100 bytes but we append just in case

        let filePacket = BitchatFilePacket(
            fileName: "VOICE_20260727_221600_0123456789abcdef.ogg",
            fileSize: UInt64(content.count),
            mimeType: "audio/ogg; codecs=opus",
            content: content
        )

        guard let encoded = filePacket.encode() else {
            return XCTFail("Failed to encode OGG voice note packet")
        }

        let result = BLEIncomingFileValidator.validate(payload: encoded)
        switch result {
        case .success(let acceptance):
            XCTAssertEqual(acceptance.mime, .ogg)
            // Verify stableID resolves successfully
            let localPeer = PeerID(str: "8899aabbccddeeff")
            let senderPeer = PeerID(str: "0011223344556677")
            let stableID = PrivateMediaMessageIdentity.stableID(
                for: acceptance.filePacket,
                senderPeerID: senderPeer,
                recipientPeerID: localPeer
            )
            XCTAssertNotNil(stableID)
        case .failure(let error):
            XCTFail("Android OGG validation failed: \(error)")
        }
    }

    func testAndroidOctetStreamFallbackPassesValidation() throws {
        // Construct fallback application/octet-stream packet:
        // fileName: "file_20260727_221600_12345678-1234-1234-1234-1234567890ab.bin"
        // mimeType: "application/octet-stream"
        // content: random bytes
        let content = Data([0x01, 0x02, 0x03, 0x04, 0x05])

        let filePacket = BitchatFilePacket(
            fileName: "file_20260727_221600_12345678-1234-1234-1234-1234567890ab.bin",
            fileSize: UInt64(content.count),
            mimeType: "application/octet-stream",
            content: content
        )

        guard let encoded = filePacket.encode() else {
            return XCTFail("Failed to encode binary packet")
        }

        let result = BLEIncomingFileValidator.validate(payload: encoded)
        switch result {
        case .success(let acceptance):
            XCTAssertEqual(acceptance.mime, .octetStream)
        case .failure(let error):
            XCTFail("Android binary fallback validation failed: \(error)")
        }
    }
}

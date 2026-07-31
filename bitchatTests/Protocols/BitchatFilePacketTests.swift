import BitFoundation
import XCTest
@testable import bitchat

final class BitchatFilePacketTests: XCTestCase {

    func testRoundTripPreservesFields() throws {
        let content = Data((0..<4096).map { UInt8($0 % 251) })
        let packet = BitchatFilePacket(
            fileName: "sample.jpg",
            fileSize: UInt64(content.count),
            mimeType: "image/jpeg",
            content: content
        )

        guard let encoded = packet.encode() else {
            return XCTFail("Failed to encode file packet")
        }
        guard let decoded = BitchatFilePacket.decode(encoded) else {
            return XCTFail("Failed to decode file packet")
        }

        XCTAssertEqual(decoded.fileName, packet.fileName)
        XCTAssertEqual(decoded.fileSize, packet.fileSize)
        XCTAssertEqual(decoded.mimeType, packet.mimeType)
        XCTAssertEqual(decoded.content, packet.content)
    }

    func testDecodeFallsBackToContentSizeWhenFileSizeMissing() throws {
        let content = Data(repeating: 0x7F, count: 1024)
        let packet = BitchatFilePacket(
            fileName: nil,
            fileSize: nil,
            mimeType: nil,
            content: content
        )

        guard let encoded = packet.encode() else {
            return XCTFail("Failed to encode file packet")
        }
        guard let decoded = BitchatFilePacket.decode(encoded) else {
            return XCTFail("Failed to decode file packet")
        }

        XCTAssertEqual(decoded.fileSize, UInt64(content.count))
        XCTAssertEqual(decoded.content, content)
    }

    func testDecodeSupportsLegacyEightByteFileSizeTLV() throws {
        let content = Data([0x01, 0x02, 0x03, 0x04])
        var data = Data()

        data.append(0x02)
        data.append(contentsOf: [0x00, 0x08])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00])
        data.append(0x04)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x04])
        data.append(content)

        let decoded = try XCTUnwrap(BitchatFilePacket.decode(data))
        XCTAssertEqual(decoded.fileSize, 256)
        XCTAssertEqual(decoded.content, content)
    }

    func testDecodeUsesContentCountWhenFileSizeTLVIsMissing() throws {
        let content = Data([0xAA, 0xBB, 0xCC])
        var data = Data()

        data.append(0x04)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x03])
        data.append(content)

        let decoded = try XCTUnwrap(BitchatFilePacket.decode(data))
        XCTAssertEqual(decoded.fileSize, UInt64(content.count))
        XCTAssertEqual(decoded.content, content)
    }

    /// The TLV tag list is a floor, not a ceiling: a decoder that bails on the
    /// first tag it does not know makes the format unextendable, because a field
    /// the sender considered optional costs the receiver the whole file. This
    /// decoder skips them (`case nil: continue`) and that has to stay true — it
    /// is load-bearing for any peer, version or third-party client that adds a
    /// field we have not seen. `PrivateMediaMessageIdentity` exists precisely
    /// because the Android decoder does *not* do this, so the asymmetry is real
    /// and worth pinning on the side that gets it right.
    func testDecodeSkipsUnknownTLVTypesInsteadOfDroppingTheFile() throws {
        let content = Data((0..<64).map { UInt8($0) })
        let unknownValue = Data("some-message-id".utf8)
        var data = Data()

        // fileName
        data.append(0x01)
        data.append(contentsOf: [0x00, 0x09])
        data.append(Data("photo.jpg".utf8))
        // fileSize
        data.append(0x02)
        data.append(contentsOf: [0x00, 0x04])
        data.append(contentsOf: [0x00, 0x00, 0x00, UInt8(content.count)])
        // mimeType
        data.append(0x03)
        data.append(contentsOf: [0x00, 0x0A])
        data.append(Data("image/jpeg".utf8))
        // An unknown tag, where an encoder appending content last would put it
        data.append(0x05)
        data.append(contentsOf: [0x00, UInt8(unknownValue.count)])
        data.append(unknownValue)
        // content
        data.append(0x04)
        data.append(contentsOf: [0x00, 0x00, 0x00, UInt8(content.count)])
        data.append(content)

        let decoded = try XCTUnwrap(BitchatFilePacket.decode(data))
        XCTAssertEqual(decoded.fileName, "photo.jpg")
        XCTAssertEqual(decoded.mimeType, "image/jpeg")
        XCTAssertEqual(decoded.fileSize, UInt64(content.count))
        XCTAssertEqual(decoded.content, content)
    }

    /// Same contract for an extension that trails the content, which a decoder
    /// stopping at the first unknown tag would also lose.
    func testDecodeSkipsAnUnknownTLVTrailingTheContent() throws {
        let content = Data(repeating: 0x7F, count: 16)
        var data = Data()

        data.append(0x01)
        data.append(contentsOf: [0x00, 0x08])
        data.append(Data("note.m4a".utf8))
        data.append(0x04)
        data.append(contentsOf: [0x00, 0x00, 0x00, UInt8(content.count)])
        data.append(content)
        data.append(0x7F)
        data.append(contentsOf: [0x00, 0x04])
        data.append(Data([0x11, 0x11, 0x11, 0x11]))

        let decoded = try XCTUnwrap(BitchatFilePacket.decode(data))
        XCTAssertEqual(decoded.fileName, "note.m4a")
        XCTAssertNil(decoded.mimeType)
        XCTAssertEqual(decoded.fileSize, UInt64(content.count))
        XCTAssertEqual(decoded.content, content)
    }

    func testPrivateMediaMessageIdentityConvergesAcrossPeerIDAliases() throws {
        let senderKey = Data(repeating: 0x11, count: 32)
        let recipientKey = Data(repeating: 0x22, count: 32)
        let senderStable = PeerID(hexData: senderKey)
        let recipientStable = PeerID(hexData: recipientKey)
        let fileName = "img_20260725_105708_1CC2760D-76AA-40C3-8013-C7FAA6C2EF99.jpg"

        let senderID = try XCTUnwrap(PrivateMediaMessageIdentity.stableID(
            senderPeerID: senderStable.toShort(),
            recipientPeerID: PeerID(str: "mesh:\(recipientStable.toShort().bare)"),
            fileName: fileName
        ))
        let receiverID = try XCTUnwrap(PrivateMediaMessageIdentity.stableID(
            senderPeerID: senderStable,
            recipientPeerID: recipientStable.toShort(),
            fileName: fileName
        ))

        XCTAssertEqual(senderID, receiverID)
        XCTAssertTrue(senderID.hasPrefix("media-"))
        XCTAssertEqual(senderID.count, 38)
        XCTAssertTrue(PrivateMediaMessageIdentity.isStableID(senderID))
        XCTAssertFalse(PrivateMediaMessageIdentity.isStableID("media-\(String(repeating: "A", count: 32))"))
        XCTAssertFalse(PrivateMediaMessageIdentity.isStableID("media-\(String(repeating: "a", count: 31))"))
        XCTAssertFalse(PrivateMediaMessageIdentity.isStableID(UUID().uuidString))
    }

    func testPrivateMediaMessageIdentitySeparatesDirectionAndFilename() throws {
        let alice = PeerID(str: "0011223344556677")
        let bob = PeerID(str: "8899aabbccddeeff")
        let firstName = "voice_20260725_105708_11111111-1111-1111-1111-111111111111.m4a"
        let secondName = "voice_20260725_105709_22222222-2222-2222-2222-222222222222.m4a"
        let first = try XCTUnwrap(PrivateMediaMessageIdentity.stableID(
            senderPeerID: alice,
            recipientPeerID: bob,
            fileName: firstName
        ))

        XCTAssertNotEqual(first, PrivateMediaMessageIdentity.stableID(
            senderPeerID: bob,
            recipientPeerID: alice,
            fileName: firstName
        ))
        XCTAssertNotEqual(first, PrivateMediaMessageIdentity.stableID(
            senderPeerID: alice,
            recipientPeerID: bob,
            fileName: secondName
        ))
        XCTAssertNil(PrivateMediaMessageIdentity.stableID(
            senderPeerID: alice,
            recipientPeerID: bob,
            fileName: nil
        ))
        XCTAssertNil(PrivateMediaMessageIdentity.stableID(
            senderPeerID: alice,
            recipientPeerID: bob,
            fileName: "photo.jpg"
        ))
        XCTAssertNil(PrivateMediaMessageIdentity.stableID(
            senderPeerID: alice,
            recipientPeerID: bob,
            fileName: "img_11111111-1111-1111-1111-111111111111.pdf"
        ))
        XCTAssertNotNil(PrivateMediaMessageIdentity.stableID(
            senderPeerID: alice,
            recipientPeerID: bob,
            fileName: "voice_0011223344556677.m4a"
        ))
    }

    func testPrivateMediaMessageIdentityMatchesVersionOneGoldenVector() {
        XCTAssertEqual(
            PrivateMediaMessageIdentity.stableID(
                senderPeerID: PeerID(str: "0011223344556677"),
                recipientPeerID: PeerID(str: "8899aabbccddeeff"),
                fileName: "img_20260725_105708_1CC2760D-76AA-40C3-8013-C7FAA6C2EF99.jpg"
            ),
            "media-910bd42c65060ab76bb6406f220c4516"
        )
    }
}

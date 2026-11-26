import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BLEFileTransferPolicyTests {
    @Test
    func selfEchoRejectsOnlyNonSyncReplayFromLocalPeer() {
        let localPeerID = PeerID(str: "1122334455667788")
        let localPacket = makePacket(sender: localPeerID, ttl: 3)
        let replayPacket = makePacket(sender: localPeerID, ttl: 0)
        let remotePacket = makePacket(sender: PeerID(str: "8877665544332211"), ttl: 3)

        #expect(BLEFileTransferPolicy.isSelfEcho(packet: localPacket, from: localPeerID, localPeerID: localPeerID))
        #expect(!BLEFileTransferPolicy.isSelfEcho(packet: replayPacket, from: localPeerID, localPeerID: localPeerID))
        #expect(!BLEFileTransferPolicy.isSelfEcho(packet: remotePacket, from: PeerID(str: "8877665544332211"), localPeerID: localPeerID))
    }

    @Test
    func deliveryPlanTracksPublicBroadcastsForSync() {
        let localPeerID = PeerID(str: "1122334455667788")

        #expect(BLEFileTransferPolicy.deliveryPlan(
            packet: makePacket(sender: PeerID(str: "8877665544332211"), recipientID: nil),
            localPeerID: localPeerID
        ) == BLEFileTransferDeliveryPlan(isPrivateMessage: false, shouldTrackForSync: true))

        #expect(BLEFileTransferPolicy.deliveryPlan(
            packet: makePacket(
                sender: PeerID(str: "8877665544332211"),
                recipientID: Data(repeating: 0xFF, count: 8)
            ),
            localPeerID: localPeerID
        ) == BLEFileTransferDeliveryPlan(isPrivateMessage: false, shouldTrackForSync: true))
    }

    @Test
    func deliveryPlanAcceptsOnlyDirectedPacketsForLocalPeer() {
        let localPeerID = PeerID(str: "1122334455667788")
        let otherPeerID = PeerID(str: "8877665544332211")

        #expect(BLEFileTransferPolicy.deliveryPlan(
            packet: makePacket(
                sender: otherPeerID,
                recipientID: Data(hexString: localPeerID.id)
            ),
            localPeerID: localPeerID
        ) == BLEFileTransferDeliveryPlan(isPrivateMessage: true, shouldTrackForSync: false))

        #expect(BLEFileTransferPolicy.deliveryPlan(
            packet: makePacket(
                sender: otherPeerID,
                recipientID: Data(hexString: otherPeerID.id)
            ),
            localPeerID: localPeerID
        ) == nil)
    }

    @Test
    func validatorAcceptsMatchingMimeAndMagicBytes() throws {
        let payload = try makeFilePayload(
            mimeType: "application/pdf",
            content: Data("%PDF-1.7".utf8)
        )

        let result = BLEIncomingFileValidator.validate(payload: payload)

        guard case .success(let acceptance) = result else {
            Issue.record("Expected file validation success")
            return
        }
        #expect(acceptance.mime == .pdf)
        #expect(acceptance.filePacket.content == Data("%PDF-1.7".utf8))
    }

    @Test
    func validatorRejectsMalformedPayload() {
        let result = BLEIncomingFileValidator.validate(payload: Data([0x01, 0x02, 0x03]))

        #expect(result.rejection == .malformedPayload)
    }

    @Test
    func validatorRejectsUnsupportedMime() throws {
        let payload = try makeFilePayload(
            mimeType: nil,
            content: Data([0x4D, 0x5A, 0x00, 0x00])
        )

        let result = BLEIncomingFileValidator.validate(payload: payload)

        #expect(result.rejection == .unsupportedMime(mimeType: nil, bytes: 4))
    }

    @Test
    func validatorRejectsMimeMagicMismatch() throws {
        let payload = try makeFilePayload(
            mimeType: "image/png",
            content: Data([0x00, 0x01, 0x02, 0x03])
        )

        let result = BLEIncomingFileValidator.validate(payload: payload)

        #expect(result.rejection == .magicMismatch(
            mime: .png,
            bytes: 4,
            prefixHex: "00 01 02 03"
        ))
    }

    @Test
    func validatorAcceptsValidPNGAndJPEGWithinBounds() throws {
        let pngPayload = try makeFilePayload(mimeType: "image/png", content: TestImageFixtures.makePNG(width: 16, height: 12))
        let jpegPayload = try makeFilePayload(mimeType: "image/jpeg", content: TestImageFixtures.makeJPEG(width: 16, height: 12))

        if case .failure(let rejection) = BLEIncomingFileValidator.validate(payload: pngPayload) {
            Issue.record("Expected valid PNG to pass, got \(rejection)")
        }
        if case .failure(let rejection) = BLEIncomingFileValidator.validate(payload: jpegPayload) {
            Issue.record("Expected valid JPEG to pass, got \(rejection)")
        }
    }

    @Test
    func validatorRejectsPNGDecompressionBombExceedingDimensionLimit() throws {
        let bomb = TestImageFixtures.makePNGBomb(width: 32_768, height: 32_768)
        let payload = try makeFilePayload(mimeType: "image/png", content: bomb)

        let result = BLEIncomingFileValidator.validate(payload: payload)

        guard case .failure(.invalidImage(let mime, let bytes, _)) = result else {
            Issue.record("Expected .invalidImage rejection for 32768x32768 PNG bomb, got \(result)")
            return
        }
        #expect(mime == .png)
        #expect(bytes == bomb.count)
    }

    @Test
    func validatorRejectsTruncatedJPEGWithoutDimensions() throws {
        let stub = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let payload = try makeFilePayload(mimeType: "image/jpeg", content: stub)

        let result = BLEIncomingFileValidator.validate(payload: payload)

        guard case .failure(.invalidImage(let mime, _, _)) = result else {
            Issue.record("Expected .invalidImage rejection for truncated JPEG stub, got \(result)")
            return
        }
        #expect(mime == .jpeg)
    }

    @Test
    func imageDownsamplerRejectsOversizedPNGAndDownsamplesValidImage() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageDownsamplerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bombURL = tempDir.appendingPathComponent("bomb.png")
        try TestImageFixtures.makePNGBomb(width: 16_384, height: 16_384).write(to: bombURL)
        #expect(ImageDownsampler.loadDownsampledImage(from: bombURL, maxPixelSize: 64) == nil)

        let validURL = tempDir.appendingPathComponent("valid.png")
        try TestImageFixtures.makePNG(width: 256, height: 128).write(to: validURL)
        let thumbnail = try #require(ImageDownsampler.loadDownsampledImage(from: validURL, maxPixelSize: 64))
        #expect(max(thumbnail.size.width, thumbnail.size.height) <= 64)
    }

    private func makePacket(
        sender: PeerID,
        ttl: UInt8 = 3,
        recipientID: Data? = nil
    ) -> BitchatPacket {
        BitchatPacket(
            type: MessageType.fileTransfer.rawValue,
            senderID: Data(hexString: sender.id) ?? Data(),
            recipientID: recipientID,
            timestamp: 900_000,
            payload: Data([0x01, 0x02]),
            signature: nil,
            ttl: ttl
        )
    }

    private func makeFilePayload(mimeType: String?, content: Data) throws -> Data {
        let packet = BitchatFilePacket(
            fileName: "sample",
            fileSize: UInt64(content.count),
            mimeType: mimeType,
            content: content
        )
        return try #require(packet.encode())
    }
}

private extension Result where Failure == BLEIncomingFileRejection {
    var rejection: BLEIncomingFileRejection? {
        guard case .failure(let rejection) = self else { return nil }
        return rejection
    }
}

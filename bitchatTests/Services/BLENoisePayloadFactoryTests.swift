import Foundation
import Testing
@testable import bitchat

struct BLENoisePayloadFactoryTests {
    @Test
    func privateMessagePayloadPrefixesTLVWithNoiseType() throws {
        let payload = try #require(BLENoisePayloadFactory.privateMessage(content: "secret", messageID: "pm-1"))

        #expect(payload.first == NoisePayloadType.privateMessage.rawValue)

        let packet = try #require(PrivateMessagePacket.decode(from: Data(payload.dropFirst())))
        #expect(packet.messageID == "pm-1")
        #expect(packet.content == "secret")
    }

    @Test
    func receiptPayloadsUseMessageIDBytes() {
        let read = BLENoisePayloadFactory.readReceipt(originalMessageID: "read-id")
        let delivered = BLENoisePayloadFactory.delivered(messageID: "delivered-id")

        #expect(read.first == NoisePayloadType.readReceipt.rawValue)
        #expect(String(data: Data(read.dropFirst()), encoding: .utf8) == "read-id")
        #expect(delivered.first == NoisePayloadType.delivered.rawValue)
        #expect(String(data: Data(delivered.dropFirst()), encoding: .utf8) == "delivered-id")
    }

    @Test
    func typedPayloadKeepsOpaqueDataUnchanged() {
        let payload = BLENoisePayloadFactory.typedPayload(.verifyChallenge, payload: Data([0xCA, 0xFE]))

        #expect(payload == Data([NoisePayloadType.verifyChallenge.rawValue, 0xCA, 0xFE]))
    }

    @Test
    func privateFilePayloadPrefixesCanonicalFilePacket() throws {
        let content = Data("%PDF-secret".utf8)
        let file = BitchatFilePacket(
            fileName: "secret.pdf",
            fileSize: UInt64(content.count),
            mimeType: "application/pdf",
            content: content
        )

        let payload = try #require(BLENoisePayloadFactory.privateFile(file))

        #expect(payload.first == NoisePayloadType.privateFile.rawValue)
        let decoded = try #require(BitchatFilePacket.decode(Data(payload.dropFirst())))
        #expect(decoded.fileName == "secret.pdf")
        #expect(decoded.mimeType == "application/pdf")
        #expect(decoded.content == content)
    }
}

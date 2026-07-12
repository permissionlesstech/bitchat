import Foundation
import Testing
import BitFoundation
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

        #expect(payload.first == 0x20, "Encrypted files must use Android's deployed wire value")
        let decoded = try #require(BitchatFilePacket.decode(Data(payload.dropFirst())))
        #expect(decoded.fileName == "secret.pdf")
        #expect(decoded.mimeType == "application/pdf")
        #expect(decoded.content == content)
    }

    @Test
    func androidB7f0b33PrivateFilePlaintextFixtureIsByteCompatible() throws {
        // Runtime-emitted by Android commit b7f0b33d from
        // BitchatFilePacket("a.txt", 3, "text/plain", [01, 02, 03]) and
        // NoisePayload(type = FILE_TRANSFER, data = file.encode()).encode().
        let fixtureHex = "20010005612e7478740200040000000303000a746578742f706c61696e0400000003010203"
        let fixture = try #require(Data(hexString: fixtureHex))

        let typed = try #require(NoisePayload.decode(fixture))
        #expect(typed.type == .privateFile)
        let file = try #require(BitchatFilePacket.decode(typed.data))
        #expect(file.fileName == "a.txt")
        #expect(file.fileSize == 3)
        #expect(file.mimeType == "text/plain")
        #expect(file.content == Data([0x01, 0x02, 0x03]))
        #expect(BLENoisePayloadFactory.privateFile(file) == fixture)
    }

    @Test
    func prereleasePrivateFileTypeCanonicalizesOnDecode() throws {
        let encoded = Data([NoisePayloadType.prereleasePrivateFileRawValue, 0xCA, 0xFE])
        let decoded = try #require(NoisePayload.decode(encoded))

        #expect(decoded.type == .privateFile)
        #expect(decoded.data == Data([0xCA, 0xFE]))
        #expect(decoded.encode().first == 0x20)
    }
}

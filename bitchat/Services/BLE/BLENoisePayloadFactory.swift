import BitFoundation
import Foundation

enum BLENoisePayloadFactory {
    static let privateFileChunkContentBytes = 60 * 1024

    static func privateMessage(content: String, messageID: String) -> Data? {
        guard let payload = PrivateMessagePacket(messageID: messageID, content: content).encode() else {
            return nil
        }

        return typedPayload(.privateMessage, payload: payload)
    }

    static func readReceipt(originalMessageID: String) -> Data {
        typedPayload(.readReceipt, payload: Data(originalMessageID.utf8))
    }

    static func delivered(messageID: String) -> Data {
        typedPayload(.delivered, payload: Data(messageID.utf8))
    }

    static func privateFileTransferChunks(_ packet: BitchatFilePacket, transferId: String) -> [Data]? {
        guard !packet.content.isEmpty,
              packet.content.count <= FileTransferLimits.maxImageBytes else {
            return nil
        }

        let total = Int(ceil(Double(packet.content.count) / Double(privateFileChunkContentBytes)))
        guard total > 0, total <= Int(UInt16.max) else { return nil }

        let fileHash = packet.content.sha256Hash()
        var chunks: [Data] = []
        chunks.reserveCapacity(total)

        for index in 0..<total {
            let start = index * privateFileChunkContentBytes
            let end = min(start + privateFileChunkContentBytes, packet.content.count)
            let chunkPacket = PrivateFileTransferChunkPacket(
                transferID: transferId,
                index: index,
                total: total,
                fileName: packet.fileName,
                mimeType: packet.mimeType,
                fileSize: UInt64(packet.content.count),
                fileSHA256: fileHash,
                content: Data(packet.content[start..<end])
            )

            guard let encoded = chunkPacket.encode() else { return nil }
            let typed = typedPayload(.fileTransfer, payload: encoded)
            guard typed.count <= NoiseSecurityConstants.maxMessageSize else { return nil }
            chunks.append(typed)
        }

        return chunks
    }

    static func typedPayload(_ type: NoisePayloadType, payload: Data) -> Data {
        var typed = Data([type.rawValue])
        typed.append(payload)
        return typed
    }
}

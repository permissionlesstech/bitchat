import BitFoundation
import Foundation

enum BLENoisePayloadFactory {
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

    static func privateFileTransferPayload(_ packet: BitchatFilePacket, transferId: String) -> Data? {
        guard !packet.content.isEmpty,
              packet.content.count <= FileTransferLimits.maxImageBytes else {
            return nil
        }

        let envelope = PrivateFileTransferPacket(
            transferID: transferId,
            fileSHA256: packet.content.sha256Hash(),
            filePacket: packet
        )
        guard let encoded = envelope.encode() else { return nil }
        let typed = typedPayload(.fileTransfer, payload: encoded)
        guard NoiseSecurityValidator.validatePrivateFileMessageSize(typed) else { return nil }
        return typed
    }

    static func typedPayload(_ type: NoisePayloadType, payload: Data) -> Data {
        var typed = Data([type.rawValue])
        typed.append(payload)
        return typed
    }
}

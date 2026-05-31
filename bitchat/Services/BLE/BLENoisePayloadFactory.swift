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

    static func typedPayload(_ type: NoisePayloadType, payload: Data) -> Data {
        var typed = Data([type.rawValue])
        typed.append(payload)
        return typed
    }
}

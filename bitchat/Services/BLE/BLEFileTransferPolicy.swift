import BitFoundation
import Foundation

struct BLEFileTransferDeliveryPlan: Equatable {
    let isPrivateMessage: Bool
    let shouldTrackForSync: Bool
}

enum BLEFileTransferPolicy {
    static func isSelfEcho(packet: BitchatPacket, from peerID: PeerID, localPeerID: PeerID) -> Bool {
        peerID == localPeerID && packet.ttl != 0
    }

    static func deliveryPlan(packet: BitchatPacket, localPeerID: PeerID) -> BLEFileTransferDeliveryPlan? {
        guard let recipientID = packet.recipientID else {
            return BLEFileTransferDeliveryPlan(isPrivateMessage: false, shouldTrackForSync: true)
        }

        let isBroadcast = recipientID.allSatisfy { $0 == 0xFF }
        if isBroadcast {
            return BLEFileTransferDeliveryPlan(isPrivateMessage: false, shouldTrackForSync: true)
        }

        guard PeerID(hexData: recipientID) == localPeerID else {
            return nil
        }

        return BLEFileTransferDeliveryPlan(isPrivateMessage: true, shouldTrackForSync: false)
    }
}

struct BLEIncomingFileAcceptance {
    let filePacket: BitchatFilePacket
    let mime: MimeType
}

enum BLEIncomingFileRejection: Error, Equatable {
    case malformedPayload
    case payloadTooLarge(bytes: Int)
    case unsupportedMime(mimeType: String?, bytes: Int)
    case magicMismatch(mime: MimeType, bytes: Int, prefixHex: String)
}

enum BLEIncomingFileValidator {
    static func validate(payload: Data) -> Result<BLEIncomingFileAcceptance, BLEIncomingFileRejection> {
        guard let filePacket = BitchatFilePacket.decode(payload) else {
            SecureLogger.error("❌ BLEIncomingFileValidator: BitchatFilePacket.decode returned nil", category: .session)
            return .failure(.malformedPayload)
        }

        guard FileTransferLimits.isValidPayload(filePacket.content.count) else {
            SecureLogger.warning("🚫 BLEIncomingFileValidator: payloadTooLarge (\(filePacket.content.count) bytes)", category: .security)
            return .failure(.payloadTooLarge(bytes: filePacket.content.count))
        }

        guard let mime = MimeType(filePacket.mimeType), mime.isAllowed else {
            SecureLogger.warning("🚫 BLEIncomingFileValidator: unsupportedMime '\(filePacket.mimeType ?? "nil")'", category: .security)
            return .failure(.unsupportedMime(
                mimeType: filePacket.mimeType,
                bytes: filePacket.content.count
            ))
        }

        guard mime.matches(data: filePacket.content) else {
            let prefix = filePacket.content.prefix(20).map { String(format: "%02x", $0) }.joined(separator: " ")
            SecureLogger.warning("🚫 BLEIncomingFileValidator: magicMismatch for \(mime) (prefix: \(prefix))", category: .security)
            return .failure(.magicMismatch(
                mime: mime,
                bytes: filePacket.content.count,
                prefixHex: prefix
            ))
        }

        return .success(BLEIncomingFileAcceptance(filePacket: filePacket, mime: mime))
    }
}

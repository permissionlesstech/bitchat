import BitFoundation
import Foundation

enum BLEOutboundPacketPolicy {
    private static let fragmentFrameOverhead = 13 + 8 + 8 + 13

    static func messageID(for packet: BitchatPacket) -> String {
        BLEIngressLinkRegistry.messageID(for: packet)
    }

    static func padsBLEFrame(for packetType: UInt8) -> Bool {
        switch MessageType(rawValue: packetType) {
        case .noiseEncrypted, .noiseHandshake:
            return true
        // voiceFrame is deliberately unpadded: padding to the 512 block would
        // push every ~490-byte signed voice packet over the MTU into the
        // fragment path.
        case .none, .announce, .message, .leave, .requestSync, .fragment, .fileTransfer, .courierEnvelope, .boardPost, .ping, .pong, .nostrCarrier, .prekeyBundle, .groupMessage, .voiceFrame:
            return false
        }
    }

    static func priority(for packet: BitchatPacket, data _: Data) -> BLEOutboundWritePriority {
        guard let messageType = MessageType(rawValue: packet.type) else { return .low }
        switch messageType {
        case .fragment:
            return .fragment(totalFragments: fragmentTotalCount(from: packet.payload))
        case .fileTransfer:
            return .fileTransfer
        default:
            return .high
        }
    }

    static func fragmentChunkSize(forLinkLimit limit: Int) -> Int {
        max(64, limit - fragmentFrameOverhead)
    }

    private static func fragmentTotalCount(from payload: Data) -> Int {
        guard payload.count >= 12 else { return Int(UInt16.max) }
        let totalHigh = Int(payload[10])
        let totalLow = Int(payload[11])
        let total = (totalHigh << 8) | totalLow
        return max(total, 1)
    }
}

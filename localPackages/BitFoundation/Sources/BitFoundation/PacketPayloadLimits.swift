//
// PacketPayloadLimits.swift
// BitFoundation
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

/// Receive-side ceilings on how large a packet's payload may be, per type.
///
/// Received packets retain decoded payload data and any compressed representation
/// for signing and forwarding. Binary decoding applies the per-type cap to each
/// representation. Byte-budgeted stores count both representations.
///
/// | Packet types | Payload cap |
/// |---|---|
/// | fileTransfer, noiseEncrypted | FileTransferLimits.maxFramedFileBytes |
/// | message, groupMessage, unknown types | 128 KiB |
/// | courierEnvelope, nostrCarrier | 64 KiB |
/// | requestSync | 8 KiB |
/// | fragment | 1,280 bytes |
/// | announce, announceV2, leave, boardPost, prekeyBundle, voiceFrame, noiseHandshake, ping, pong | 4 KiB |
///
/// Binary decoding also applies its global framed-payload limit. A new packet
/// type uses the unknown-type cap until it is assigned an explicit limit here.
public enum PacketPayloadLimits {
    /// Raw DEFLATE's hard expansion ceiling: every 258-byte match costs at
    /// least a 1-bit length code plus a 1-bit distance code. A declared
    /// original size beyond this multiple of the compressed bytes cannot be
    /// produced by any stream, so it is rejected before the output buffer is
    /// allocated.
    static let maxDeflateRatio = 1032

    private static let fragmentBytes = 1_280
    private static let controlBytes = 4 * 1024
    private static let requestSyncBytes = 8 * 1024
    private static let envelopeBytes = 64 * 1024
    private static let twiceV1FrameBytes = 128 * 1024

    /// Conservative overhead allowance for a v2 header, sender and recipient,
    /// 255 route hops, original-size field, signature and padding.
    private static let maxFrameOverheadBytes = BinaryProtocol.v2HeaderSize
        + BinaryProtocol.senderIDSize
        + BinaryProtocol.recipientIDSize
        + 1 + Int(UInt8.max) * BinaryProtocol.senderIDSize
        + 4
        + BinaryProtocol.signatureSize
        + Int(UInt8.max)

    /// Ceiling for a packet's decoded payload and, separately, its retained
    /// compressed representation.
    static func maxPayloadBytes(forType type: UInt8) -> Int {
        guard let messageType = MessageType(rawValue: type) else {
            return twiceV1FrameBytes
        }
        switch messageType {
        case .fileTransfer, .noiseEncrypted:
            return FileTransferLimits.maxFramedFileBytes
        case .message, .groupMessage:
            return twiceV1FrameBytes
        case .courierEnvelope, .nostrCarrier:
            return envelopeBytes
        case .requestSync:
            return requestSyncBytes
        case .fragment:
            return fragmentBytes
        case .announce, .announceV2, .leave, .boardPost, .prekeyBundle,
             .voiceFrame, .noiseHandshake, .ping, .pong:
            return controlBytes
        }
    }

    /// Frame-size budget used by fragment reassembly for the claimed packet type.
    /// Includes the payload cap and a conservative overhead allowance; decoding
    /// applies additional validation after reassembly.
    public static func maxFrameBytes(forType type: UInt8) -> Int {
        maxPayloadBytes(forType: type) + maxFrameOverheadBytes
    }
}

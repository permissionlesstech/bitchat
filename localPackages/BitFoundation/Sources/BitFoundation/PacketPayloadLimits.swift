//
// PacketPayloadLimits.swift
// BitFoundation
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

/// Receive-side ceilings on how large a packet's payload may be, per type.
///
/// A compressed frame declares its original size, and raw DEFLATE lets ~1 KB
/// on air stand for ~1 MB decoded; fragment reassembly lets a large
/// uncompressed frame arrive as a stream of small, compressed fragments.
/// Every accepted packet is then held at its decoded size by stores that
/// evict by count (gossip sync, the public-message archive, the mesh
/// timeline), relayed, and re-served by sync, so a single frame-wide ceiling
/// turns airtime into memory on every node. `BinaryProtocol` enforces these
/// caps on every decoded payload, compressed or not, and fragment reassembly
/// bounds an assembly by the frame its claimed type can fill. Only the types
/// that carry media keep the framed-file ceiling; every other type is capped
/// at no less than twice the largest payload any shipping iOS or Android
/// encoder produces for it. Receive-side only: senders are unchanged.
///
/// | Type                         | Largest legitimate payload                                   | Cap                |
/// |------------------------------|--------------------------------------------------------------|--------------------|
/// | fileTransfer, noiseEncrypted | 1 MiB file + name/MIME TLVs (+ Noise framing for private)    | maxFramedFileBytes |
/// | message                      | 65,535 B: iOS and Android both send public messages as v1    | 128 KiB            |
/// |                              | frames (16-bit length); 60,000-char composer limit           |                    |
/// | groupMessage                 | 65,535 B: v1 frame (iOS only)                                | 128 KiB            |
/// | courierEnvelope              | 16 KiB ciphertext + 44 B of TLVs (iOS only)                  | 64 KiB             |
/// | nostrCarrier                 | 16 KiB event JSON + 22 B of TLVs (iOS only)                  | 64 KiB             |
/// | requestSync                  | ~2.1 KB: 1,024 B GCS filter (both platforms) + 1,019 B       | 8 KiB              |
/// |                              | fragment-ID filter (iOS)                                     |                    |
/// | announce                     | ~680 B: nickname, keys, 10 neighbours, capabilities, cell    | 4 KiB              |
/// | fragment                     | ≤ 513 B: 13 B header + chunk (Android 469 B, 500 B before    | 1,280 B            |
/// |                              | Aug 2025; iOS 469 B default, ≤ 482 B from the link limit;    |                    |
/// |                              | iOS 500 B before Jul 2025). Kept tight: every fragment also  |                    |
/// |                              | lands in the reassembly buffer and the gossip fragment store |                    |
/// | boardPost                    | ~750 B: 512 B content cap + IDs, key, signature (iOS only)   | 4 KiB              |
/// | prekeyBundle                 | ~400 B: 8 prekeys + key + signature (iOS only)               | 4 KiB              |
/// | announceV2                   | ~340 B: 64 B tag block + capabilities + cell (iOS only)      | 4 KiB              |
/// | voiceFrame                   | ~210 B burst budget (both platforms)                         | 4 KiB              |
/// | noiseHandshake               | 96 B (XX with empty payloads, both platforms)                | 4 KiB              |
/// | leave                        | ≤ 255 B: empty on iOS, nickname from Android Wi-Fi Aware     | 4 KiB              |
/// | ping, pong                   | 9 B (iOS only)                                               | 4 KiB              |
/// | unknown / future types       | a v1 frame (65,535 B) stays relayable                        | 128 KiB            |
///
/// A future type that needs more than a v1 frame must be added here before it
/// ships, or current receivers will drop it at decode.
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

    /// Everything a frame can carry besides its payload: the v2 header, the
    /// sender and recipient, the widest route the decoder accepts (255 hops),
    /// the compressed-size field, the signature, and the most padding
    /// `MessagePadding` adds (iOS fragments the padded frame).
    private static let maxFrameOverheadBytes = BinaryProtocol.v2HeaderSize
        + BinaryProtocol.senderIDSize
        + BinaryProtocol.recipientIDSize
        + 1 + Int(UInt8.max) * BinaryProtocol.senderIDSize
        + 4
        + BinaryProtocol.signatureSize
        + Int(UInt8.max)

    /// Largest decoded payload accepted for a packet of `type`, whether it
    /// arrived compressed or not.
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

    /// Largest encoded frame, padding included, that can still decode as a
    /// packet of `type`. Fragment reassembly holds an assembly to this for
    /// the type its fragments claim, so it never buffers more than the
    /// reassembled packet would be allowed to decode to.
    public static func maxFrameBytes(forType type: UInt8) -> Int {
        maxPayloadBytes(forType: type) + maxFrameOverheadBytes
    }
}

import Foundation

/// Centralized thresholds for Bluetooth file transfers to keep payload sizes sane on constrained radios.
enum FileTransferLimits {
    /// Absolute ceiling enforced for any file payload (voice, image, other).
    static let maxPayloadBytes: Int = 1 * 1024 * 1024 // 1 MiB
    /// Voice notes stay small for low-latency relays.
    static let maxVoiceNoteBytes: Int = 512 * 1024 // 512 KiB
    /// Compressed images after downscaling should comfortably fit under this budget.
    static let maxImageBytes: Int = 512 * 1024 // 512 KiB
    /// Worst-case size once TLV metadata and binary packet framing are included for the largest payloads.
    static let maxFramedFileBytes: Int = {
        let maxMetadataBytes = Int(UInt16.max) * 2 // fileName + mimeType TLVs
        let tlvEnvelopeOverhead = 18 + maxMetadataBytes // TLV tags + lengths + metadata bytes
        let binaryEnvelopeOverhead = BinaryProtocol.v2HeaderSize
            + BinaryProtocol.senderIDSize
            + BinaryProtocol.recipientIDSize
            + BinaryProtocol.signatureSize
        return maxPayloadBytes + tlvEnvelopeOverhead + binaryEnvelopeOverhead
    }()

    static func isValidPayload(_ size: Int) -> Bool {
        size <= maxPayloadBytes
    }
}

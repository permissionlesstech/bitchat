/// Centralized thresholds for Bluetooth file transfers to keep payload sizes sane on constrained radios.
public enum FileTransferLimits {
    /// Absolute ceiling enforced for any file payload (voice, image, other).
    public static let maxPayloadBytes: Int = 1 * 1024 * 1024 // 1 MiB
    /// Voice notes stay small for low-latency relays.
    public static let maxVoiceNoteBytes: Int = 512 * 1024 // 512 KiB
    /// Compressed images after downscaling should comfortably fit under this budget.
    public static let maxImageBytes: Int = 512 * 1024 // 512 KiB
    /// Worst-case size once TLV metadata and binary packet framing are included for the largest payloads.
    public static let maxFramedFileBytes: Int = {
        let maxMetadataBytes = Int(UInt16.max) * 2 // fileName + mimeType TLVs
        let tlvEnvelopeOverhead = 18 + maxMetadataBytes // TLV tags + lengths + metadata bytes
        let binaryEnvelopeOverhead = BinaryProtocol.v2HeaderSize
            + BinaryProtocol.senderIDSize
            + BinaryProtocol.recipientIDSize
            + BinaryProtocol.signatureSize
        return maxPayloadBytes + tlvEnvelopeOverhead + binaryEnvelopeOverhead
    }()

    public static func isValidPayload(_ size: Int) -> Bool {
        size <= maxPayloadBytes
    }
}

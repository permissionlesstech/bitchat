/// Centralized thresholds for Bluetooth file transfers to keep payload sizes sane on constrained radios.
public enum FileTransferLimits {
    /// Absolute ceiling enforced for any file payload (voice, image, other).
    public static let maxPayloadBytes: Int = 1 * 1024 * 1024 // 1 MiB
    /// Voice notes stay small for low-latency relays.
    public static let maxVoiceNoteBytes: Int = 512 * 1024 // 512 KiB
    /// Compressed images after downscaling should comfortably fit under this budget.
    public static let maxImageBytes: Int = 512 * 1024 // 512 KiB
    /// Worst-case size once TLV metadata and binary packet framing are included for the largest payloads.
    ///
    /// Also the allocation bound for compressed mesh payloads in
    /// `BinaryProtocol.decodeCore`: a declared `originalSize` above this is
    /// rejected before `CompressionUtil.decompress` allocates. Android's
    /// `MAX_PAYLOAD_LENGTH` is currently 10 MiB, so a well-compressed Android
    /// packet can declare an original size iOS will refuse (#1618 / #1629).
    /// Raising this to match Android would let a ~210-byte compressed body
    /// force a ~10 MiB allocation on the more memory-constrained platform —
    /// the 50 000:1 ratio guard runs *after* the size check. Prefer keeping
    /// the tighter iOS bound (and logging the reject; see #1628) over growing
    /// the cheap remote allocation.
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

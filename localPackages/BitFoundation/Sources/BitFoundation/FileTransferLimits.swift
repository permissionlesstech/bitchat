/// Centralized thresholds for Bluetooth file transfers to keep payload sizes sane on constrained radios.
public enum FileTransferLimits {
    /// Absolute ceiling enforced for any file payload (voice, image, other).
    public static let maxPayloadBytes: Int = 1 * 1024 * 1024 // 1 MiB
    /// Voice notes stay small for low-latency relays.
    public static let maxVoiceNoteBytes: Int = 512 * 1024 // 512 KiB
    /// Compressed images after downscaling should comfortably fit under this budget.
    public static let maxImageBytes: Int = 512 * 1024 // 512 KiB
    /// Worst-case size once TLV metadata and binary packet framing are included for the largest payloads.
    /// MUST stay in sync with AppConstants.Protocol.MAX_PAYLOAD_LENGTH in the Android repo (issue #1618).
    public static let maxFramedFileBytes: Int = 10_485_760

    public static func isValidPayload(_ size: Int) -> Bool {
        size <= maxPayloadBytes
    }
}

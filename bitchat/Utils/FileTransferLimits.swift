import Foundation

/// Centralized thresholds for Bluetooth file transfers to keep payload sizes sane on constrained radios.
enum FileTransferLimits {
    /// Absolute ceiling enforced for any file payload (voice, image, other).
    static let maxPayloadBytes: Int = 1 * 1024 * 1024 // 1 MiB
    /// Voice notes stay small for low-latency relays.
    static let maxVoiceNoteBytes: Int = 1 * 1024 * 1024 // 1 MiB
    /// Compressed images after downscaling should comfortably fit under this budget.
    static let maxImageBytes: Int = 1 * 1024 * 1024 // 1 MiB

    static func isValidPayload(_ size: Int) -> Bool {
        size <= maxPayloadBytes
    }
}

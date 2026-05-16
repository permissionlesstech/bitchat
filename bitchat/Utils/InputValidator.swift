import Foundation
import BitLogger

/// Comprehensive input validation for BitChat protocol
/// Prevents injection attacks, buffer overflows, and malformed data
struct InputValidator {
    
    // MARK: - Constants
    
    struct Limits {
        static let maxNicknameLength = 50
        // BinaryProtocol caps payload length at UInt16.max (65_535). Leave headroom
        // for headers/padding by limiting user content to 60_000 bytes.
        static let maxMessageLength = 60_000
    }
    
    // MARK: - String Content Validation
    
    /// Validates and sanitizes user-provided strings used in UI
    ///
    /// Rejects strings containing control characters to prevent potential security issues
    /// and UI rendering problems. This strict approach ensures data integrity at input time.
    static func validateUserString(_ string: String, maxLength: Int) -> String? {
        guard let trimmed = string.trimmedOrNilIfEmpty, trimmed.count <= maxLength else { return nil }

        // Reject control characters outright instead of rewriting the string.
        // This prevents injection attacks and ensures consistent UI rendering.
        let controlChars = CharacterSet.controlCharacters
        if !trimmed.unicodeScalars.allSatisfy({ !controlChars.contains($0) }) {
            // Log rejection for monitoring, without exposing actual content for privacy
            let controlCharCount = trimmed.unicodeScalars.filter { controlChars.contains($0) }.count
            SecureLogger.debug(
                "Input validation rejected string (length: \(trimmed.count), control chars: \(controlCharCount))",
                category: .security
            )
            return nil
        }

        return trimmed
    }
    
    /// Validates nickname
    static func validateNickname(_ nickname: String) -> String? {
        return validateUserString(nickname, maxLength: Limits.maxNicknameLength)
    }
    
    // MARK: - Protocol Field Validation

    // Note: Message type validation is performed closer to decoding using
    // MessageType/NoisePayloadType enums; keeping validator free of stale lists.

    /// Validates timestamp is reasonable (not too far in past or future)
    /// BCH-01-011: Reduced from ±1 hour to ±5 minutes to limit replay attack window
    static func validateTimestamp(_ timestamp: Date) -> Bool {
        let now = Date()
        // 5 minutes = 300 seconds (industry standard for replay protection)
        let fiveMinutesAgo = now.addingTimeInterval(-300)
        let fiveMinutesFromNow = now.addingTimeInterval(300)
        return timestamp >= fiveMinutesAgo && timestamp <= fiveMinutesFromNow
    }

}

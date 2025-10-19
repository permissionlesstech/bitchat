import Foundation

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
    static func validateUserString(_ string: String, maxLength: Int) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count <= maxLength else { return nil }

        // Reject control characters outright instead of rewriting the string.
        let controlChars = CharacterSet.controlCharacters
        guard trimmed.unicodeScalars.allSatisfy({ !controlChars.contains($0) }) else { return nil }

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
    static func validateTimestamp(_ timestamp: Date) -> Bool {
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3600)
        let oneHourFromNow = now.addingTimeInterval(3600)
        return timestamp >= oneHourAgo && timestamp <= oneHourFromNow
    }

}

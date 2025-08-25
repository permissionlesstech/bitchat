import Foundation

/// Comprehensive input validation for BitChat protocol
/// Prevents injection attacks, buffer overflows, and malformed data
struct InputValidator {
    
    // MARK: - Constants
    
    struct Limits {
        static let maxNicknameLength = 50
        static let maxMessageLength = 10_000
        static let maxReasonLength = 200
        static let maxPeerIDLength = 64
        static let hexPeerIDLength = 16 // 8 bytes = 16 hex chars
    }
    
    // MARK: - Peer ID Validation
    
    /// Validates a peer ID from any source (short 16-hex, full 64-hex, or internal alnum/-/_ up to 64)
    static func validatePeerID(_ peerID: String) -> Bool {
        // Accept short routing IDs (exact 16-hex)
        if PeerIDResolver.isShortID(peerID) { return true }
        // If length equals short-hex length but isn't valid hex, reject
        if peerID.count == Limits.hexPeerIDLength { return false }
        // Accept full Noise key hex (exact 64-hex)
        if PeerIDResolver.isNoiseKeyHex(peerID) { return true }
        // If length equals full key length but isn't valid hex, reject
        if peerID.count == Limits.maxPeerIDLength { return false }
        // Internal format: alphanumeric + dash/underscore up to 63 (not 16 or 64)
        let validCharset = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return !peerID.isEmpty &&
               peerID.count < Limits.maxPeerIDLength &&
               peerID.rangeOfCharacter(from: validCharset.inverted) == nil
    }
    
    // MARK: - String Content Validation
    
    /// Validates and sanitizes user-provided strings (nicknames, messages)
    static func validateUserString(_ string: String, maxLength: Int, allowNewlines: Bool = false) -> String? {
        // Check empty
        guard !string.isEmpty else { return nil }
        
        // Trim whitespace
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        // Check length
        guard trimmed.count <= maxLength else { return nil }
        
        // Remove control characters except allowed ones
        var allowedControlChars = CharacterSet()
        if allowNewlines {
            allowedControlChars.insert(charactersIn: "\n\r")
        }
        
        let controlChars = CharacterSet.controlCharacters.subtracting(allowedControlChars)
        let cleaned = trimmed.components(separatedBy: controlChars).joined()
        
        // Ensure valid UTF-8 (should already be, but double-check)
        guard cleaned.data(using: .utf8) != nil else { return nil }
        
        // Prevent zero-width characters and other invisible unicode
        let invisibleChars = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{FEFF}")
        let visible = cleaned.components(separatedBy: invisibleChars).joined()
        
        return visible.isEmpty ? nil : visible
    }
    
    /// Validates nickname
    static func validateNickname(_ nickname: String) -> String? {
        return validateUserString(nickname, maxLength: Limits.maxNicknameLength, allowNewlines: false)
    }
    
    /// Validates message content
    static func validateMessageContent(_ content: String) -> String? {
        return validateUserString(content, maxLength: Limits.maxMessageLength, allowNewlines: true)
    }
    
    /// Validates error/reason strings
    static func validateReasonString(_ reason: String) -> String? {
        return validateUserString(reason, maxLength: Limits.maxReasonLength, allowNewlines: false)
    }
    
    // MARK: - Protocol Field Validation
    
    // Note: Message type validation is performed closer to decoding using
    // MessageType/NoisePayloadType enums; keeping validator free of stale lists.
    
    /// Validates hop count is reasonable
    static func validateHopCount(_ hopCount: UInt8) -> Bool {
        return hopCount <= 10 // Prevent excessive forwarding
    }
    
    /// Validates timestamp is reasonable (not too far in past or future)
    static func validateTimestamp(_ timestamp: Date) -> Bool {
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3600)
        let oneHourFromNow = now.addingTimeInterval(3600)
        return timestamp >= oneHourAgo && timestamp <= oneHourFromNow
    }
    
    /// Validates data size for different contexts
    static func validateDataSize(_ data: Data, maxSize: Int) -> Bool {
        return data.count > 0 && data.count <= maxSize
    }
    
    // MARK: - Binary Data Validation
    
    /// Validates UUID format
    static func validateUUID(_ uuid: String) -> Bool {
        // Remove dashes and validate hex
        let cleaned = uuid.replacingOccurrences(of: "-", with: "")
        return cleaned.count == 32 && cleaned.allSatisfy { $0.isHexDigit }
    }
    
    /// Validates public key data
    static func validatePublicKey(_ keyData: Data) -> Bool {
        // Curve25519 public keys are 32 bytes
        return keyData.count == 32
    }
    
    /// Validates signature data
    static func validateSignature(_ signature: Data) -> Bool {
        // Ed25519 signatures are 64 bytes
        return signature.count == 64
    }
}

// MARK: - Character Extensions

private extension Character {
    var isHexDigit: Bool {
        return "0123456789abcdefABCDEF".contains(self)
    }
}

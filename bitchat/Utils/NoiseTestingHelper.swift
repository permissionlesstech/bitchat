//
// NoiseTestingHelper.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

// MARK: - Encryption Status Enum
public enum EncryptionStatus {
    case noiseVerified    // Noise + fingerprint verified
    case noiseSecured     // Noise established
    case noiseHandshaking // Noise in progress
    case none             // No encryption
    
    var icon: String {
        switch self {
        case .noiseVerified:
            return "checkmark.shield.fill"  // Verified secure
        case .noiseSecured:
            return "lock.fill"               // Secure
        case .noiseHandshaking:
            return "lock.rotation"           // In progress
        // Legacy case removed
        case .none:
            return "lock.slash"              // Not secure
        }
    }
    
    var description: String {
        switch self {
        case .noiseVerified:
            return "Verified Secure"
        case .noiseSecured:
            return "Secure (Noise)"
        case .noiseHandshaking:
            return "Securing..."
        // Legacy case removed
        case .none:
            return "Not Encrypted"
        }
    }
}

// MARK: - Testing Helper for Noise Protocol Migration

#if DEBUG
class NoiseTestingHelper {
    static let shared = NoiseTestingHelper()
    
    // Test Scenarios Checklist
    struct TestScenario {
        let name: String
        let steps: [String]
        var passed: Bool = false
    }
    
    private var testScenarios: [TestScenario] = [
        TestScenario(
            name: "Basic Handshake",
            steps: [
                "1. Connect two devices via Bluetooth",
                "2. Verify Noise handshake completes (check logs)",
                "3. Confirm lock icon appears next to peer name",
                "4. Send a message and verify delivery"
            ]
        ),
        TestScenario(
            name: "Legacy Fallback",
            steps: [
                "1. Connect old app version to new version",
                "2. Verify legacy encryption still works",
                "3. Check for warning icon (not fully secure)",
                "4. Messages should still deliver"
            ]
        ),
        TestScenario(
            name: "Fingerprint Verification",
            steps: [
                "1. Long-press on peer name to see fingerprint",
                "2. Compare fingerprints on both devices",
                "3. Mark as verified",
                "4. Check for verified checkmark"
            ]
        ),
        TestScenario(
            name: "Channel Encryption",
            steps: [
                "1. Create password-protected channel",
                "2. Join from another device",
                "3. Send messages to channel",
                "4. Verify only members can decrypt"
            ]
        ),
        TestScenario(
            name: "Session Recovery",
            steps: [
                "1. Establish Noise session",
                "2. Force quit app",
                "3. Reopen and reconnect",
                "4. Verify session re-establishes automatically"
            ]
        ),
        TestScenario(
            name: "Rate Limiting",
            steps: [
                "1. Send many messages rapidly",
                "2. Verify rate limit kicks in after 100 msgs/sec",
                "3. Wait and verify messaging resumes",
                "4. Check no messages lost"
            ]
        ),
        TestScenario(
            name: "Panic Mode",
            steps: [
                "1. Establish sessions with peers",
                "2. Trigger panic mode (shake device)",
                "3. Verify all keys cleared",
                "4. Check new identity generated on restart"
            ]
        )
    ]
    
    // Debug logging for Noise events
    func logNoiseEvent(_ event: String, details: Any? = nil) {
        // Logging removed - keeping method signature for compatibility
    }
    
    // Get encryption status for peer
    func getEncryptionStatus(for peerID: String, noiseService: NoiseEncryptionService) -> EncryptionStatus {
        if noiseService.hasEstablishedSession(with: peerID) {
            // Check if fingerprint is verified
            if let fingerprint = noiseService.getPeerFingerprint(peerID),
               isFingerprinted(peerID: peerID, fingerprint: fingerprint) {
                return .noiseVerified
            }
            return .noiseSecured
        } else {
            // Always use Noise - no legacy encryption
            return .noiseHandshaking
        }
    }
    
    // Store verified fingerprints (in production, use Keychain)
    private var verifiedFingerprints: [String: String] = [:]
    
    func verifyFingerprint(peerID: String, fingerprint: String) {
        verifiedFingerprints[peerID] = fingerprint
    }
    
    func isFingerprinted(peerID: String, fingerprint: String) -> Bool {
        return verifiedFingerprints[peerID] == fingerprint
    }
    
    // Format fingerprint for display
    func formatFingerprint(_ fingerprint: String) -> String {
        // Convert to uppercase and format into 2 lines (8 groups of 4 on each line)
        let uppercased = fingerprint.uppercased()
        var formatted = ""
        
        for (index, char) in uppercased.enumerated() {
            // Add space every 4 characters (but not at the start)
            if index > 0 && index % 4 == 0 {
                // Add newline after 32 characters (8 groups of 4)
                if index == 32 {
                    formatted += "\n"
                } else {
                    formatted += " "
                }
            }
            formatted += String(char)
        }
        
        return formatted
    }
    
    // Get test scenario checklist
    func getTestChecklist() -> String {
        var checklist = "NOISE PROTOCOL TEST CHECKLIST\n"
        checklist += "=" .repeated(30) + "\n\n"
        
        for scenario in testScenarios {
            checklist += "□ \(scenario.name)\n"
            for step in scenario.steps {
                checklist += "  \(step)\n"
            }
            checklist += "\n"
        }
        
        return checklist
    }
}

// String extension for repeating
extension String {
    func repeated(_ count: Int) -> String {
        return String(repeating: self, count: count)
    }
}
#endif
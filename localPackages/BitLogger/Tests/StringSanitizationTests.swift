//
//  StringSanitizationTests.swift
//  BitLogger
//
//  Created by Islam on 19/10/2025.
//

import Testing
@testable import BitLogger

struct StringSanitizationTests {
    
    @Test("64-hex fingerprint is truncated to first 8 chars followed by ellipsis")
    func fingerprintTruncation() async throws {
        let fingerprint = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        #expect(fingerprint.count == 64)
        
        let input = "fingerprint=\(fingerprint)"
        let output = input.sanitized()
        
        #expect(output.contains("fingerprint=01234567..."))
        // Ensure no full fingerprint remains
        #expect(output.contains(fingerprint) == false)
    }
    
    @Test("Multiple fingerprints in a string are all truncated")
    func multipleFingerprintTruncation() async throws {
        let fp1 = String(repeating: "a", count: 64)
        let fp2 = String(repeating: "b", count: 64)
        let input = "fp1=\(fp1) fp2=\(fp2)"
        let output = input.sanitized()
        #expect(output.contains("fp1=aaaaaaaa..."))
        #expect(output.contains("fp2=bbbbbbbb..."))
        #expect(output.contains(fp1) == false)
        #expect(output.contains(fp2) == false)
    }
    
    @Test("Base64-like long data is replaced with <base64-data>")
    func base64Replacement() async throws {
        // 44+ chars of base64 characters
        let base64ish = "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo5ODc2NTQzMjE="
        let input = "payload=\(base64ish)"
        let output = input.sanitized()
        #expect(output == "payload=<base64-data>")
    }
    
    @Test("Base64-like without padding is replaced with <base64-data>")
    func base64NoPaddingReplacement() async throws {
        let base64ish = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        #expect(base64ish.count >= 40)
        let input = "b64:\(base64ish)"
        let output = input.sanitized()
        #expect(output == "b64:<base64-data>")
    }
    
    @Test("Short base64-like strings (below threshold) are not replaced")
    func shortBase64NotReplaced() async throws {
        let short = "QUJDREVGR0hJSktMTU5P" // < 40 chars
        let input = "payload=\(short)"
        let output = input.sanitized()
        #expect(output == input)
    }
    
    @Test("Password redaction for key:value formats", arguments: [
        "password: secret123",
        "password=secret123",
        "password = secret123",
        "password: 'secret123'",
        "password:\"secret123\"",
        "password='secret123'"
    ])
    func passwordRedactionKeyValue(password: String) async throws {
        #expect(password.sanitized() == "password: <redacted>")
    }
    
    @Test("Password redaction inside wider messages")
    func passwordRedactionInContext() async throws {
        let input = "user=john password: 'p@ssW0rd' attempt=1"
        let output = input.sanitized()
        #expect(output == "user=john password: <redacted> attempt=1")
    }
    
    @Test("PeerID is truncated to first 8 chars followed by ellipsis")
    func peerIDTruncation() async throws {
        let peer = "ABCDEF12GHIJKL34"
        let input = "peerID: \(peer)"
        let output = input.sanitized()
        #expect(output == "peerID: ABCDEF12...")
    }
    
    @Test("PeerID not truncated when exactly 8 chars")
    func peerIDExactlyEightNotTruncated() async throws {
        let peer = "ABCDEF12"
        let input = "peerID: \(peer)"
        let output = input.sanitized()
        // Pattern only matches when there are more than 8 trailing chars, so unchanged
        #expect(output == input)
    }
    
    @Test("Non-matching content remains unchanged")
    func nonMatchingUnchanged() async throws {
        let input = "Hello world 123 - nothing sensitive here."
        let output = input.sanitized()
        #expect(output == input)
    }
    
    @Test("Idempotency: sanitizing twice yields same result")
    func idempotentSanitization() async throws {
        let input = """
        fingerprint=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
        password: "superSecret" \
        peerID: ZYXWVUT987654321 \
        payload=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/
        """
        let once = input.sanitized()
        let twice = once.sanitized()
        #expect(once == twice)
    }
    
    @Test("Mixed content: all rules apply in a single string")
    func mixedContent() async throws {
        let fingerprint = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
        let base64ish = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        let peer = "PEERID01EXTRA"
        let input = "fp=\(fingerprint) password='x' peerID: \(peer) data=\(base64ish)"
        let output = input.sanitized()
        #expect(output.contains("fp=fedcba98..."))
        #expect(output.contains("password: <redacted>"))
        #expect(output.contains("peerID: PEERID01..."))
        #expect(output.contains("data=<base64-data>"))
        #expect(output.contains(fingerprint) == false)
        #expect(output.contains(base64ish) == false)
    }
    
    @Test("Cache returns consistent result for repeated inputs")
    func cacheHitConsistency() async throws {
        let input = "password: hunter2"
        let first = input.sanitized()
        let second = input.sanitized()
        #expect(first == "password: <redacted>")
        #expect(first == second)
    }
}

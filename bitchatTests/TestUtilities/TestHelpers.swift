//
// TestHelpers.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CryptoKit
@testable import bitchat

class TestHelpers {
    
    // MARK: - Key Generation
    
    static func generateTestKeyPair() -> (privateKey: Curve25519.KeyAgreement.PrivateKey, publicKey: Curve25519.KeyAgreement.PublicKey) {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey
        return (privateKey, publicKey)
    }
    
    static func generateTestIdentity(peerID: String, nickname: String) -> (peerID: String, nickname: String, privateKey: Curve25519.KeyAgreement.PrivateKey, publicKey: Curve25519.KeyAgreement.PublicKey) {
        let (privateKey, publicKey) = generateTestKeyPair()
        return (peerID: peerID, nickname: nickname, privateKey: privateKey, publicKey: publicKey)
    }
    
    // MARK: - Message Creation
    
    static func createTestMessage(
        content: String = TestConstants.testMessage1,
        sender: String = TestConstants.testNickname1,
        senderPeerID: String = TestConstants.testPeerID1,
        isPrivate: Bool = false,
        recipientNickname: String? = nil,
        mentions: [String]? = nil
    ) -> BitchatMessage {
        return BitchatMessage(
            id: UUID().uuidString,
            sender: sender,
            content: content,
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: isPrivate,
            recipientNickname: recipientNickname,
            senderPeerID: senderPeerID,
            mentions: mentions
        )
    }
    
    static func createTestPacket(
        type: UInt8 = 0x01,
        senderID: String = TestConstants.testPeerID1,
        recipientID: String? = nil,
        payload: Data = "test payload".data(using: .utf8)!,
        signature: Data? = nil,
        ttl: UInt8 = 3
    ) -> BitchatPacket {
        return BitchatPacket(
            type: type,
            senderID: senderID.data(using: .utf8)!,
            recipientID: recipientID?.data(using: .utf8),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: signature,
            ttl: ttl
        )
    }
    
    // MARK: - Data Generation
    
    static func generateRandomData(length: Int) -> Data {
        var data = Data(count: length)
        _ = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, length, bytes.baseAddress!)
        }
        return data
    }
    
    static func generateTestPeerID() -> String {
        return "PEER" + UUID().uuidString.prefix(8)
    }
    
    // MARK: - Async Helpers
    
    static func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = TestConstants.defaultTimeout) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout {
                throw TestError.timeout
            }
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }
    
    static func expectAsync<T>(
        timeout: TimeInterval = TestConstants.defaultTimeout,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                return try await operation()
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw TestError.timeout
            }
            
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

enum TestError: Error {
    case timeout
    case unexpectedValue
    case testFailure(String)
}
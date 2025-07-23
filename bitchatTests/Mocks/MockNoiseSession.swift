//
// MockNoiseSession.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CryptoKit
@testable import bitchat

class MockNoiseSession: NoiseSession {
    var mockState: NoiseSessionState = .uninitialized
    var shouldFailHandshake = false
    var shouldFailEncryption = false
    var handshakeMessages: [Data] = []
    var encryptedData: [Data] = []
    var decryptedData: [Data] = []
    
    override func getState() -> NoiseSessionState {
        return mockState
    }
    
    override func isEstablished() -> Bool {
        return mockState == .established
    }
    
    override func startHandshake() throws -> Data {
        if shouldFailHandshake {
            mockState = .failed(NoiseSessionError.handshakeFailed(TestError.testFailure("Mock handshake failure")))
            throw NoiseSessionError.handshakeFailed(TestError.testFailure("Mock handshake failure"))
        }
        
        mockState = .handshaking
        let handshakeData = TestHelpers.generateRandomData(length: 32)
        handshakeMessages.append(handshakeData)
        return handshakeData
    }
    
    override func processHandshakeMessage(_ message: Data) throws -> Data? {
        if shouldFailHandshake {
            mockState = .failed(NoiseSessionError.handshakeFailed(TestError.testFailure("Mock handshake failure")))
            throw NoiseSessionError.handshakeFailed(TestError.testFailure("Mock handshake failure"))
        }
        
        handshakeMessages.append(message)
        
        // Simulate handshake completion after 2 messages
        if handshakeMessages.count >= 2 {
            mockState = .established
            return nil
        } else {
            let response = TestHelpers.generateRandomData(length: 48)
            handshakeMessages.append(response)
            return response
        }
    }
    
    override func encrypt(_ plaintext: Data) throws -> Data {
        if shouldFailEncryption {
            throw NoiseSessionError.notEstablished
        }
        
        guard mockState == .established else {
            throw NoiseSessionError.notEstablished
        }
        
        // Simple mock encryption: prepend magic bytes and append the data
        var encrypted = Data([0xDE, 0xAD, 0xBE, 0xEF])
        encrypted.append(plaintext)
        encryptedData.append(encrypted)
        return encrypted
    }
    
    override func decrypt(_ ciphertext: Data) throws -> Data {
        if shouldFailEncryption {
            throw NoiseSessionError.notEstablished
        }
        
        guard mockState == .established else {
            throw NoiseSessionError.notEstablished
        }
        
        // Simple mock decryption: remove magic bytes
        guard ciphertext.count > 4 else {
            throw TestError.testFailure("Invalid ciphertext")
        }
        
        let plaintext = ciphertext.dropFirst(4)
        decryptedData.append(plaintext)
        return plaintext
    }
    
    override func reset() {
        mockState = .uninitialized
        handshakeMessages.removeAll()
        encryptedData.removeAll()
        decryptedData.removeAll()
    }
}
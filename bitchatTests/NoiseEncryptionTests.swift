//
// NoiseEncryptionTests.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
@testable import bitchat

struct NoiseEncryptionTests {
    @Test func generatesNewIdentityWhenMissing() throws {
        let keychain = MockKeychain()

        // Create service with empty keychain - should generate new identity
        let service = NoiseEncryptionService(keychain: keychain)

        // Should have generated and saved keys
        #expect(service.getStaticPublicKeyData().count == 32)
        #expect(service.getSigningPublicKeyData().count == 32)

        // Keys should be persisted
        let noiseKeyResult = keychain.getIdentityKeyWithResult(forKey: "noiseStaticKey")
        switch noiseKeyResult {
        case .success:
            // Expected - key was saved
            break
        default:
            throw KeychainTestError("Expected noise key to be saved")
        }
    }

    @Test func loadsExistingIdentity() throws {
        let keychain = MockKeychain()

        // Create first service to generate identity
        let service1 = NoiseEncryptionService(keychain: keychain)
        let originalPublicKey = service1.getStaticPublicKeyData()
        let originalSigningKey = service1.getSigningPublicKeyData()

        // Create second service - should load same identity
        let service2 = NoiseEncryptionService(keychain: keychain)

        #expect(service2.getStaticPublicKeyData() == originalPublicKey)
        #expect(service2.getSigningPublicKeyData() == originalSigningKey)
    }

    @Test func handlesAccessDeniedGracefully() throws {
        let keychain = MockKeychain()
        keychain.simulatedReadError = .accessDenied

        // Service should still initialize with ephemeral key
        let service = NoiseEncryptionService(keychain: keychain)

        // Should have an identity (ephemeral)
        #expect(service.getStaticPublicKeyData().count == 32)
        #expect(service.getSigningPublicKeyData().count == 32)
    }

    @Test func handlesDeviceLockedGracefully() throws {
        let keychain = MockKeychain()
        keychain.simulatedReadError = .deviceLocked

        // Service should still initialize with ephemeral key
        let service = NoiseEncryptionService(keychain: keychain)

        // Should have an identity (ephemeral)
        #expect(service.getStaticPublicKeyData().count == 32)
    }
}

// TODO: Reuse
private struct KeychainTestError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

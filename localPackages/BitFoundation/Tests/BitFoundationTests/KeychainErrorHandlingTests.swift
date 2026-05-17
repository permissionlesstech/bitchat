//
// KeychainErrorHandlingTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//
// BCH-01-009: Tests for proper keychain error classification and handling

import Testing
import Foundation
import BitFoundation

struct KeychainErrorHandlingTests {

    // MARK: - Error Classification Tests

    @Test func keychainReadResult_successIsNotRecoverable() throws {
        let result = KeychainReadResult.success(Data([1, 2, 3]))
        #expect(result.isRecoverableError == false)
    }

    @Test func keychainReadResult_itemNotFoundIsNotRecoverable() throws {
        let result = KeychainReadResult.itemNotFound
        #expect(result.isRecoverableError == false)
    }

    @Test func keychainReadResult_deviceLockedIsRecoverable() throws {
        let result = KeychainReadResult.deviceLocked
        #expect(result.isRecoverableError == true)
    }

    @Test func keychainReadResult_authenticationFailedIsRecoverable() throws {
        let result = KeychainReadResult.authenticationFailed
        #expect(result.isRecoverableError == true)
    }

    @Test func keychainReadResult_accessDeniedIsNotRecoverable() throws {
        let result = KeychainReadResult.accessDenied
        #expect(result.isRecoverableError == false)
    }

    @Test func keychainSaveResult_successIsNotRecoverable() throws {
        let result = KeychainSaveResult.success
        #expect(result.isRecoverableError == false)
    }

    @Test func keychainSaveResult_duplicateItemIsRecoverable() throws {
        let result = KeychainSaveResult.duplicateItem
        #expect(result.isRecoverableError == true)
    }

    @Test func keychainSaveResult_deviceLockedIsRecoverable() throws {
        let result = KeychainSaveResult.deviceLocked
        #expect(result.isRecoverableError == true)
    }

    @Test func keychainSaveResult_storageFullIsNotRecoverable() throws {
        let result = KeychainSaveResult.storageFull
        #expect(result.isRecoverableError == false)
    }

    // MARK: - Mock Keychain Error Simulation Tests

    @Test func mockKeychain_canSimulateReadErrors() throws {
        let keychain = MockKeychain()

        // Simulate access denied error
        keychain.simulatedReadError = .accessDenied
        let result = keychain.getIdentityKeyWithResult(forKey: "testKey")

        switch result {
        case .accessDenied:
            // Expected
            break
        default:
            throw KeychainTestError("Expected accessDenied, got \(result)")
        }
    }

    @Test func mockKeychain_canSimulateSaveErrors() throws {
        let keychain = MockKeychain()

        // Simulate storage full error
        keychain.simulatedSaveError = .storageFull
        let result = keychain.saveIdentityKeyWithResult(Data([1, 2, 3]), forKey: "testKey")

        switch result {
        case .storageFull:
            // Expected
            break
        default:
            throw KeychainTestError("Expected storageFull, got \(result)")
        }
    }

    @Test func mockKeychain_returnsItemNotFoundForMissingKey() throws {
        let keychain = MockKeychain()
        let result = keychain.getIdentityKeyWithResult(forKey: "nonExistentKey")

        switch result {
        case .itemNotFound:
            // Expected
            break
        default:
            throw KeychainTestError("Expected itemNotFound, got \(result)")
        }
    }

    @Test func mockKeychain_returnsSuccessForExistingKey() throws {
        let keychain = MockKeychain()
        let testData = Data([1, 2, 3, 4, 5])

        // First save the key
        _ = keychain.saveIdentityKey(testData, forKey: "existingKey")

        // Now read it back
        let result = keychain.getIdentityKeyWithResult(forKey: "existingKey")

        switch result {
        case .success(let data):
            #expect(data == testData)
        default:
            throw KeychainTestError("Expected success, got \(result)")
        }
    }

    @Test func mockKeychain_saveWithResultStoresData() throws {
        let keychain = MockKeychain()
        let testData = Data([10, 20, 30])

        let saveResult = keychain.saveIdentityKeyWithResult(testData, forKey: "newKey")

        switch saveResult {
        case .success:
            // Verify data was stored
            let readResult = keychain.getIdentityKeyWithResult(forKey: "newKey")
            switch readResult {
            case .success(let data):
                #expect(data == testData)
            default:
                throw KeychainTestError("Expected to read back saved data")
            }
        default:
            throw KeychainTestError("Expected save success, got \(saveResult)")
        }
    }
}

// Helper error type for tests
private struct KeychainTestError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

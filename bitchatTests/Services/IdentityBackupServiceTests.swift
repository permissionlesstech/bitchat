//
// IdentityBackupServiceTests.swift
// bitchatTests
//

import BitFoundation
import CryptoKit
import Foundation
import Testing
@testable import bitchat

struct IdentityBackupServiceTests {

    private func sampleMaterial(keychain: MockKeychain = MockKeychain()) throws -> IdentityKeyMaterial {
        let noise = NoiseEncryptionService(keychain: keychain)
        let keys = noise.exportPersistentPrivateKeys()
        let nostr = try NostrIdentity.generate()
        var seed = Data(count: 32)
        seed.withUnsafeMutableBytes { ptr in
            _ = SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
        }
        return try IdentityKeyMaterial(
            noiseStaticPrivateKey: keys.noiseStatic,
            ed25519SigningPrivateKey: keys.ed25519Signing,
            nostrPrivateKey: nostr.privateKey,
            nostrDeviceSeed: seed
        ).validated()
    }

    @Test func roundTripEncryptDecryptPreservesKeys() throws {
        let material = try sampleMaterial()
        let passphrase = "correct-horse-battery-staple-extra"
        let uri = try IdentityBackupService.encrypt(material, passphrase: passphrase)

        #expect(uri.hasPrefix("bitchat://identity-backup/v1/"))
        #expect(uri.utf8.count < 600)

        let restored = try IdentityBackupService.decrypt(uri, passphrase: passphrase)
        #expect(restored == material)

        let restoredFP = try IdentityBackupService.fingerprint(of: restored)
        let originalFP = try IdentityBackupService.fingerprint(of: material)
        #expect(restoredFP == originalFP)
        #expect(restoredFP.count == 64)
    }

    @Test func compactTokenRoundTrip() throws {
        let material = try sampleMaterial()
        let passphrase = "twelve-chars-min"
        let uri = try IdentityBackupService.encrypt(material, passphrase: passphrase)
        let token = try IdentityBackupService.compactToken(fromURI: uri)
        #expect(token.hasPrefix("bitchat1id:"))

        let restored = try IdentityBackupService.decrypt(token, passphrase: passphrase)
        #expect(restored == material)
    }

    @Test func wrongPassphraseFails() throws {
        let material = try sampleMaterial()
        let uri = try IdentityBackupService.encrypt(material, passphrase: "right-passphrase-ok")
        #expect(throws: IdentityBackupError.decryptionFailed) {
            _ = try IdentityBackupService.decrypt(uri, passphrase: "wrong-passphrase-ok")
        }
    }

    @Test func weakPassphraseRejected() {
        #expect(throws: IdentityBackupError.weakPassphrase) {
            try IdentityBackupService.validatePassphrase("short", confirm: "short")
        }
    }

    @Test func passphraseMismatchRejected() {
        #expect(throws: IdentityBackupError.passphraseMismatch) {
            try IdentityBackupService.validatePassphrase(
                "long-enough-pass",
                confirm: "different-pass-1"
            )
        }
    }

    @Test func garbagePayloadRejected() {
        #expect(throws: IdentityBackupError.invalidPayload) {
            _ = try IdentityBackupService.decrypt("not-a-backup", passphrase: "long-enough-pass")
        }
    }

    @Test func fingerprintMatchesNoiseService() throws {
        let keychain = MockKeychain()
        let noise = NoiseEncryptionService(keychain: keychain)
        let keys = noise.exportPersistentPrivateKeys()
        let nostr = try NostrIdentity.generate()
        var seed = Data(count: 32)
        seed.withUnsafeMutableBytes { ptr in
            _ = SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
        }
        let fromLive = try IdentityKeyMaterial(
            noiseStaticPrivateKey: keys.noiseStatic,
            ed25519SigningPrivateKey: keys.ed25519Signing,
            nostrPrivateKey: nostr.privateKey,
            nostrDeviceSeed: seed
        ).validated()
        let backupFP = try IdentityBackupService.fingerprint(of: fromLive)
        #expect(backupFP == noise.getIdentityFingerprint())
    }

    @Test func nostrBridgeInstallRestoresPrimaryAndSeed() throws {
        let keychain = MockKeychain()
        let bridge = NostrIdentityBridge(keychain: keychain)
        let original = try #require(try bridge.getCurrentNostrIdentity())
        let seed = bridge.exportDeviceSeed()

        let otherKeychain = MockKeychain()
        let other = NostrIdentityBridge(keychain: otherKeychain)
        let installed = try other.installRestoredIdentity(
            privateKey: original.privateKey,
            deviceSeed: seed
        )
        #expect(installed.npub == original.npub)
        #expect(other.exportDeviceSeed() == seed)

        let again = try #require(try other.getCurrentNostrIdentity())
        #expect(again.privateKey == original.privateKey)
    }

    @Test func suggestPassphraseIsLongEnough() {
        let suggested = IdentityBackupService.suggestPassphrase()
        #expect(suggested.count >= IdentityBackupService.minimumPassphraseLength)
        #expect(suggested.contains("-"))
    }

    @Test func normalizeAcceptsBareBase64URL() throws {
        let material = try sampleMaterial()
        let passphrase = "twelve-chars-min"
        let uri = try IdentityBackupService.encrypt(material, passphrase: passphrase)
        let token = try #require(URL(string: uri)?.pathComponents.last)
        let restored = try IdentityBackupService.decrypt(token, passphrase: passphrase)
        #expect(restored == material)
    }
}

struct IdentityBackupInstallTests {
    @Test func noiseServiceLoadsImportedKeys() throws {
        let keychain = MockKeychain()
        let original = NoiseEncryptionService(keychain: keychain)
        let exported = original.exportPersistentPrivateKeys()
        let fingerprint = original.getIdentityFingerprint()
        let staticPub = original.getStaticPublicKeyData()
        let signingPub = original.getSigningPublicKeyData()

        // Simulate clear + reinstall on a fresh service lifetime.
        #expect(keychain.deleteIdentityKey(forKey: "noiseStaticKey"))
        #expect(keychain.deleteIdentityKey(forKey: "ed25519SigningKey"))
        let noiseSave = keychain.saveIdentityKeyWithResult(exported.noiseStatic, forKey: "noiseStaticKey")
        let signingSave = keychain.saveIdentityKeyWithResult(exported.ed25519Signing, forKey: "ed25519SigningKey")
        guard case .success = noiseSave, case .success = signingSave else {
            Issue.record("Failed to save restored keys")
            return
        }

        let restored = NoiseEncryptionService(keychain: keychain)
        #expect(restored.getIdentityFingerprint() == fingerprint)
        #expect(restored.getStaticPublicKeyData() == staticPub)
        #expect(restored.getSigningPublicKeyData() == signingPub)
    }
}

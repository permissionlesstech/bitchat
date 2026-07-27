//
// IdentityBackupService.swift
// bitchat
//
// Passphrase-encrypted export/import of the long-lived cryptographic identity.
// Scope matches issue #183 v1: migrate Noise static + Ed25519 signing + Nostr
// primary (+ device seed) to another device. Concurrent multi-device use of the
// same backup is unsupported and warned about in the UI.
//

import BitFoundation
import CommonCrypto
import CryptoKit
import Foundation

/// Raw private key material that makes one BitChat identity portable.
struct IdentityKeyMaterial: Equatable, Sendable {
    /// Curve25519.KeyAgreement private key (32 bytes).
    var noiseStaticPrivateKey: Data
    /// Curve25519.Signing private key (32 bytes).
    var ed25519SigningPrivateKey: Data
    /// secp256k1 Schnorr private key for the primary Nostr identity (32 bytes).
    var nostrPrivateKey: Data
    /// HMAC seed used to derive per-geohash Nostr identities (32 bytes).
    var nostrDeviceSeed: Data

    static let keyByteCount = 32
    static let plaintextByteCount = keyByteCount * 4

    func validated() throws -> IdentityKeyMaterial {
        guard noiseStaticPrivateKey.count == Self.keyByteCount,
              ed25519SigningPrivateKey.count == Self.keyByteCount,
              nostrPrivateKey.count == Self.keyByteCount,
              nostrDeviceSeed.count == Self.keyByteCount else {
            throw IdentityBackupError.invalidKeyMaterial
        }
        // Reject all-zero seeds / keys (almost certainly corruption).
        let parts = [
            noiseStaticPrivateKey,
            ed25519SigningPrivateKey,
            nostrPrivateKey,
            nostrDeviceSeed
        ]
        for part in parts where part.allSatisfy({ $0 == 0 }) {
            throw IdentityBackupError.invalidKeyMaterial
        }
        // CryptoKit / P256K will throw if the curve points are invalid.
        _ = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: noiseStaticPrivateKey)
        _ = try Curve25519.Signing.PrivateKey(rawRepresentation: ed25519SigningPrivateKey)
        _ = try NostrIdentity(privateKeyData: nostrPrivateKey)
        return self
    }

    func encodePlaintext() -> Data {
        var data = Data(capacity: Self.plaintextByteCount)
        data.append(noiseStaticPrivateKey)
        data.append(ed25519SigningPrivateKey)
        data.append(nostrPrivateKey)
        data.append(nostrDeviceSeed)
        return data
    }

    static func decodePlaintext(_ data: Data) throws -> IdentityKeyMaterial {
        guard data.count == plaintextByteCount else {
            throw IdentityBackupError.invalidPayload
        }
        let n = keyByteCount
        return try IdentityKeyMaterial(
            noiseStaticPrivateKey: data.subdata(in: 0..<n),
            ed25519SigningPrivateKey: data.subdata(in: n..<(2 * n)),
            nostrPrivateKey: data.subdata(in: (2 * n)..<(3 * n)),
            nostrDeviceSeed: data.subdata(in: (3 * n)..<(4 * n))
        ).validated()
    }
}

enum IdentityBackupError: Error, Equatable, LocalizedError {
    case weakPassphrase
    case passphraseMismatch
    case invalidPayload
    case invalidKeyMaterial
    case decryptionFailed
    case unsupportedVersion
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .weakPassphrase:
            return String(
                localized: "identity_backup.error.weak_passphrase",
                defaultValue: "passphrase must be at least 12 characters",
                comment: "Error when the backup passphrase is too short"
            )
        case .passphraseMismatch:
            return String(
                localized: "identity_backup.error.passphrase_mismatch",
                defaultValue: "passphrases do not match",
                comment: "Error when confirm-passphrase field differs from the first"
            )
        case .invalidPayload:
            return String(
                localized: "identity_backup.error.invalid_payload",
                defaultValue: "that doesn't look like an identity backup",
                comment: "Error when pasted/scanned backup text cannot be parsed"
            )
        case .invalidKeyMaterial:
            return String(
                localized: "identity_backup.error.invalid_keys",
                defaultValue: "backup contains invalid key material",
                comment: "Error when decrypted backup keys fail validation"
            )
        case .decryptionFailed:
            return String(
                localized: "identity_backup.error.decryption_failed",
                defaultValue: "could not decrypt — check the passphrase",
                comment: "Error when AES-GCM open fails (wrong passphrase or tampered backup)"
            )
        case .unsupportedVersion:
            return String(
                localized: "identity_backup.error.unsupported_version",
                defaultValue: "this backup was made by a newer bitchat; update the app",
                comment: "Error when backup envelope version is newer than we support"
            )
        case .encodingFailed:
            return String(
                localized: "identity_backup.error.encoding_failed",
                defaultValue: "failed to build the encrypted backup",
                comment: "Error when encrypting or encoding the backup envelope fails"
            )
        }
    }
}

/// Builds and opens passphrase-encrypted identity backup envelopes.
enum IdentityBackupService {
    static let uriScheme = "bitchat"
    static let uriHost = "identity-backup"
    static let uriVersionPath = "v1"
    /// Compact pasteable prefix (analogous to `bitchat1:` for Nostr packets).
    static let tokenPrefix = "bitchat1id:"
    static let minimumPassphraseLength = 12
    static let pbkdf2Iterations: UInt32 = 600_000
    static let saltByteCount = 16
    static let currentVersion: UInt8 = 1
    private static let magic = Data("BCID".utf8)
    private static let kdfPBKDF2SHA256: UInt8 = 1

    // MARK: - Fingerprint

    /// SHA-256 hex of the Noise static *public* key — matches live identity fingerprint.
    static func fingerprint(of material: IdentityKeyMaterial) throws -> String {
        let validated = try material.validated()
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: validated.noiseStaticPrivateKey
        )
        return privateKey.publicKey.rawRepresentation.sha256Fingerprint()
    }

    static func nostrNpub(of material: IdentityKeyMaterial) throws -> String {
        try NostrIdentity(privateKeyData: material.validated().nostrPrivateKey).npub
    }

    // MARK: - Passphrase helpers

    static func validatePassphrase(_ passphrase: String, confirm: String?) throws {
        let trimmed = passphrase
        guard trimmed.count >= minimumPassphraseLength else {
            throw IdentityBackupError.weakPassphrase
        }
        if let confirm, confirm != trimmed {
            throw IdentityBackupError.passphraseMismatch
        }
    }

    /// Suggests a high-entropy passphrase the user can write down (groups of base32).
    static func suggestPassphrase() -> String {
        var bytes = Data(count: 16)
        bytes.withUnsafeMutableBytes { ptr in
            _ = SecRandomCopyBytes(kSecRandomDefault, 16, ptr.baseAddress!)
        }
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var chars: [Character] = []
        chars.reserveCapacity(26)
        for (index, byte) in bytes.enumerated() {
            chars.append(alphabet[Int(byte % 32)])
            if index % 4 == 3, index != bytes.count - 1 {
                chars.append("-")
            }
        }
        return String(chars)
    }

    // MARK: - Encrypt / decrypt

    static func encrypt(
        _ material: IdentityKeyMaterial,
        passphrase: String
    ) throws -> String {
        try validatePassphrase(passphrase, confirm: nil)
        let plaintext = try material.validated().encodePlaintext()

        var salt = Data(count: saltByteCount)
        let saltStatus = salt.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, saltByteCount, ptr.baseAddress!)
        }
        guard saltStatus == errSecSuccess else {
            throw IdentityBackupError.encodingFailed
        }

        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: pbkdf2Iterations)
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(plaintext, using: key)
        } catch {
            throw IdentityBackupError.encodingFailed
        }
        guard let combined = sealed.combined else {
            throw IdentityBackupError.encodingFailed
        }

        var envelope = Data()
        envelope.append(magic)
        envelope.append(currentVersion)
        envelope.append(kdfPBKDF2SHA256)
        var iterationsBE = pbkdf2Iterations.bigEndian
        withUnsafeBytes(of: &iterationsBE) { envelope.append(contentsOf: $0) }
        envelope.append(salt)
        envelope.append(combined)

        let token = Base64URLCoding.encode(envelope)
        return "\(uriScheme)://\(uriHost)/\(uriVersionPath)/\(token)"
    }

    static func decrypt(_ backup: String, passphrase: String) throws -> IdentityKeyMaterial {
        try validatePassphrase(passphrase, confirm: nil)
        let envelope = try decodeEnvelopeData(from: backup)

        guard envelope.count > magic.count + 1 + 1 + 4 + saltByteCount + 12 + 16 else {
            throw IdentityBackupError.invalidPayload
        }
        guard envelope.prefix(magic.count) == magic else {
            throw IdentityBackupError.invalidPayload
        }

        var offset = magic.count
        let version = envelope[offset]
        offset += 1
        guard version == currentVersion else {
            throw IdentityBackupError.unsupportedVersion
        }

        let kdf = envelope[offset]
        offset += 1
        guard kdf == kdfPBKDF2SHA256 else {
            throw IdentityBackupError.unsupportedVersion
        }

        let iterations: UInt32 = envelope.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            UInt32(bigEndian: $0.load(as: UInt32.self))
        }
        offset += 4

        let salt = envelope.subdata(in: offset..<(offset + saltByteCount))
        offset += saltByteCount
        let combined = envelope.subdata(in: offset..<envelope.count)

        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.SealedBox(combined: combined)
        } catch {
            throw IdentityBackupError.invalidPayload
        }

        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(sealed, using: key)
        } catch {
            throw IdentityBackupError.decryptionFailed
        }

        return try IdentityKeyMaterial.decodePlaintext(plaintext)
    }

    /// Normalizes pasted/scanned text into the canonical URI string when possible.
    static func normalizeBackupString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(tokenPrefix) {
            let token = String(trimmed.dropFirst(tokenPrefix.count))
            return "\(uriScheme)://\(uriHost)/\(uriVersionPath)/\(token)"
        }
        return trimmed
    }

    /// Compact token form for copy/share (shorter than the URI, same payload).
    static func compactToken(fromURI uri: String) throws -> String {
        let data = try decodeEnvelopeData(from: uri)
        return tokenPrefix + Base64URLCoding.encode(data)
    }

    // MARK: - Private

    private static func decodeEnvelopeData(from backup: String) throws -> Data {
        let normalized = normalizeBackupString(backup)
        let token: String
        if let url = URL(string: normalized),
           url.scheme == uriScheme,
           url.host == uriHost {
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count >= 2, parts[0] == uriVersionPath else {
                throw IdentityBackupError.invalidPayload
            }
            token = parts[1]
        } else if normalized.hasPrefix(tokenPrefix) {
            token = String(normalized.dropFirst(tokenPrefix.count))
        } else {
            // Bare base64url envelope.
            token = normalized
        }

        guard let data = Base64URLCoding.decode(token), !data.isEmpty else {
            throw IdentityBackupError.invalidPayload
        }
        return data
    }

    private static func deriveKey(
        passphrase: String,
        salt: Data,
        iterations: UInt32
    ) throws -> SymmetricKey {
        let passwordData = Data(passphrase.utf8)
        var derived = Data(count: 32)
        let status = derived.withUnsafeMutableBytes { derivedPtr in
            salt.withUnsafeBytes { saltPtr in
                passwordData.withUnsafeBytes { passwordPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltPtr.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedPtr.bindMemory(to: UInt8.self).baseAddress,
                        32
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw IdentityBackupError.encodingFailed
        }
        return SymmetricKey(data: derived)
    }
}

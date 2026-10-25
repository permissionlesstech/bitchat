//
// IdentityCacheFixture.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CryptoKit
import Foundation
import BitFoundation
@testable import bitchat

/// The persisted state of a `SecureIdentityStateManager` with `count`
/// strangers already in its identity cache, built directly: one encode and
/// seal instead of `count` upserts, each of which would rewrite the whole
/// cache. Load it with `SecureIdentityStateManager(fixture.keychain)`.
struct IdentityCacheFixture {
    /// `SecureIdentityStateManager`'s keychain item names.
    static let encryptionKeyName = "identityCacheEncryptionKey"
    static let cacheKey = "bitchat.identityCache.v2"

    struct Stranger {
        let fingerprint: String
        let noisePublicKey: Data
        let signingPublicKey: Data
        let nickname: String
    }

    let keychain = MockKeychain()
    let strangers: [Stranger]

    /// - Parameter count: strangers in the cache, each with a crypto identity
    ///   and an auto-created social identity, as verified announces leave them.
    init(count: Int) throws {
        let keyData = Self.bytes(seed: 0x5EED, count: 32)
        _ = keychain.saveIdentityKey(keyData, forKey: Self.encryptionKeyName)

        var cache = IdentityCache()
        let firstSeenBase = Date(timeIntervalSince1970: 1_760_000_000)
        strangers = (0..<count).map { index in
            let noisePublicKey = Self.bytes(seed: index, count: 32)
            let stranger = Stranger(
                fingerprint: noisePublicKey.sha256Fingerprint(),
                noisePublicKey: noisePublicKey,
                signingPublicKey: Self.bytes(seed: 1_000_000 + index, count: 32),
                nickname: "stranger\(index)"
            )
            cache.cryptographicIdentities[stranger.fingerprint] = CryptographicIdentity(
                fingerprint: stranger.fingerprint,
                publicKey: stranger.noisePublicKey,
                signingPublicKey: stranger.signingPublicKey,
                firstSeen: firstSeenBase.addingTimeInterval(TimeInterval(index))
            )
            cache.socialIdentities[stranger.fingerprint] = SocialIdentity(
                fingerprint: stranger.fingerprint,
                localPetname: nil,
                claimedNickname: stranger.nickname,
                trustLevel: .unknown,
                isFavorite: false,
                isBlocked: false,
                notes: nil
            )
            return stranger
        }

        let sealed = try AES.GCM.seal(JSONEncoder().encode(cache), using: SymmetricKey(data: keyData))
        guard let combined = sealed.combined else { throw CocoaError(.coderInvalidValue) }
        _ = keychain.saveIdentityKey(combined, forKey: Self.cacheKey)
    }

    /// Identity-cache writes the keychain has seen, the fixture's own included.
    var cacheSaveCount: Int {
        keychain.identityKeySaveCounts[Self.cacheKey, default: 0]
    }

    /// Deterministic pseudo-random bytes (xorshift64).
    static func bytes(seed: Int, count: Int) -> Data {
        var state = UInt64(truncatingIfNeeded: seed) &* 0x9E37_79B9_7F4A_7C15 &+ 1
        return Data((0..<count).map { _ in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        })
    }
}

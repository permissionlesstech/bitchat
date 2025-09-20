//
// MockIdentityManager.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
@testable import bitchat

final class MockIdentityManager: SecureIdentityStateManagerProtocol {
    private let keychain: KeychainManagerProtocol
    
    init(_ keychain: KeychainManagerProtocol) {
        self.keychain = keychain
    }
    
    func loadIdentityCache() {}
    
    func saveIdentityCache() {}
    
    func forceSave() {}
    
    func getSocialIdentity(for fingerprint: String) -> SocialIdentity? {
        nil
    }
    
    func upsertCryptographicIdentity(fingerprint: String, noisePublicKey: Data, signingPublicKey: Data?, claimedNickname: String?) {}
    
    func getCryptoIdentitiesByPeerIDPrefix(_ peer: Peer) -> [CryptographicIdentity] {
        []
    }
    
    func updateSocialIdentity(_ identity: SocialIdentity) {}
    
    func getFavorites() -> Set<String> {
        Set()
    }
    
    func setFavorite(_ fingerprint: String, isFavorite: Bool) {}
    
    func isFavorite(fingerprint: String) -> Bool {
        false
    }
    
    func isBlocked(fingerprint: String) -> Bool {
        false
    }
    
    func setBlocked(_ fingerprint: String, isBlocked: Bool) {}
    
    func isNostrBlocked(pubkeyHexLowercased: String) -> Bool {
        true
    }
    
    func setNostrBlocked(_ pubkeyHexLowercased: String, isBlocked: Bool) {}
    
    func getBlockedNostrPubkeys() -> Set<String> {
        Set()
    }
    
    func registerEphemeralSession(peer: Peer, handshakeState: HandshakeState) {}
    
    func updateHandshakeState(peer: Peer, state: HandshakeState) {}
    
    func clearAllIdentityData() {}
    
    func removeEphemeralSession(peer: Peer) {}
    
    func setVerified(fingerprint: String, verified: Bool) {}
    
    func isVerified(fingerprint: String) -> Bool {
        true
    }
    
    func getVerifiedFingerprints() -> Set<String> {
        Set()
    }
}

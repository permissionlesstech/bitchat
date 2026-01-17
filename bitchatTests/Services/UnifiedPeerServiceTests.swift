//
// UnifiedPeerServiceTests.swift
// bitchatTests
//
// Tests for UnifiedPeerService fingerprint and block resolution.
//

import Testing
import Foundation
@testable import bitchat

struct UnifiedPeerServiceTests {

    @Test @MainActor
    func getFingerprint_prefersMeshService() async {
        let transport = MockTransport()
        let identity = TestIdentityManager()
        let idBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
        let service = UnifiedPeerService(meshService: transport, idBridge: idBridge, identityManager: identity)

        let peerID = PeerID(str: "00000000000000CC")
        transport.peerFingerprints[peerID] = "fp-1"

        let fingerprint = service.getFingerprint(for: peerID)

        #expect(fingerprint == "fp-1")
    }

    @Test @MainActor
    func isBlocked_usesSocialIdentity() async {
        let transport = MockTransport()
        let identity = TestIdentityManager()
        let idBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
        let service = UnifiedPeerService(meshService: transport, idBridge: idBridge, identityManager: identity)

        let peerID = PeerID(str: "00000000000000DD")
        let fingerprint = "fp-blocked"
        transport.peerFingerprints[peerID] = fingerprint
        identity.setBlocked(fingerprint, isBlocked: true)

        #expect(service.isBlocked(peerID))
    }
}

private final class TestIdentityManager: SecureIdentityStateManagerProtocol {
    private var socialIdentities: [String: SocialIdentity] = [:]
    private var favorites: Set<String> = []
    private var blockedNostr: Set<String> = []
    private var verified: Set<String> = []

    func forceSave() {}

    func getSocialIdentity(for fingerprint: String) -> SocialIdentity? {
        socialIdentities[fingerprint]
    }

    func upsertCryptographicIdentity(fingerprint: String, noisePublicKey: Data, signingPublicKey: Data?, claimedNickname: String?) {}

    func getCryptoIdentitiesByPeerIDPrefix(_ peerID: PeerID) -> [CryptographicIdentity] {
        []
    }

    func updateSocialIdentity(_ identity: SocialIdentity) {
        socialIdentities[identity.fingerprint] = identity
    }

    func getFavorites() -> Set<String> {
        favorites
    }

    func setFavorite(_ fingerprint: String, isFavorite: Bool) {
        if isFavorite {
            favorites.insert(fingerprint)
        } else {
            favorites.remove(fingerprint)
        }
    }

    func isFavorite(fingerprint: String) -> Bool {
        favorites.contains(fingerprint)
    }

    func isBlocked(fingerprint: String) -> Bool {
        socialIdentities[fingerprint]?.isBlocked ?? false
    }

    func setBlocked(_ fingerprint: String, isBlocked: Bool) {
        var identity = socialIdentities[fingerprint] ?? SocialIdentity(
            fingerprint: fingerprint,
            localPetname: nil,
            claimedNickname: "",
            trustLevel: .unknown,
            isFavorite: false,
            isBlocked: false,
            notes: nil
        )
        identity.isBlocked = isBlocked
        socialIdentities[fingerprint] = identity
    }

    func isNostrBlocked(pubkeyHexLowercased: String) -> Bool {
        blockedNostr.contains(pubkeyHexLowercased)
    }

    func setNostrBlocked(_ pubkeyHexLowercased: String, isBlocked: Bool) {
        if isBlocked {
            blockedNostr.insert(pubkeyHexLowercased)
        } else {
            blockedNostr.remove(pubkeyHexLowercased)
        }
    }

    func getBlockedNostrPubkeys() -> Set<String> {
        blockedNostr
    }

    func registerEphemeralSession(peerID: PeerID, handshakeState: HandshakeState) {}

    func updateHandshakeState(peerID: PeerID, state: HandshakeState) {}

    func clearAllIdentityData() {
        socialIdentities.removeAll()
        favorites.removeAll()
        blockedNostr.removeAll()
        verified.removeAll()
    }

    func removeEphemeralSession(peerID: PeerID) {}

    func setVerified(fingerprint: String, verified: Bool) {
        if verified {
            self.verified.insert(fingerprint)
        } else {
            self.verified.remove(fingerprint)
        }
    }

    func isVerified(fingerprint: String) -> Bool {
        verified.contains(fingerprint)
    }

    func getVerifiedFingerprints() -> Set<String> {
        verified
    }
}

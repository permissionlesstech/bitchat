//
// UnifiedPeerServiceTests.swift
// bitchatTests
//
// Tests for UnifiedPeerService fingerprint and block resolution.
//

import Testing
import Foundation
import BitFoundation
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

    @Test @MainActor
    func setBlocked_persistsByFingerprintAndToggles() async {
        let transport = MockTransport()
        let identity = TestIdentityManager()
        let idBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
        let service = UnifiedPeerService(meshService: transport, idBridge: idBridge, identityManager: identity)

        let peerID = PeerID(str: "00000000000000EE")
        let fingerprint = "fp-target"
        transport.peerFingerprints[peerID] = fingerprint

        // Blocking resolves and persists by the peer's fingerprint, and
        // scrubs the peer's carried public messages from the gossip archive
        // while the fingerprint↔peerID mapping is still known (the
        // archived-echo seed filter can't resolve offline strangers).
        let resolved = service.setBlocked(peerID, blocked: true)
        #expect(resolved == fingerprint)
        #expect(identity.isBlocked(fingerprint: fingerprint))
        #expect(service.isBlocked(peerID))
        #expect(transport.purgedArchivePeers == [peerID])

        // Unblocking clears it against the same identity, without purging.
        let unresolved = service.setBlocked(peerID, blocked: false)
        #expect(unresolved == fingerprint)
        #expect(!identity.isBlocked(fingerprint: fingerprint))
        #expect(!service.isBlocked(peerID))
        #expect(transport.purgedArchivePeers == [peerID])
    }

    // MARK: - Offline-favorite dedup (updatePeers phase 2)

    /// A mutual favorite that is also on the mesh must collapse to a single
    /// row keyed by the short mesh ID — even when the announced nickname no
    /// longer matches the one stored with the favorite.
    @Test @MainActor
    func updatePeers_mutualFavoriteOnMeshYieldsSingleRow() async {
        let favoritesService = FavoritesPersistenceService.shared

        let transport = MockTransport()
        let idBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
        let service = UnifiedPeerService(meshService: transport, idBridge: idBridge, identityManager: TestIdentityManager())

        let noiseKey = Data(repeating: 0xAB, count: 32)
        favoritesService.addFavorite(peerNoisePublicKey: noiseKey, peerNickname: "alice")
        favoritesService.updatePeerFavoritedUs(peerNoisePublicKey: noiseKey, favorited: true)
        defer {
            favoritesService.updatePeerFavoritedUs(peerNoisePublicKey: noiseKey, favorited: false)
            favoritesService.removeFavorite(peerNoisePublicKey: noiseKey)
        }

        let meshID = PeerID(publicKey: noiseKey)
        let snapshots = [TransportPeerSnapshot(
            peerID: meshID,
            nickname: "alice-renamed",
            isConnected: true,
            noisePublicKey: noiseKey,
            lastSeen: Date()
        )]
        transport.updatePeerSnapshots(snapshots)
        service.didUpdatePeerSnapshots(snapshots)

        let rows = service.peers.filter { $0.noisePublicKey == noiseKey }
        #expect(rows.count == 1)
        #expect(rows.first?.peerID == meshID)
        #expect(rows.first?.isMutualFavorite == true)
        #expect(service.favorites.filter { $0.noisePublicKey == noiseKey }.count == 1)
    }

    /// Same collapse must hold for a reachable-but-not-connected favorite
    /// (relayed peers linger as "reachable" after their link drops).
    @Test @MainActor
    func updatePeers_reachableMutualFavoriteYieldsSingleRow() async {
        let favoritesService = FavoritesPersistenceService.shared

        let transport = MockTransport()
        let idBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
        let service = UnifiedPeerService(meshService: transport, idBridge: idBridge, identityManager: TestIdentityManager())

        let noiseKey = Data(repeating: 0xCD, count: 32)
        favoritesService.addFavorite(peerNoisePublicKey: noiseKey, peerNickname: "bob")
        favoritesService.updatePeerFavoritedUs(peerNoisePublicKey: noiseKey, favorited: true)
        defer {
            favoritesService.updatePeerFavoritedUs(peerNoisePublicKey: noiseKey, favorited: false)
            favoritesService.removeFavorite(peerNoisePublicKey: noiseKey)
        }

        let otherKey = Data(repeating: 0x11, count: 32)
        let snapshots = [
            // A live link is required for anyone to count as reachable.
            TransportPeerSnapshot(
                peerID: PeerID(publicKey: otherKey),
                nickname: "carol",
                isConnected: true,
                noisePublicKey: otherKey,
                lastSeen: Date()
            ),
            TransportPeerSnapshot(
                peerID: PeerID(publicKey: noiseKey),
                nickname: "bob",
                isConnected: false,
                noisePublicKey: noiseKey,
                lastSeen: Date()
            )
        ]
        transport.updatePeerSnapshots(snapshots)
        service.didUpdatePeerSnapshots(snapshots)

        let bobRows = service.peers.filter { $0.noisePublicKey == noiseKey }
        #expect(bobRows.count == 1)
        #expect(bobRows.first?.peerID == PeerID(publicKey: noiseKey))
        #expect(bobRows.first?.isReachable == true)
    }

    /// A mutual favorite with no mesh presence still gets its offline row,
    /// keyed by the full noise-key PeerID.
    @Test @MainActor
    func updatePeers_offlineMutualFavoriteGetsOfflineRow() async {
        let favoritesService = FavoritesPersistenceService.shared

        let transport = MockTransport()
        let idBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
        let service = UnifiedPeerService(meshService: transport, idBridge: idBridge, identityManager: TestIdentityManager())

        let noiseKey = Data(repeating: 0xEF, count: 32)
        favoritesService.addFavorite(peerNoisePublicKey: noiseKey, peerNickname: "dave")
        favoritesService.updatePeerFavoritedUs(peerNoisePublicKey: noiseKey, favorited: true)
        defer {
            favoritesService.updatePeerFavoritedUs(peerNoisePublicKey: noiseKey, favorited: false)
            favoritesService.removeFavorite(peerNoisePublicKey: noiseKey)
        }

        transport.updatePeerSnapshots([])
        service.didUpdatePeerSnapshots([])

        let rows = service.peers.filter { $0.noisePublicKey == noiseKey }
        #expect(rows.count == 1)
        #expect(rows.first?.peerID == PeerID(hexData: noiseKey))
        #expect(rows.first?.isMutualFavorite == true)
    }

    @Test @MainActor
    func setBlocked_unknownIdentityReturnsNil() async {
        let transport = MockTransport()
        let identity = TestIdentityManager()
        let idBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
        let service = UnifiedPeerService(meshService: transport, idBridge: idBridge, identityManager: identity)

        // No fingerprint resolvable for this peer (offline & unknown).
        let peerID = PeerID(str: "00000000000000FF")

        #expect(service.setBlocked(peerID, blocked: true) == nil)
        #expect(!service.isBlocked(peerID))
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

    // MARK: Vouching (unused by these tests)

    @discardableResult
    func recordVouch(voucheeFingerprint: String, voucherFingerprint: String, timestamp: Date) -> Bool {
        false
    }

    func validVouchers(for fingerprint: String) -> [VouchRecord] {
        []
    }

    func isVouched(fingerprint: String) -> Bool {
        false
    }

    func lastVouchBatchSent(to fingerprint: String) -> Date? {
        nil
    }

    func markVouchBatchSent(to fingerprint: String, at date: Date) {}

    func signingPublicKey(forFingerprint fingerprint: String) -> Data? {
        nil
    }

    func mostRecentlyVerifiedFingerprints(limit: Int, excluding fingerprint: String) -> [String] {
        []
    }
}

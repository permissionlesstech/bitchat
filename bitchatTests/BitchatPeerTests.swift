import Foundation
import Testing
@testable import bitchat

@Suite("BitchatPeer Tests")
struct BitchatPeerTests {
    typealias FavoriteRelationship = FavoritesPersistenceService.FavoriteRelationship

    @Test("Connection state prioritizes bluetooth, mesh, nostr, then offline")
    func connectionStatePriorityIsCorrect() {
        let peerID = PeerID(str: "0123456789abcdef")
        let noiseKey = Data((0..<32).map(UInt8.init))
        let mutual = makeRelationship(isFavorite: true, theyFavoritedUs: true)

        let bluetooth = BitchatPeer(peerID: peerID, noisePublicKey: noiseKey, nickname: "A", isConnected: true, isReachable: true)
        let mesh = BitchatPeer(peerID: peerID, noisePublicKey: noiseKey, nickname: "A", isConnected: false, isReachable: true)
        var nostr = BitchatPeer(peerID: peerID, noisePublicKey: noiseKey, nickname: "A", isConnected: false, isReachable: false)
        nostr.favoriteStatus = mutual
        let offline = BitchatPeer(peerID: peerID, noisePublicKey: noiseKey, nickname: "A", isConnected: false, isReachable: false)

        #expect(bluetooth.connectionState == .bluetoothConnected)
        #expect(mesh.connectionState == .meshReachable)
        #expect(nostr.connectionState == .nostrAvailable)
        #expect(offline.connectionState == .offline)
    }

    @Test("Display name falls back to peer prefix and offline icon reflects inbound favorite")
    func displayNameAndOfflineIconUseDerivedState() {
        let peerID = PeerID(str: "fedcba9876543210")
        let noiseKey = Data((32..<64).map(UInt8.init))
        var peer = BitchatPeer(peerID: peerID, noisePublicKey: noiseKey, nickname: "", isConnected: false, isReachable: false)
        peer.favoriteStatus = makeRelationship(isFavorite: false, theyFavoritedUs: true)

        #expect(peer.displayName == String(peerID.id.prefix(8)))
        #expect(peer.statusIcon == "🌙")
    }

    @Test("Mutual offline peers show Nostr icon")
    func mutualFavoriteOfflinePeerShowsNostrIcon() {
        let peerID = PeerID(str: "0011223344556677")
        let noiseKey = Data((64..<96).map(UInt8.init))
        var peer = BitchatPeer(peerID: peerID, noisePublicKey: noiseKey, nickname: "Peer", isConnected: false, isReachable: false)
        peer.favoriteStatus = makeRelationship(isFavorite: true, theyFavoritedUs: true)

        #expect(peer.statusIcon == "🌐")
        #expect(peer.isFavorite)
        #expect(peer.isMutualFavorite)
        #expect(peer.theyFavoritedUs)
    }

    @Test("Equality is based only on peer ID")
    func equalityUsesPeerIDOnly() {
        let peerID = PeerID(str: "8899aabbccddeeff")
        let first = BitchatPeer(
            peerID: peerID,
            noisePublicKey: Data(repeating: 1, count: 32),
            nickname: "First",
            isConnected: false,
            isReachable: false
        )
        let second = BitchatPeer(
            peerID: peerID,
            noisePublicKey: Data(repeating: 2, count: 32),
            nickname: "Second",
            isConnected: true,
            isReachable: true
        )

        #expect(first == second)
    }

    private func makeRelationship(isFavorite: Bool, theyFavoritedUs: Bool) -> FavoriteRelationship {
        FavoriteRelationship(
            peerNoisePublicKey: Data(repeating: 7, count: 32),
            peerNostrPublicKey: "npub1example",
            peerNickname: "Peer",
            isFavorite: isFavorite,
            theyFavoritedUs: theyFavoritedUs,
            favoritedAt: Date(timeIntervalSince1970: 1),
            lastUpdated: Date(timeIntervalSince1970: 2)
        )
    }
}

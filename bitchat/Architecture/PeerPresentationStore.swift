import BitFoundation
import Combine
import BitLogger
import Foundation
import SwiftUI

@MainActor
final class PeerPresentationStore: ObservableObject, PeerPresentationStoreProtocol {
    @Published private(set) var verifiedFingerprints: Set<String> = []
    @Published var showingFingerprintFor: PeerID? = nil
    @Published private(set) var selectedPeer: PeerID? = nil
    @Published private(set) var peerEncryptionStatus: [PeerID: EncryptionStatus] = [:]

    var myPeerID: PeerID { meshService.myPeerID }

    private let meshService: Transport
    private let peerStore: UnifiedPeerService
    private let privateConversationsStore: PrivateConversationsStore
    private let identityManager: SecureIdentityStateManagerProtocol
    private let keychain: KeychainManagerProtocol
    private let idBridge: NostrIdentityBridge
    private let messageRouter: MessageRouter
    private let favoritesService: FavoritesPersistenceService
    private let meshPalette = MinimalDistancePalette(config: .mesh)

    private var shortIDToNoiseKey: [PeerID: PeerID] = [:]
    private var cancellables = Set<AnyCancellable>()

    init(
        meshService: Transport,
        peerStore: UnifiedPeerService,
        privateConversationsStore: PrivateConversationsStore,
        identityManager: SecureIdentityStateManagerProtocol,
        keychain: KeychainManagerProtocol,
        idBridge: NostrIdentityBridge,
        messageRouter: MessageRouter,
        favoritesService: FavoritesPersistenceService? = nil
    ) {
        self.meshService = meshService
        self.peerStore = peerStore
        self.privateConversationsStore = privateConversationsStore
        self.identityManager = identityManager
        self.keychain = keychain
        self.idBridge = idBridge
        self.messageRouter = messageRouter
        self.favoritesService = favoritesService ?? FavoritesPersistenceService.shared
        
        loadVerifiedFingerprints()
        selectedPeer = privateConversationsStore.selectedPeer
        refreshShortIDMappings(from: peerStore.peers)

        privateConversationsStore.$selectedPeer
            .sink { [weak self] in self?.selectedPeer = $0 }
            .store(in: &cancellables)

        peerStore.$peers
            .sink { [weak self] peers in
                self?.refreshShortIDMappings(from: peers)
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func shortID(for fullNoiseKeyHex: PeerID) -> PeerID {
        guard fullNoiseKeyHex.isNoiseKeyHex else { return fullNoiseKeyHex }
        if let match = peerStore.peers.first(where: { PeerID(hexData: $0.noisePublicKey) == fullNoiseKeyHex }) {
            return match.peerID
        }
        if let pair = shortIDToNoiseKey.first(where: { $0.value == fullNoiseKeyHex }) {
            return pair.key
        }
        return fullNoiseKeyHex
    }

    func fingerprint(for peerID: PeerID) -> String? {
        peerStore.getFingerprint(for: peerID)
    }

    func isVerified(peerID: PeerID) -> Bool {
        guard let fingerprint = fingerprint(for: shortID(for: peerID)) else { return false }
        return verifiedFingerprints.contains(fingerprint)
    }

    func encryptionStatus(for peerID: PeerID) -> EncryptionStatus {
        let statusPeerID = shortID(for: peerID)
        let hasEverEstablishedSession = fingerprint(for: statusPeerID) != nil

        switch meshService.getNoiseSessionState(for: statusPeerID) {
        case .established:
            return trustedEncryptionStatus(for: statusPeerID)
        case .handshaking, .handshakeQueued:
            return hasEverEstablishedSession ? trustedEncryptionStatus(for: statusPeerID) : .noiseHandshaking
        case .none:
            return hasEverEstablishedSession ? trustedEncryptionStatus(for: statusPeerID) : .noHandshake
        case .failed:
            return hasEverEstablishedSession ? trustedEncryptionStatus(for: statusPeerID) : .none
        }
    }

    func color(forMeshPeer peerID: PeerID, isDark: Bool) -> Color {
        guard peerID != myPeerID else { return .orange }

        meshPalette.ensurePalette(for: currentMeshPaletteSeeds())
        if let color = meshPalette.color(for: peerID.id, isDark: isDark) {
            return color
        }
        return Color(peerSeed: meshSeed(for: peerID), isDark: isDark)
    }

    func displayName(for peerID: PeerID) -> String {
        let statusPeerID = shortID(for: peerID)

        if let peer = peerStore.getPeer(by: statusPeerID) {
            return peer.displayName
        }
        if let name = meshService.peerNickname(peerID: statusPeerID), !name.isEmpty {
            return name
        }
        if let noisePublicKey = resolvedNoisePublicKey(for: statusPeerID),
           let favorite = favoritesService.getFavoriteStatus(for: noisePublicKey),
           !favorite.peerNickname.isEmpty {
            return favorite.peerNickname
        }
        if statusPeerID.isShort {
            for candidate in identityManager.getCryptoIdentitiesByPeerIDPrefix(statusPeerID) {
                if let name = socialDisplayName(for: candidate.fingerprint) {
                    return name
                }
            }
        }
        if let fingerprint = fingerprint(for: statusPeerID),
           let name = socialDisplayName(for: fingerprint) {
            return name
        }

        return String(localized: "common.unknown", comment: "Fallback label for unknown peer")
    }

    func headerContext(for privatePeerID: PeerID, selectedChannel: ChannelID) -> PeerHeaderContext {
        let headerPeerID = shortID(for: privatePeerID)
        let peer = peerStore.getPeer(by: headerPeerID)
        let resolvedDisplayName: String

        if privatePeerID.isGeoDM, case .location(let channel) = selectedChannel {
            resolvedDisplayName = "#\(channel.geohash)/@\(privatePeerID.id)"
        } else {
            resolvedDisplayName = displayName(for: headerPeerID)
        }

        let isNostrAvailable: Bool = {
            guard let connectionState = peer?.connectionState else {
                guard let noiseKey = resolvedNoisePublicKey(for: headerPeerID),
                      let favoriteStatus = favoritesService.getFavoriteStatus(for: noiseKey) else {
                    return false
                }
                return favoriteStatus.isMutual
            }
            return connectionState == .nostrAvailable
        }()

        return PeerHeaderContext(
            headerPeerID: headerPeerID,
            peer: peer,
            displayName: resolvedDisplayName,
            isNostrAvailable: isNostrAvailable
        )
    }

    func fingerprintDetails(for peerID: PeerID) -> FingerprintDetails {
        let statusPeerID = shortID(for: peerID)
        return FingerprintDetails(
            statusPeerID: statusPeerID,
            displayName: displayName(for: statusPeerID),
            encryptionStatus: encryptionStatus(for: statusPeerID),
            theirFingerprint: fingerprint(for: statusPeerID),
            myFingerprint: myFingerprint()
        )
    }

    func isBlocked(_ peerID: PeerID) -> Bool {
        peerStore.isBlocked(shortID(for: peerID))
    }

    func isFavorite(peerID: PeerID) -> Bool {
        if let noisePublicKey = peerID.noiseKey,
           let status = favoritesService.getFavoriteStatus(for: noisePublicKey) {
            return status.isFavorite
        }
        return peerStore.getPeer(by: peerID)?.isFavorite ?? false
    }

    func isPeerConnected(_ peerID: PeerID) -> Bool {
        meshService.isPeerConnected(shortID(for: peerID))
    }

    func isPeerReachable(_ peerID: PeerID) -> Bool {
        meshService.isPeerReachable(shortID(for: peerID))
    }

    func toggleFavorite(peerID: PeerID) {
        if let noisePublicKey = peerID.noiseKey {
            let ephemeralPeerID = peerStore.peers.first(where: { $0.noisePublicKey == noisePublicKey })?.peerID

            if let ephemeralPeerID {
                peerStore.toggleFavorite(ephemeralPeerID)
                return
            }

            let currentStatus = favoritesService.getFavoriteStatus(for: noisePublicKey)
            let wasFavorite = currentStatus?.isFavorite ?? false

            if wasFavorite {
                favoritesService.removeFavorite(peerNoisePublicKey: noisePublicKey)
            } else {
                var resolvedNickname = currentStatus?.peerNickname
                if resolvedNickname == nil,
                   let messages = privateConversationsStore.privateChats[peerID], !messages.isEmpty {
                    resolvedNickname = messages.first(where: { $0.senderPeerID == peerID })?.sender
                }
                let finalNickname = resolvedNickname ?? "Unknown"
                let nostrKey = currentStatus?.peerNostrPublicKey ?? idBridge.getNostrPublicKey(for: noisePublicKey)

                favoritesService.addFavorite(
                    peerNoisePublicKey: noisePublicKey,
                    peerNostrPublicKey: nostrKey,
                    peerNickname: finalNickname
                )
            }

            if !wasFavorite && currentStatus?.theyFavoritedUs == true {
                sendFavoriteNotificationViaNostr(noisePublicKey: noisePublicKey, isFavorite: true)
            } else if wasFavorite {
                sendFavoriteNotificationViaNostr(noisePublicKey: noisePublicKey, isFavorite: false)
            }
            return
        }

        peerStore.toggleFavorite(peerID)
    }

    func showFingerprint(for peerID: PeerID) {
        showingFingerprintFor = shortID(for: peerID)
    }

    func replaceVerifiedFingerprints(_ fingerprints: Set<String>) {
        guard verifiedFingerprints != fingerprints else { return }
        verifiedFingerprints = fingerprints
    }

    func replacePeerEncryptionStatuses(_ statuses: [PeerID: EncryptionStatus]) {
        guard peerEncryptionStatus != statuses else { return }
        peerEncryptionStatus = statuses
    }

    func loadVerifiedFingerprints() {
        verifiedFingerprints = identityManager.getVerifiedFingerprints()

        let sample = Array(verifiedFingerprints.prefix(TransportConfig.uiFingerprintSampleCount))
            .map { $0.prefix(8) }
            .joined(separator: ", ")
        SecureLogger.info("🔐 Verified loaded: \(verifiedFingerprints.count) [\(sample)]", category: .security)

        let offlineFavorites = peerStore.favorites.filter { !$0.isConnected }
        for favorite in offlineFavorites {
            let fingerprint = peerStore.getFingerprint(for: favorite.peerID)
            let isVerified = fingerprint.flatMap { verifiedFingerprints.contains($0) } ?? false
            let fingerprintPrefix = fingerprint?.prefix(8) ?? "nil"
            SecureLogger.info(
                "⭐️ Favorite offline: \(favorite.nickname) fp=\(fingerprintPrefix) verified=\(isVerified)",
                category: .security
            )
        }
    }

    func myFingerprint() -> String {
        meshService.getNoiseService().getIdentityFingerprint()
    }

    func verifyFingerprint(for peerID: PeerID) {
        let statusPeerID = shortID(for: peerID)
        guard let fingerprint = fingerprint(for: statusPeerID) else { return }

        identityManager.setVerified(fingerprint: fingerprint, verified: true)
        saveIdentityState()

        var updatedVerified = verifiedFingerprints
        updatedVerified.insert(fingerprint)
        verifiedFingerprints = updatedVerified

        var updatedStatuses = peerEncryptionStatus
        updatedStatuses[statusPeerID] = trustedEncryptionStatus(for: statusPeerID)
        peerEncryptionStatus = updatedStatuses
    }

    func unverifyFingerprint(for peerID: PeerID) {
        let statusPeerID = shortID(for: peerID)
        guard let fingerprint = fingerprint(for: statusPeerID) else { return }

        identityManager.setVerified(fingerprint: fingerprint, verified: false)
        saveIdentityState()

        var updatedVerified = verifiedFingerprints
        updatedVerified.remove(fingerprint)
        verifiedFingerprints = updatedVerified

        var updatedStatuses = peerEncryptionStatus
        updatedStatuses[statusPeerID] = trustedEncryptionStatus(for: statusPeerID)
        peerEncryptionStatus = updatedStatuses
    }

    func cacheNoiseKeyMapping(for peerID: PeerID) {
        guard shortIDToNoiseKey[peerID] == nil else { return }

        if let peer = peerStore.getPeer(by: peerID), !peer.noisePublicKey.isEmpty {
            shortIDToNoiseKey[peerID] = PeerID(hexData: peer.noisePublicKey)
            return
        }

        if let keyData = meshService.getNoiseService().getPeerPublicKeyData(peerID) {
            shortIDToNoiseKey[peerID] = PeerID(hexData: keyData)
        }
    }

    func stableNoiseKey(for peerID: PeerID) -> PeerID? {
        if peerID.isNoiseKeyHex {
            return peerID
        }
        if let mapped = shortIDToNoiseKey[peerID] {
            return mapped
        }
        if let keyData = meshService.getNoiseService().getPeerPublicKeyData(peerID) {
            let stablePeerID = PeerID(hexData: keyData)
            shortIDToNoiseKey[peerID] = stablePeerID
            return stablePeerID
        }
        return nil
    }

    func applyPeerAuthenticated(_ peerID: PeerID, fingerprint: String) {
        var updatedStatuses = peerEncryptionStatus
        updatedStatuses[peerID] = verifiedFingerprints.contains(fingerprint) ? .noiseVerified : .noiseSecured
        peerEncryptionStatus = updatedStatuses
        cacheNoiseKeyMapping(for: peerID)
    }

    func markHandshakeRequired(for peerID: PeerID) {
        var updatedStatuses = peerEncryptionStatus
        updatedStatuses[peerID] = .noiseHandshaking
        peerEncryptionStatus = updatedStatuses
    }

    func refreshEncryptionStatuses(for peerIDs: Set<PeerID>) {
        var updatedStatuses = peerEncryptionStatus
        for peerID in peerIDs {
            updatedStatuses[peerID] = encryptionStatus(for: peerID)
            cacheNoiseKeyMapping(for: peerID)
        }
        peerEncryptionStatus = updatedStatuses
    }

    func clearEncryptionStatus(for peerID: PeerID) {
        guard peerEncryptionStatus[peerID] != nil else { return }
        var updatedStatuses = peerEncryptionStatus
        updatedStatuses.removeValue(forKey: peerID)
        peerEncryptionStatus = updatedStatuses
    }
}

private extension PeerPresentationStore {

    func refreshShortIDMappings(from peers: [BitchatPeer]) {
        shortIDToNoiseKey = peers.reduce(into: [:]) { mapping, peer in
            guard !peer.noisePublicKey.isEmpty else { return }
            mapping[peer.peerID] = PeerID(hexData: peer.noisePublicKey)
        }
    }

    func trustedEncryptionStatus(for peerID: PeerID) -> EncryptionStatus {
        guard let fingerprint = fingerprint(for: peerID) else { return .noiseSecured }
        return verifiedFingerprints.contains(fingerprint) ? .noiseVerified : .noiseSecured
    }

    func meshSeed(for peerID: PeerID) -> String {
        if let fullNoiseKey = shortIDToNoiseKey[peerID]?.id.lowercased() {
            return "noise:" + fullNoiseKey
        }
        return peerID.id.lowercased()
    }

    func currentMeshPaletteSeeds() -> [String: String] {
        peerStore.peers.reduce(into: [:]) { seeds, peer in
            guard peer.peerID != myPeerID else { return }
            seeds[peer.peerID.id] = meshSeed(for: peer.peerID)
        }
    }

    func resolvedNoisePublicKey(for peerID: PeerID) -> Data? {
        if let noiseKey = peerID.noiseKey {
            return noiseKey
        }
        if let peer = peerStore.getPeer(by: peerID), !peer.noisePublicKey.isEmpty {
            return peer.noisePublicKey
        }
        return shortIDToNoiseKey[peerID]?.noiseKey
    }

    func socialDisplayName(for fingerprint: String) -> String? {
        guard let social = identityManager.getSocialIdentity(for: fingerprint) else {
            return nil
        }
        if let petname = social.localPetname, !petname.isEmpty {
            return petname
        }
        if !social.claimedNickname.isEmpty {
            return social.claimedNickname
        }
        return nil
    }

    func sendFavoriteNotificationViaNostr(noisePublicKey: Data, isFavorite: Bool) {
        guard let relationship = favoritesService.getFavoriteStatus(for: noisePublicKey),
              relationship.peerNostrPublicKey != nil else {
            return
        }

        messageRouter.sendFavoriteNotification(to: PeerID(hexData: noisePublicKey), isFavorite: isFavorite)
    }

    func saveIdentityState() {
        identityManager.forceSave()
        _ = keychain.verifyIdentityKeyExists()
    }
}

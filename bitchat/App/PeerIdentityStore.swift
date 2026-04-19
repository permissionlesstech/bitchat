import BitFoundation
import Combine
import Foundation

@MainActor
final class PeerIdentityStore: ObservableObject {
    @Published private(set) var encryptionStatuses: [PeerID: EncryptionStatus] = [:]
    @Published private(set) var verifiedFingerprints: Set<String> = []

    private(set) var peerFingerprintsByPeerID: [PeerID: String] = [:]
    private(set) var selectedPrivateChatFingerprint: String?

    private var stablePeerIDsByShortID: [PeerID: PeerID] = [:]
    private var encryptionStatusCache: [PeerID: EncryptionStatus] = [:]

    func stablePeerID(forShortID peerID: PeerID) -> PeerID? {
        stablePeerIDsByShortID[peerID]
    }

    func shortPeerID(forStablePeerID stablePeerID: PeerID) -> PeerID? {
        stablePeerIDsByShortID.first(where: { $0.value == stablePeerID })?.key
    }

    func setStablePeerID(_ stablePeerID: PeerID, forShortID peerID: PeerID) {
        stablePeerIDsByShortID[peerID] = stablePeerID
    }

    func replaceStablePeerIDs(_ mappings: [PeerID: PeerID]) {
        stablePeerIDsByShortID = mappings
    }

    func fingerprint(for peerID: PeerID) -> String? {
        peerFingerprintsByPeerID[peerID]
    }

    func setFingerprint(_ fingerprint: String?, for peerID: PeerID) {
        if let fingerprint {
            peerFingerprintsByPeerID[peerID] = fingerprint
        } else {
            peerFingerprintsByPeerID.removeValue(forKey: peerID)
        }
    }

    func replaceFingerprintMappings(_ mappings: [PeerID: String]) {
        peerFingerprintsByPeerID = mappings
    }

    @discardableResult
    func migrateFingerprintMapping(
        from oldPeerID: PeerID,
        to newPeerID: PeerID,
        fallback: String? = nil
    ) -> String? {
        let fingerprint = peerFingerprintsByPeerID.removeValue(forKey: oldPeerID) ?? fallback
        if let fingerprint {
            peerFingerprintsByPeerID[newPeerID] = fingerprint
            if selectedPrivateChatFingerprint == nil {
                selectedPrivateChatFingerprint = fingerprint
            }
        }
        return fingerprint
    }

    func setSelectedPrivateChatFingerprint(_ fingerprint: String?) {
        selectedPrivateChatFingerprint = fingerprint
    }

    func cachedEncryptionStatus(for peerID: PeerID) -> EncryptionStatus? {
        encryptionStatusCache[peerID]
    }

    func setCachedEncryptionStatus(_ status: EncryptionStatus, for peerID: PeerID) {
        encryptionStatusCache[peerID] = status
    }

    func invalidateEncryptionCache(for peerID: PeerID? = nil) {
        if let peerID {
            encryptionStatusCache.removeValue(forKey: peerID)
        } else {
            encryptionStatusCache.removeAll()
        }
    }

    func encryptionStatus(for peerID: PeerID) -> EncryptionStatus? {
        encryptionStatuses[peerID]
    }

    func setEncryptionStatus(_ status: EncryptionStatus?, for peerID: PeerID) {
        if let status {
            encryptionStatuses[peerID] = status
        } else {
            encryptionStatuses.removeValue(forKey: peerID)
        }
        invalidateEncryptionCache(for: peerID)
    }

    func replaceEncryptionStatuses(_ statuses: [PeerID: EncryptionStatus]) {
        encryptionStatuses = statuses
    }

    func setVerifiedFingerprints(_ fingerprints: Set<String>) {
        verifiedFingerprints = fingerprints
    }

    func setVerified(_ fingerprint: String, verified: Bool) {
        if verified {
            verifiedFingerprints.insert(fingerprint)
        } else {
            verifiedFingerprints.remove(fingerprint)
        }
    }

    func isVerified(_ fingerprint: String) -> Bool {
        verifiedFingerprints.contains(fingerprint)
    }

    func clearAll() {
        encryptionStatuses.removeAll()
        verifiedFingerprints.removeAll()
        peerFingerprintsByPeerID.removeAll()
        selectedPrivateChatFingerprint = nil
        stablePeerIDsByShortID.removeAll()
        encryptionStatusCache.removeAll()
    }
}

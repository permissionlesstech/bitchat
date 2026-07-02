import BitFoundation
import Foundation

struct BLEAnnouncePreflightAcceptance {
    let announcement: AnnouncementPacket
    let derivedPeerID: PeerID
}

enum BLEAnnouncePreflightRejection: Equatable {
    case malformed
    case senderMismatch(derivedPeerID: PeerID)
    case selfAnnounce
    case stale(ageSeconds: Double)
}

enum BLEAnnouncePreflightDecision {
    case accept(BLEAnnouncePreflightAcceptance)
    case reject(BLEAnnouncePreflightRejection)
}

enum BLEAnnouncePreflightPolicy {
    static func evaluate(
        packet: BitchatPacket,
        from peerID: PeerID,
        localPeerID: PeerID,
        now: Date
    ) -> BLEAnnouncePreflightDecision {
        guard let announcement = AnnouncementPacket.decode(from: packet.payload) else {
            return .reject(.malformed)
        }

        let derivedPeerID = PeerID(publicKey: announcement.noisePublicKey)
        guard derivedPeerID == peerID else {
            return .reject(.senderMismatch(derivedPeerID: derivedPeerID))
        }

        guard peerID != localPeerID else {
            return .reject(.selfAnnounce)
        }

        guard !BLEPacketFreshnessPolicy.isStale(timestampMilliseconds: packet.timestamp, now: now) else {
            return .reject(.stale(ageSeconds: BLEPacketFreshnessPolicy.ageSeconds(
                timestampMilliseconds: packet.timestamp,
                now: now
            )))
        }

        return .accept(BLEAnnouncePreflightAcceptance(
            announcement: announcement,
            derivedPeerID: derivedPeerID
        ))
    }
}

enum BLEAnnounceTrustRejection: Equatable {
    case missingSignature
    case invalidSignature
    case keyMismatch
    case signingKeyMismatch
}

enum BLEAnnounceTrustDecision: Equatable {
    case verified
    case reject(BLEAnnounceTrustRejection)

    var isVerified: Bool {
        self == .verified
    }
}

enum BLEAnnounceTrustPolicy {
    static func evaluate(
        hasSignature: Bool,
        signatureValid: Bool,
        existingNoisePublicKey: Data?,
        announcedNoisePublicKey: Data,
        existingSigningPublicKey: Data?,
        announcedSigningPublicKey: Data
    ) -> BLEAnnounceTrustDecision {
        if let existingNoisePublicKey, existingNoisePublicKey != announcedNoisePublicKey {
            return .reject(.keyMismatch)
        }

        // TOFU signing-key pinning. The packet signature only proves the
        // announce is self-consistent — it is verified against the Ed25519 key
        // carried *inside the same announce*. Since peerIDs derive from the
        // broadcast (public) noise key, an attacker can replay a victim's
        // peerID+noiseKey with their own signing key and a valid
        // self-signature. Once we have bound a signing key to this peer,
        // refuse to silently replace it.
        if let existingSigningPublicKey, existingSigningPublicKey != announcedSigningPublicKey {
            return .reject(.signingKeyMismatch)
        }

        guard hasSignature else {
            return .reject(.missingSignature)
        }

        guard signatureValid else {
            return .reject(.invalidSignature)
        }

        return .verified
    }
}

struct BLEAnnounceResponsePlan: Equatable {
    let shouldNotifyPeerConnected: Bool
    let shouldScheduleInitialSync: Bool
    let shouldSendAnnounceBack: Bool
    let shouldScheduleAfterglow: Bool
}

enum BLEAnnounceResponsePolicy {
    static func plan(
        isDirectAnnounce: Bool,
        isNewPeer: Bool,
        isReconnectedPeer: Bool,
        shouldSendAnnounceBack: Bool
    ) -> BLEAnnounceResponsePlan {
        let shouldNotifyPeerConnected = isDirectAnnounce && (isNewPeer || isReconnectedPeer)

        return BLEAnnounceResponsePlan(
            shouldNotifyPeerConnected: shouldNotifyPeerConnected,
            shouldScheduleInitialSync: shouldNotifyPeerConnected,
            shouldSendAnnounceBack: shouldSendAnnounceBack,
            shouldScheduleAfterglow: isNewPeer
        )
    }
}

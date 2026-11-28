//
// LocalWebOfTrustService.swift
// bitchat
//
// Bridges bitchat's physical in-person verification & transitive VouchAttestation
// graph (SecureIdentityStateManager + FavoritesPersistenceService) onto Nostr
// feed authors so users can filter feeds by real-world physical trust.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation

/// Physical Web-of-Trust status for a Nostr feed author, derived strictly from
/// local in-person QR/Noise verification and signed VouchAttestations.
enum FeedAuthorTrust: Equatable, Sendable {
    /// Directly verified in person via Noise/QR fingerprint.
    case verified
    /// Transitively vouched for via signed VouchAttestation by ≥1 peer we verified.
    case vouched(voucherCount: Int)
    /// Not linked to a locally verified or vouched mesh identity.
    case none

    var isTrusted: Bool {
        switch self {
        case .verified, .vouched:
            return true
        case .none:
            return false
        }
    }
}

@MainActor
final class LocalWebOfTrustService {
    static let shared = LocalWebOfTrustService()

    private var identityManager: SecureIdentityStateManagerProtocol?
    private let noiseKeyLookup: @MainActor (_ nostrPubkeyHex: String) -> Data?
    private let isVerifiedFingerprintOverride: ((_ fingerprint: String) -> Bool)?
    private let validVoucherCountOverride: ((_ fingerprint: String) -> Int)?

    init(
        identityManager: SecureIdentityStateManagerProtocol? = nil,
        noiseKeyLookup: (@MainActor (_ nostrPubkeyHex: String) -> Data?)? = nil,
        isVerifiedFingerprint: ((_ fingerprint: String) -> Bool)? = nil,
        validVoucherCount: ((_ fingerprint: String) -> Int)? = nil
    ) {
        self.identityManager = identityManager
        self.noiseKeyLookup = noiseKeyLookup ?? { pubkey in
            FavoritesPersistenceService.shared.noisePublicKey(forNostrPubkey: pubkey)
        }
        self.isVerifiedFingerprintOverride = isVerifiedFingerprint
        self.validVoucherCountOverride = validVoucherCount
    }

    func configure(identityManager: SecureIdentityStateManagerProtocol) {
        self.identityManager = identityManager
    }

    func trust(forNostrPubkey nostrPubkeyHex: String) -> FeedAuthorTrust {
        guard let noiseKey = noiseKeyLookup(nostrPubkeyHex.lowercased()) else {
            return .none
        }
        let fingerprint = noiseKey.sha256Fingerprint()
        let verified = isVerifiedFingerprintOverride?(fingerprint)
            ?? identityManager?.isVerified(fingerprint: fingerprint)
            ?? false
        if verified {
            return .verified
        }
        let vouchers = validVoucherCountOverride?(fingerprint)
            ?? identityManager?.validVouchers(for: fingerprint).count
            ?? 0
        if vouchers > 0 {
            return .vouched(voucherCount: vouchers)
        }
        return .none
    }

    func isTrustedAuthor(_ nostrPubkeyHex: String) -> Bool {
        trust(forNostrPubkey: nostrPubkeyHex).isTrusted
    }
}

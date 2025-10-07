//
// FingerprintVerificationService.swift
// bitchat
//
// Service for managing peer fingerprint verification
// This is free and unencumbered software released into the public domain.
//

import BitLogger
import Foundation

/// Service that manages fingerprint verification for peers
/// Handles verification status, loading verified fingerprints, and UI state
@MainActor
final class FingerprintVerificationService: ObservableObject {

    // MARK: - Published Properties

    @Published var verifiedFingerprints: Set<String> = []
    @Published var showingFingerprintFor: String? = nil

    // MARK: - Dependencies

    private let identityManager: SecureIdentityStateManagerProtocol
    private let getFingerprint: (String) -> String?
    private let updateEncryptionStatus: (String) -> Void
    private let getFavorites: () -> [BitchatPeer]

    // MARK: - Initialization

    init(
        identityManager: SecureIdentityStateManagerProtocol,
        getFingerprint: @escaping (String) -> String?,
        updateEncryptionStatus: @escaping (String) -> Void,
        getFavorites: @escaping () -> [BitchatPeer]
    ) {
        self.identityManager = identityManager
        self.getFingerprint = getFingerprint
        self.updateEncryptionStatus = updateEncryptionStatus
        self.getFavorites = getFavorites
    }

    // MARK: - Public API

    /// Show fingerprint sheet for a peer
    func showFingerprint(for peerID: String) {
        showingFingerprintFor = peerID
    }

    /// Verify a peer's fingerprint
    func verify(peerID: String) {
        guard let fingerprint = getFingerprint(peerID) else { return }

        // Update secure storage with verified status
        identityManager.setVerified(fingerprint: fingerprint, verified: true)

        // Update local set for UI
        verifiedFingerprints.insert(fingerprint)

        // Update encryption status after verification
        updateEncryptionStatus(peerID)
    }

    /// Unverify a peer's fingerprint
    func unverify(peerID: String) {
        guard let fingerprint = getFingerprint(peerID) else { return }

        identityManager.setVerified(fingerprint: fingerprint, verified: false)
        identityManager.forceSave()
        verifiedFingerprints.remove(fingerprint)

        updateEncryptionStatus(peerID)
    }

    /// Load verified fingerprints from secure storage
    func loadVerified() {
        // Load verified fingerprints directly from secure storage
        verifiedFingerprints = identityManager.getVerifiedFingerprints()

        // Log snapshot for debugging persistence
        let sample = Array(verifiedFingerprints.prefix(TransportConfig.uiFingerprintSampleCount))
            .map { $0.prefix(8) }
            .joined(separator: ", ")
        SecureLogger.info("🔐 Verified loaded: \(verifiedFingerprints.count) [\(sample)]", category: .security)

        // Also log any offline favorites and whether we consider them verified
        let offlineFavorites = getFavorites().filter { !$0.isConnected }
        for fav in offlineFavorites {
            let fp = getFingerprint(fav.peerID.id)
            let isVer = fp.flatMap { verifiedFingerprints.contains($0) } ?? false
            let fpShort = fp?.prefix(8) ?? "nil"
            SecureLogger.info("⭐️ Favorite offline: \(fav.nickname) fp=\(fpShort) verified=\(isVer)", category: .security)
        }
    }

    /// Check if a fingerprint is verified
    func isVerified(fingerprint: String) -> Bool {
        return verifiedFingerprints.contains(fingerprint)
    }

    /// Invalidate all verification state (for reset)
    func reset() {
        verifiedFingerprints.removeAll()
        showingFingerprintFor = nil
    }
}

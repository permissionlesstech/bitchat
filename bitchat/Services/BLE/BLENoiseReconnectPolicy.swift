import Foundation

/// Bounds ordinary Noise revalidation to one attempt per physical-link epoch.
/// A live epoch may retry after the cooldown so a lost handshake cannot leave
/// the link permanently unauthenticated.
struct BLENoiseReconnectPolicy {
    static let minimumRetryInterval: TimeInterval = 60

    private var lastAttemptAt: [BLEIngressLinkID: Date] = [:]

    mutating func shouldRevalidate(
        on link: BLEIngressLinkID,
        hasEstablishedSession: Bool,
        isNoiseAuthenticatedLink: Bool,
        hasAuthenticatedPeerLink: Bool,
        now: Date
    ) -> Bool {
        guard hasEstablishedSession,
              !isNoiseAuthenticatedLink,
              !hasAuthenticatedPeerLink else {
            return false
        }
        if let previous = lastAttemptAt[link],
           now.timeIntervalSince(previous) < Self.minimumRetryInterval {
            return false
        }
        lastAttemptAt[link] = now
        return true
    }

    /// Link identifiers can be stable across CoreBluetooth reconnects, so a
    /// disconnect explicitly starts a new epoch and permits one fresh attempt.
    mutating func endLinkEpoch(_ link: BLEIngressLinkID) {
        lastAttemptAt.removeValue(forKey: link)
    }

    mutating func removeAll() {
        lastAttemptAt.removeAll()
    }
}

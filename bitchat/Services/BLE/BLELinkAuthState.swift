import BitFoundation
import Foundation

/// Per-link Noise authentication and rebind-containment state.
///
/// A peer ID can retain an established Noise session after its physical
/// link disappears, and link bindings heal on announces whose directness
/// is forgeable (TTL is unsigned). This state pins the stronger facts the
/// containment rules need: which exact ingress link a Noise handshake
/// completed on, each link's revalidation epoch, and the cooldowns that
/// stop a replayed announce from flip-flopping bindings or survivor
/// selection.
///
/// Engine-owned (option-B boundary, docs/BLE-ARCHITECTURE-V3.md),
/// alongside the link bindings it qualifies: BLEService debug-traps any
/// access off the engine queue.
struct BLELinkAuthState {
    private var authenticatedOwners: [BLEIngressLinkID: PeerID] = [:]
    private var reconnectPolicy = BLENoiseReconnectPolicy()
    // Entries older than the cooldown are pruned on each check.
    private var lastRebindAt: [String: Date] = [:]
    private var lastRedundantRetirementAt: [PeerID: Date] = [:]

    // MARK: - Authentication ownership

    /// Whether `peerID`'s Noise session was established on this exact link.
    func isAuthenticated(_ link: BLEIngressLinkID, for peerID: PeerID) -> Bool {
        authenticatedOwners[link] == peerID
    }

    func links(ownedBy peerID: PeerID) -> [BLEIngressLinkID] {
        authenticatedOwners.compactMap { link, owner in
            owner == peerID ? link : nil
        }
    }

    mutating func markAuthenticated(_ link: BLEIngressLinkID, owner peerID: PeerID) {
        authenticatedOwners[link] = peerID
    }

    /// Retires a link's proof and closes its revalidation epoch — the pair
    /// every teardown path (disconnect, unsubscribe, timeout, rebind,
    /// redundant retirement) must apply together.
    mutating func retireLink(_ link: BLEIngressLinkID) {
        authenticatedOwners.removeValue(forKey: link)
        reconnectPolicy.endLinkEpoch(link)
    }

    /// Retires every link the departing peer's proofs still own; returns
    /// the retired links.
    mutating func retireLinks(ownedBy peerID: PeerID) -> [BLEIngressLinkID] {
        let departed = links(ownedBy: peerID)
        for link in departed {
            retireLink(link)
        }
        return departed
    }

    /// Drops every link proof and revalidation epoch. The containment
    /// cooldowns deliberately SURVIVE this: panic and emergency resets can
    /// restart services well inside `bleLinkRebindCooldownSeconds`, and a
    /// stable CoreBluetooth UUID must not get a fresh rebind/retirement
    /// allowance just because the session state around it was wiped. The
    /// maps stay time-pruned on each permit check.
    mutating func removeAll() {
        authenticatedOwners.removeAll()
        reconnectPolicy.removeAll()
    }

    // MARK: - Session revalidation

    /// Whether a fresh direct link warrants revalidating a cached
    /// peer-level session with a new XX exchange.
    mutating func shouldRevalidate(
        on link: BLEIngressLinkID,
        for peerID: PeerID,
        hasEstablishedSession: Bool,
        hasAuthenticatedPeerLink: Bool,
        now: Date
    ) -> Bool {
        reconnectPolicy.shouldRevalidate(
            on: link,
            hasEstablishedSession: hasEstablishedSession,
            isNoiseAuthenticatedLink: isAuthenticated(link, for: peerID),
            hasAuthenticatedPeerLink: hasAuthenticatedPeerLink,
            now: now
        )
    }

    // MARK: - Rebind containment cooldowns

    /// At most one rotation rebind per link per cooldown window, so two
    /// identities can't fight over a link in a replay flip-flop. Prunes,
    /// checks, and records in one transition; true = permitted (recorded).
    mutating func permitRebind(linkUUID: String, now: Date, cooldown: TimeInterval) -> Bool {
        lastRebindAt = lastRebindAt.filter {
            now.timeIntervalSince($0.value) < cooldown
        }
        guard lastRebindAt[linkUUID] == nil else { return false }
        lastRebindAt[linkUUID] = now
        return true
    }

    /// At most one redundant-link retirement per peer per cooldown window,
    /// bounding how often a replayed announce could flip which duplicate
    /// link survives. True = permitted (recorded).
    mutating func permitRedundantRetirement(peerID: PeerID, now: Date, cooldown: TimeInterval) -> Bool {
        lastRedundantRetirementAt = lastRedundantRetirementAt.filter {
            now.timeIntervalSince($0.value) < cooldown
        }
        guard lastRedundantRetirementAt[peerID] == nil else { return false }
        lastRedundantRetirementAt[peerID] = now
        return true
    }
}

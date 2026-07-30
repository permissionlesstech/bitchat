import BitFoundation
import Foundation

/// The upward half of the link-layer port: everything the bleQueue link
/// layer tells the engine, as one enumerable surface with one engine
/// entry point (`BLEService.handleLinkEvent`). CoreBluetooth delegates
/// shrink to physical bookkeeping plus event emission, and the simulated
/// mesh drives the engine through exactly the same seam.
///
/// Naming follows the physical stores: a *peripheral link* is a
/// connection we own as central (keyed by the remote peripheral's UUID);
/// a *central link* is a remote central subscribed to our peripheral role
/// (keyed by its UUID).
enum BLELinkEvent {
    /// A decoded frame arrived on a link. Attribution — binding lookup,
    /// spoof rejection, raw-announce binding, ingress recording — is
    /// engine work. Emission captures the panic lifecycle at the handoff.
    case frameDecoded(BitchatPacket, link: BLEIngressLinkID, linkDescription: String)

    /// One peripheral link ended (disconnect, connect failure, or radio
    /// policy teardown). The engine retires the link's identity half —
    /// proof, epoch, binding with survivor repair — and, when
    /// `runPeerBookkeeping` is set (real disconnects), marks the peer
    /// disconnected once its last live link is gone and republishes the
    /// peer list.
    case peripheralLinkEnded(peripheralID: String, runPeerBookkeeping: Bool)

    /// A remote central unsubscribed. The engine retires the central
    /// link's identity half and runs last-link peer bookkeeping.
    case centralLinkEnded(centralUUID: String)

    /// The central role reset and every peripheral link is gone
    /// (power-off retires proofs and notifies peers; an authorization
    /// loss only drops the bindings).
    case allPeripheralLinksEnded(peripheralIDs: [String], retireProofsAndNotify: Bool)

    /// The peripheral role reset and every central link is gone (same
    /// power-off / authorization-loss split).
    case allCentralLinksEnded(centralUUIDs: [String], retireProofsAndNotify: Bool)
}

import Foundation

/// Rollout gate for the cross-platform double-ratchet transport.
///
/// Compatible mutual favorites negotiate this transport over authenticated Noise.
/// Peers without the capability retain the existing relay envelope.
enum DoubleRatchetFeature {
    #if BITCHAT_DISABLE_NDR
    static let isEnabled = false
    #else
    static let isEnabled = true
    #endif

    /// Both clients elect the lower authenticated Nostr key as the initiator.
    @MainActor
    static func shouldInitiate(localPubkeyHex: String, peerPubkeyHex: String) -> Bool {
        guard let local = ChatViewModel.ndrNostrPubkeyHex(from: localPubkeyHex),
              let peer = ChatViewModel.ndrNostrPubkeyHex(from: peerPubkeyHex)
        else { return false }
        return local < peer
    }
}

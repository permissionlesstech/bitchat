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
}

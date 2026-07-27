import Foundation

/// Rollout gate for the cross-platform double-ratchet transport.
///
/// Keep this disabled until the pairwise NDR implementations are reviewed and
/// ready to be enabled together on iOS and Android. Source builds and tests can
/// exercise it without advertising or routing production traffic.
enum DoubleRatchetFeature {
    #if BITCHAT_ENABLE_NDR
    static let isEnabled = true
    #else
    static let isEnabled = false
    #endif
}

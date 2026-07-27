import Foundation

/// Rollout gate for the cross-platform double-ratchet transport.
///
/// Keep this disabled until the coordinated iOS/Android kind-1402 migration
/// tracked by PR #1437 is complete. Source builds and tests can exercise the
/// implementation without advertising or routing production traffic.
enum DoubleRatchetFeature {
    #if BITCHAT_ENABLE_NDR
    static let isEnabled = true
    #else
    static let isEnabled = false
    #endif
}

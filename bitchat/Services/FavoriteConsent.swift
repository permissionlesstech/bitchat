//
// FavoriteConsent.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// One-time acknowledgement before the first favorite.
///
/// The star reads like a private bookmark but behaves like a friend request
/// plus an identity handshake: it notifies the other person immediately
/// ("alice favorited you") and transmits your durable Nostr public key so
/// mutual favorites can message over the internet. Disclosing a durable
/// identifier must not happen from a tap that looks local — the first star
/// asks once, then never again.
enum FavoriteConsent {
    private static let acknowledgedKey = "favorites.consentAcknowledged"

    static var isAcknowledged: Bool {
        isAcknowledged(in: .standard)
    }

    static func isAcknowledged(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: acknowledgedKey)
    }

    static func acknowledge(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: acknowledgedKey)
    }

    /// Panic-wipe hook: a wiped device asks again.
    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: acknowledgedKey)
    }
}

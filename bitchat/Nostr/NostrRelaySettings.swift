//
// NostrRelaySettings.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Foundation

/// Relays someone has added by hand, alongside the built-in set.
///
/// The built-in relays are four well-known clearnet hostnames, so a censor
/// blocking four names ends internet-delivered private messages for everyone.
/// Adding relays — including `.onion` addresses, or a relay run by whoever
/// needs it — is the escape hatch that does not require shipping a new build.
///
/// Stored normalized so comparisons against connection keys and the built-in
/// set are exact, and bounded so a long list cannot turn every send into a
/// fan-out across dozens of sockets.
enum NostrRelaySettings {
    /// Enough to add a personal relay, an onion address, and a couple of
    /// regional fallbacks without letting the connection fan-out grow unbounded.
    static let maxCustomRelays = 8

    private static let storageKey = "nostr.customRelays"

    static let didChangeNotification = Notification.Name("bitchat.nostrRelaySettingsDidChange")

    enum AddFailure: Error, Equatable {
        case malformed
        case alreadyPresent
        case limitReached
    }

    /// Normalized relay URLs, in the order they were added.
    static func customRelays(in defaults: UserDefaults = .standard) -> [String] {
        let stored = defaults.stringArray(forKey: storageKey) ?? []
        // Re-normalize on read: a value written by an older build, or edited
        // outside the app, must not reach the connection layer unchecked.
        var seen = Set<String>()
        return stored.compactMap { NostrRelayURL.normalized($0) }
            .filter { seen.insert($0).inserted }
    }

    /// Adds a relay, returning the normalized URL or why it was rejected.
    @discardableResult
    static func add(
        _ rawValue: String,
        builtIn: Set<String>,
        in defaults: UserDefaults = .standard
    ) -> Result<String, AddFailure> {
        // Bare hostnames are the common way people quote a relay, and wss is
        // the only sensible assumption for one.
        guard let normalized = NostrRelayURL.normalized(rawValue, defaultScheme: "wss") else {
            return .failure(.malformed)
        }

        var current = customRelays(in: defaults)
        guard !current.contains(normalized), !builtIn.contains(normalized) else {
            return .failure(.alreadyPresent)
        }
        guard current.count < maxCustomRelays else {
            return .failure(.limitReached)
        }

        current.append(normalized)
        write(current, in: defaults)
        return .success(normalized)
    }

    static func remove(_ url: String, in defaults: UserDefaults = .standard) {
        // Same default scheme as `add`, so a relay entered as a bare hostname
        // can be removed the way it was typed.
        guard let normalized = NostrRelayURL.normalized(url, defaultScheme: "wss") else { return }
        let remaining = customRelays(in: defaults).filter { $0 != normalized }
        write(remaining, in: defaults)
    }

    /// Panic-wipe hook: an added relay names somewhere someone chose to route
    /// through, which is exactly the kind of trace a wipe should not leave.
    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    private static func write(_ relays: [String], in defaults: UserDefaults) {
        defaults.set(relays, forKey: storageKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

//
// ChannelShare.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Builds plain-text location-channel invites for the system share sheet (#1497).
///
/// Text-first on purpose: a `bitchat://` deep link is dead weight for people
/// who have not installed yet, and SMS does not reliably linkify custom
/// schemes. The payload always includes the App Store URL and the geohash a
/// person can type under location channels after installing.
enum ChannelShare {
    /// App Store listing used in out-of-app invites.
    static let appStoreURL = "https://apps.apple.com/us/app/bitchat-mesh/id6748219622"

    /// Neighborhood (6) and finer imply a small cell — sharing that over SMS
    /// discloses location interest to the carrier and both handsets.
    static let precisionWarningMinimumLength = 6

    static func shouldWarn(forGeohash geohash: String) -> Bool {
        geohash.count >= precisionWarningMinimumLength
    }

    /// Channel-not-presence framing: "join #x", never "I'm in #x".
    static func payload(forGeohash geohash: String) -> String {
        payload(
            forGeohash: geohash,
            format: String(
                localized: "channel.share.payload",
                defaultValue: "join the #%1$@ channel on bitchat: bitchat://geohash/%1$@ — new to bitchat? get it at %2$@ then type #%1$@ under location channels.",
                comment: "Plain-text share payload for a location channel; %1$@ is the geohash, %2$@ is the App Store URL"
            )
        )
    }

    /// Formats without a locale on purpose. With one, Foundation wraps each
    /// argument of a right-to-left format (ar, fa, he, ur) in bidi isolates
    /// (U+2068…U+2069), and NSDataDetector then stops at the first one,
    /// cutting the deep link off at `bitchat://geohash`. Both arguments are
    /// plain strings, so a locale has nothing else to contribute. Takes the
    /// format so tests can run every locale's string through it.
    static func payload(forGeohash geohash: String, format: String) -> String {
        String(format: format, locale: nil, geohash.lowercased(), appStoreURL)
    }
}

/// Identifiable wrapper so `.sheet(item:)` can present the system share UI.
struct ChannelSharePayload: Identifiable {
    let id = UUID()
    let text: String
}

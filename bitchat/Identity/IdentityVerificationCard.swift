//
// IdentityVerificationCard.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Public-only identity card for out-of-band verification (#183).
///
/// Contains nickname, npub, and Noise fingerprint — never private key material.
/// Passphrase-sealed backup export remains future work; this card is the safe
/// first step for sharing who you are on bitchat.
struct IdentityVerificationCard: Equatable {
    let nickname: String
    let npub: String?
    let noiseFingerprint: String

    var plainText: String {
        var lines: [String] = [
            String(
                localized: "identity.card.title",
                defaultValue: "bitchat identity card",
                comment: "Title line when exporting a public identity verification card"
            ),
            "",
            String(
                format: String(
                    localized: "identity.card.nickname",
                    defaultValue: "nickname: %@",
                    comment: "Nickname line on the public identity card; %@ is the nickname"
                ),
                locale: .current,
                nickname
            ),
            String(
                format: String(
                    localized: "identity.card.fingerprint",
                    defaultValue: "noise fingerprint: %@",
                    comment: "Fingerprint line on the public identity card; %@ is the hex fingerprint"
                ),
                locale: .current,
                noiseFingerprint
            ),
        ]
        if let npub, !npub.isEmpty {
            lines.append(
                String(
                    format: String(
                        localized: "identity.card.npub",
                        defaultValue: "npub: %@",
                        comment: "Nostr npub line on the public identity card; %@ is the npub"
                    ),
                    locale: .current,
                    npub
                )
            )
        }
        return lines.joined(separator: "\n")
    }

    static func current(nickname: String, npub: String?, noiseFingerprint: String) -> IdentityVerificationCard {
        IdentityVerificationCard(
            nickname: nickname,
            npub: npub,
            noiseFingerprint: noiseFingerprint
        )
    }
}

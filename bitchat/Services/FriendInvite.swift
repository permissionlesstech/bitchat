//
// FriendInvite.swift
// bitchat
//
// Shareable friend invite links & QR payloads so two people can add each other
// and start an end-to-end encrypted chat over Nostr (and seamlessly upgrade to
// Bluetooth mesh when nearby) without meeting in radio range first.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import CryptoKit
import Foundation

enum FriendInviteError: LocalizedError, Equatable {
    case invalidLink
    case missingOwnIdentity
    case cannotInviteSelf

    var errorDescription: String? {
        switch self {
        case .invalidLink:
            return String(localized: "friend_invite.error.invalid", defaultValue: "That doesn't look like a valid bitchat invite link.", comment: "Error when a pasted or scanned friend invite link is malformed")
        case .missingOwnIdentity:
            return String(localized: "friend_invite.error.identity_unavailable", defaultValue: "Your identity keys are not ready yet. Try again in a moment.", comment: "Error when local keys are unavailable while creating or accepting an invite")
        case .cannotInviteSelf:
            return String(localized: "friend_invite.error.self", defaultValue: "That's your own invite link — share it with a friend instead.", comment: "Error when a user scans or pastes their own invite link")
        }
    }
}

struct FriendInvite: Equatable, Sendable {
    static let currentVersion = "1"
    static let universalHost = "bitchat.free"
    static let path = "/invite"
    static let maxNicknameLength = 32

    let nickname: String
    let noisePublicKey: Data
    let signingPublicKey: Data
    let nostrNpub: String

    var noiseFingerprint: String {
        noisePublicKey.sha256Fingerprint()
    }

    var stablePeerID: PeerID {
        PeerID(hexData: noisePublicKey)
    }

    /// Universal Link (`https://bitchat.free/invite?...`) safe for SMS, iMessage,
    /// WhatsApp, and QR codes.
    var universalURL: URL? {
        buildURL(scheme: "https", host: Self.universalHost, path: Self.path)
    }

    /// Custom-scheme deep link (`bitchat://invite?...`).
    var deepLinkURL: URL? {
        buildURL(scheme: "bitchat", host: "invite", path: "")
    }

    /// Share sheet text including both the invite link and App Store link.
    var sharePayloadText: String {
        let link = universalURL?.absoluteString ?? deepLinkURL?.absoluteString ?? ""
        return String(
            format: String(
                localized: "friend_invite.share_payload",
                defaultValue: "Add me (@%1$@) on bitchat to chat privately — even offline:\n%2$@\n\nGet bitchat: %3$@",
                comment: "Share sheet message for a personal friend invite; %1$@ is nickname, %2$@ is invite link, %3$@ is App Store URL"
            ),
            locale: .current,
            nickname,
            link,
            ChannelShare.appStoreURL
        )
    }

    /// Parses a FriendInvite from a URL (`https://bitchat.free/invite?...` or
    /// `bitchat://invite?...`) or from a pasted share message containing one.
    static func parse(from rawText: String) -> FriendInvite? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let directURL = URL(string: trimmed), let invite = parse(url: directURL) {
            return invite
        }

        // Extract an embedded invite URL from a pasted share message.
        let tokens = trimmed.components(separatedBy: .whitespacesAndNewlines)
        for token in tokens {
            let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;()[]<>\"'"))
            if let url = URL(string: cleaned), let invite = parse(url: url) {
                return invite
            }
        }
        return nil
    }

    static func parse(url: URL) -> FriendInvite? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let isCustomScheme = components.scheme?.lowercased() == "bitchat"
            && components.host?.lowercased() == "invite"
        let isUniversalLink = (components.scheme?.lowercased() == "https" || components.scheme?.lowercased() == "http")
            && components.host?.lowercased() == Self.universalHost
            && components.path.lowercased() == Self.path

        guard isCustomScheme || isUniversalLink else { return nil }

        var params: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value {
                params[item.name] = value
            }
        }

        if let version = params["v"], version != Self.currentVersion {
            return nil
        }

        guard let noiseEncoded = params["k"],
              let noiseKey = Base64URLCoding.decode(noiseEncoded),
              noiseKey.count == 32,
              let signingEncoded = params["s"],
              let signingKey = Base64URLCoding.decode(signingEncoded),
              signingKey.count == 32,
              let rawNostr = params["p"],
              let normalizedNpub = normalizeNostrNpub(rawNostr) else {
            return nil
        }

        let rawNick = (params["n"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedNick: String
        if rawNick.isEmpty {
            cleanedNick = "friend"
        } else {
            cleanedNick = String(rawNick.prefix(Self.maxNicknameLength))
        }

        return FriendInvite(
            nickname: cleanedNick,
            noisePublicKey: noiseKey,
            signingPublicKey: signingKey,
            nostrNpub: normalizedNpub
        )
    }

    private func buildURL(scheme: String, host: String, path: String) -> URL? {
        guard noisePublicKey.count == 32,
              signingPublicKey.count == 32,
              Self.normalizeNostrNpub(nostrNpub) != nil else {
            return nil
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if !path.isEmpty {
            components.path = path
        }
        let safeNick = String(nickname.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxNicknameLength))
        components.queryItems = [
            URLQueryItem(name: "v", value: Self.currentVersion),
            URLQueryItem(name: "n", value: safeNick.isEmpty ? "friend" : safeNick),
            URLQueryItem(name: "k", value: Base64URLCoding.encode(noisePublicKey)),
            URLQueryItem(name: "s", value: Base64URLCoding.encode(signingPublicKey)),
            URLQueryItem(name: "p", value: nostrNpub)
        ]
        return components.url
    }

    private static func normalizeNostrNpub(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("npub1") {
            guard let (hrp, data) = try? Bech32.decode(trimmed.lowercased()),
                  hrp == "npub",
                  data.count == 32 else {
                return nil
            }
            return trimmed.lowercased()
        }
        if trimmed.count == 64, let hexData = Data(hexString: trimmed), hexData.count == 32 {
            return try? Bech32.encode(hrp: "npub", data: hexData)
        }
        return nil
    }
}

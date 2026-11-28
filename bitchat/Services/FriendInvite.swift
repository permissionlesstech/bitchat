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
import BitSecp256k1
import CryptoKit
import Foundation
import Security

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

/// Authenticated multi-key friend invite bundle.
///
/// BitChat uses three distinct cryptographic primitives by design:
/// - `noisePublicKey`: 32-byte Curve25519 (X25519) static key for BLE Noise sessions.
/// - `signingPublicKey`: 32-byte Ed25519 key for BLE mesh announces and group auth.
/// - `nostrNpub`: 32-byte secp256k1 x-only key for Nostr NIP-17 DMs.
///
/// Because these keys live on different curves, `bindingSignature` carries a
/// 64-byte BIP-340 Schnorr signature created with the `nostrNpub`'s private key
/// over `SHA256("bitchat-invite-v1" || noisePublicKey || signingPublicKey)`.
/// `parse` rejects any invite whose binding signature is missing or invalid so
/// an attacker cannot pair a victim's `npub` with their own Noise/signing keys.
struct FriendInvite: Equatable, Sendable {
    static let currentVersion = "1"
    static let universalHost = "bitchat.free"
    static let path = "/invite"
    static let maxNicknameLength = 32
    static let bindingDomain = Data("bitchat-invite-v1".utf8)

    let nickname: String
    let noisePublicKey: Data
    let signingPublicKey: Data
    let nostrNpub: String
    /// 64-byte BIP-340 Schnorr signature by `nostrNpub` over `bindingDigest`.
    let bindingSignature: Data

    var noiseFingerprint: String {
        noisePublicKey.sha256Fingerprint()
    }

    var stablePeerID: PeerID {
        PeerID(hexData: noisePublicKey)
    }

    /// Creates a cryptographically bound invite signed by `nostrIdentity`.
    static func makeSigned(
        nickname: String,
        noisePublicKey: Data,
        signingPublicKey: Data,
        nostrIdentity: NostrIdentity
    ) -> FriendInvite? {
        guard noisePublicKey.count == 32,
              signingPublicKey.count == 32,
              let normalizedNpub = normalizeNostrNpub(nostrIdentity.npub),
              let schnorrKey = try? nostrIdentity.schnorrSigningKey() else {
            return nil
        }
        var auxRand = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, auxRand.count, &auxRand) == errSecSuccess else {
            return nil
        }
        let digest = bindingDigest(noisePublicKey: noisePublicKey, signingPublicKey: signingPublicKey)
        guard let signature = try? schnorrKey.sign(message: Array(digest), auxiliaryRand: auxRand),
              signature.count == 64 else {
            return nil
        }
        let cleanedNick = sanitizedNickname(nickname)
        return FriendInvite(
            nickname: cleanedNick,
            noisePublicKey: noisePublicKey,
            signingPublicKey: signingPublicKey,
            nostrNpub: normalizedNpub,
            bindingSignature: signature
        )
    }

    /// SHA-256 digest signed by the invitee's Nostr secp256k1 key to bind
    /// their Curve25519 Noise key and Ed25519 mesh signing key to their `npub`.
    static func bindingDigest(noisePublicKey: Data, signingPublicKey: Data) -> Data {
        var preimage = bindingDomain
        preimage.append(noisePublicKey)
        preimage.append(signingPublicKey)
        return Data(SHA256.hash(data: preimage))
    }

    /// Verifies that `signature` is a valid BIP-340 Schnorr signature by
    /// `nostrNpub` over `(noisePublicKey, signingPublicKey)`.
    static func verifyBinding(
        noisePublicKey: Data,
        signingPublicKey: Data,
        nostrNpub: String,
        signature: Data
    ) -> Bool {
        guard noisePublicKey.count == 32,
              signingPublicKey.count == 32,
              signature.count == 64,
              let (_, xonlyPubkey) = try? Bech32.decode(nostrNpub.lowercased()),
              xonlyPubkey.count == 32 else {
            return false
        }
        let digest = bindingDigest(noisePublicKey: noisePublicKey, signingPublicKey: signingPublicKey)
        return BitSecp256k1.verifySchnorr(
            signature: signature,
            message: Array(digest),
            xonlyPublicKey: xonlyPubkey
        )
    }

    /// Universal Link (`https://bitchat.free/invite?...`) accepted by `parse`
    /// and `onContinueUserActivity` once associated domains are provisioned.
    var universalURL: URL? {
        buildURL(scheme: "https", host: Self.universalHost, path: Self.path)
    }

    /// Custom-scheme deep link (`bitchat://invite?...`) handled directly by
    /// the app's registered `bitchat` URL scheme.
    var deepLinkURL: URL? {
        buildURL(scheme: "bitchat", host: "invite", path: "")
    }

    /// Share sheet text including the directly deliverable `bitchat://` invite
    /// link and the App Store link.
    var sharePayloadText: String {
        let link = deepLinkURL?.absoluteString ?? universalURL?.absoluteString ?? ""
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

    /// Encodes a backwards-compatible `[FAVORITED]` Nostr notification carrying
    /// this user's cryptographically bound Noise + Ed25519 + Nostr identity so
    /// a remote friend who has never met us over BLE can verify and record our
    /// full identity. Legacy 1.x clients split on `:` and read only `parts[1]`.
    func favoriteAcceptancePayload() -> String {
        let k = Base64URLCoding.encode(noisePublicKey)
        let s = Base64URLCoding.encode(signingPublicKey)
        let b = Base64URLCoding.encode(bindingSignature)
        return "[FAVORITED]:\(nostrNpub):\(k):\(s):\(b)"
    }

    /// Parses and verifies the optional signed identity bundle appended to a
    /// `[FAVORITED]` Nostr notification. When `expectedSenderPubkeyHex` is
    /// provided (the NIP-17 authenticated sender), the embedded `npub` must
    /// match it exactly so a sender cannot claim another person's `npub`.
    static func parseFavoriteAcceptancePayload(
        _ content: String,
        expectedSenderPubkeyHex: String?,
        nickname: String
    ) -> FriendInvite? {
        guard content.hasPrefix("[FAVORITED]:") else { return nil }
        let parts = content.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 5,
              let normalizedNpub = normalizeNostrNpub(String(parts[1])),
              let noiseKey = Base64URLCoding.decode(String(parts[2])),
              noiseKey.count == 32,
              let signingKey = Base64URLCoding.decode(String(parts[3])),
              signingKey.count == 32,
              let signature = Base64URLCoding.decode(String(parts[4])),
              signature.count == 64 else {
            return nil
        }

        if let expectedHex = expectedSenderPubkeyHex?.lowercased(), !expectedHex.isEmpty {
            guard let (_, npubBytes) = try? Bech32.decode(normalizedNpub),
                  npubBytes.hexEncodedString().lowercased() == expectedHex else {
                return nil
            }
        }

        guard verifyBinding(
            noisePublicKey: noiseKey,
            signingPublicKey: signingKey,
            nostrNpub: normalizedNpub,
            signature: signature
        ) else {
            return nil
        }

        return FriendInvite(
            nickname: sanitizedNickname(nickname),
            noisePublicKey: noiseKey,
            signingPublicKey: signingKey,
            nostrNpub: normalizedNpub,
            bindingSignature: signature
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
              let normalizedNpub = normalizeNostrNpub(rawNostr),
              let bindingEncoded = params["b"],
              let bindingSig = Base64URLCoding.decode(bindingEncoded),
              bindingSig.count == 64,
              verifyBinding(
                  noisePublicKey: noiseKey,
                  signingPublicKey: signingKey,
                  nostrNpub: normalizedNpub,
                  signature: bindingSig
              ) else {
            return nil
        }

        return FriendInvite(
            nickname: sanitizedNickname(params["n"] ?? ""),
            noisePublicKey: noiseKey,
            signingPublicKey: signingKey,
            nostrNpub: normalizedNpub,
            bindingSignature: bindingSig
        )
    }

    private func buildURL(scheme: String, host: String, path: String) -> URL? {
        guard noisePublicKey.count == 32,
              signingPublicKey.count == 32,
              Self.normalizeNostrNpub(nostrNpub) != nil,
              bindingSignature.count == 64,
              Self.verifyBinding(
                  noisePublicKey: noisePublicKey,
                  signingPublicKey: signingPublicKey,
                  nostrNpub: nostrNpub,
                  signature: bindingSignature
              ) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if !path.isEmpty {
            components.path = path
        }
        components.queryItems = [
            URLQueryItem(name: "v", value: Self.currentVersion),
            URLQueryItem(name: "n", value: Self.sanitizedNickname(nickname)),
            URLQueryItem(name: "k", value: Base64URLCoding.encode(noisePublicKey)),
            URLQueryItem(name: "s", value: Base64URLCoding.encode(signingPublicKey)),
            URLQueryItem(name: "p", value: nostrNpub),
            URLQueryItem(name: "b", value: Base64URLCoding.encode(bindingSignature))
        ]
        return components.url
    }

    private static func sanitizedNickname(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "friend" : String(trimmed.prefix(Self.maxNicknameLength))
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

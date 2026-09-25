//
// MessageDeepLink.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation

/// Builds shareable deep links for individual messages (#587).
///
/// Links use the existing `bitchat://` scheme so they work today without
/// universal-link setup. Recipients with bitchat installed can open the
/// conversation scope; the message ID helps locate the line in-thread.
enum MessageDeepLink {
    enum Scope: Equatable {
        case mesh
        case geohash(String)
        case direct(peerID: PeerID)

        var host: String {
            switch self {
            case .mesh: return "mesh"
            case .geohash: return "geohash"
            case .direct: return "dm"
            }
        }

        var path: String {
            switch self {
            case .mesh:
                return "/"
            case .geohash(let geohash):
                return "/\(geohash.lowercased())"
            case .direct(let peerID):
                return "/\(peerID.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? peerID.id)"
            }
        }
    }

    static func url(for messageID: String, scope: Scope) -> URL? {
        var components = URLComponents()
        components.scheme = "bitchat"
        components.host = scope.host
        components.path = scope.path
        components.queryItems = [
            URLQueryItem(name: "mid", value: messageID)
        ]
        return components.url
    }

    /// The message ID carried by a `bitchat://` link, if any.
    static func messageID(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "mid" })?
            .value?
            .trimmedOrNilIfEmpty
    }

    /// The row identity `MessageListView` gives a message, so a deep link can
    /// scroll to it. Must match how `MessageDisplayItem.id` is composed.
    static func rowID(contextKey: String, messageID: String) -> String {
        "\(contextKey)|\(messageID)"
    }

    /// Validates the peer ID in a `bitchat://dm/<id>` link.
    ///
    /// The path arrives from any app or webpage, so its shape is checked before
    /// it reaches conversation state — an arbitrary string would open a
    /// conversation against an identity that never existed. This mirrors the
    /// charset/length gate the geohash handler already applies.
    ///
    /// Only the conversation shapes this file emits links for are accepted:
    /// a bare 16-hex mesh peer, a `nostr_`-prefixed geo DM, or a `group_`
    /// conversation. Routing-only prefixes (`noise:`, `name:`, `mesh:`,
    /// `bridge:`) and geohash *chat* IDs are rejected.
    static func directConversationTarget(fromPath path: String) -> PeerID? {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let decoded = trimmed.removingPercentEncoding ?? trimmed
        guard let candidate = decoded.trimmedOrNilIfEmpty, candidate.count <= 64 else { return nil }

        let peerID = PeerID(str: candidate)
        let hex = Set("0123456789abcdef")
        guard !peerID.bare.isEmpty, peerID.bare.allSatisfy({ hex.contains($0) }) else { return nil }

        switch peerID.prefix {
        case .empty, .geoDM:
            return peerID.bare.count == 16 ? peerID : nil
        case .group:
            return peerID.bare.count == 32 ? peerID : nil
        case .mesh, .name, .noise, .geoChat, .bridge:
            return nil
        }
    }

    /// How large the render window must be for `index` to be inside it.
    ///
    /// A link can point at a message older than the window currently renders;
    /// without growing it the row is not in the hierarchy and `scrollTo` is a
    /// no-op. Never shrinks an already-larger window.
    static func windowCount(toReveal index: Int, inTotal total: Int, current: Int) -> Int {
        guard (0..<total).contains(index) else { return current }
        return max(current, total - index)
    }

    static func plainText(for messageID: String, scope: Scope) -> String {
        guard let link = url(for: messageID, scope: scope)?.absoluteString else {
            return messageID
        }
        return String(
            format: String(
                localized: "message.link.plaintext",
                defaultValue: "open in bitchat: %@",
                comment: "Plain-text payload when copying a message deep link; %@ is the bitchat:// URL"
            ),
            locale: .current,
            link
        )
    }
}

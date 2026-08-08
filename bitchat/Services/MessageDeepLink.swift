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

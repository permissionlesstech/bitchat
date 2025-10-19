//
// CommandsInfo.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

// MARK: - CommandInfo Enum

enum CommandInfo: String, CaseIterable, Identifiable {
    case block = "/block"
    case clear = "/clear"
    case hug = "/hug"
    case message = "/m, /msg"
    case slap = "/slap"
    case unblock = "/unblock"
    case who = "/w"
    case favorite = "/fav"
    case unfavorite = "/unfav"

    var id: String { rawValue }

    var localizedSyntax: String? {
        switch self {
        case .block, .hug, .message, .slap, .unblock, .favorite, .unfavorite:
            return NSLocalizedString("content.input.nickname_placeholder", comment: "")
        default:
            return nil
        }
    }

    var descriptionKey: String {
        switch self {
        case .block: return "content.commands.block"
        case .clear: return "content.commands.clear"
        case .hug: return "content.commands.hug"
        case .message: return "content.commands.message"
        case .slap: return "content.commands.slap"
        case .unblock: return "content.commands.unblock"
        case .who: return "content.commands.who"
        case .favorite: return "content.commands.favorite"
        case .unfavorite: return "content.commands.unfavorite"
        }
    }

    static func all(isGeoPublic: Bool, isGeoDM: Bool) -> [CommandInfo] {
        var list: [CommandInfo] = [
            .block, .clear, .hug, .message, .slap, .unblock, .who
        ]

        if !(isGeoPublic || isGeoDM) {
            list.append(contentsOf: [.favorite, .unfavorite])
        }

        return list
    }
}

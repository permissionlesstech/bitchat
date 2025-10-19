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

    var localizedDescription: String {
        switch self {
        case .block: return NSLocalizedString("content.commands.block", comment: "about block command.")
        case .clear: return NSLocalizedString("content.commands.clear", comment: "about clear command.")
        case .hug: return NSLocalizedString("content.commands.hug", comment: "about hug command.")
        case .message: return NSLocalizedString("content.commands.message", comment: "about message command.")
        case .slap: return NSLocalizedString("content.commands.slap", comment: "about slap command.")
        case .unblock: return NSLocalizedString("content.commands.unblock", comment: "abbout unblock command.")
        case .who: return NSLocalizedString("content.commands.who", comment: "about who command.")
        case .favorite: return NSLocalizedString("content.commands.favorite", comment: "about favorite command.")
        case .unfavorite: return NSLocalizedString("content.commands.unfavorite", comment: "about unfavorite command.")
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

//
// CommandsInfo.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

// MARK: - CommandInfo Enum

enum CommandInfo: Identifiable {
    case block, clear, hug, message, slap, unblock, who, favorite, unfavorite
    
    var id: String { name }

    var name: String {
        String(describing: self)
    }
    
    var aliases: [String] {
        switch self {
        case .message:
            return ["/m", "/msg"]
        case .who:
            return ["/w", "/who"]
        default:
            return ["/\(name)"]
        }
    }
    
    var primaryAlias: String { aliases.first ?? "" }
    
    var commandsPlaceholderKey: String? {
        switch self {
        case .block, .hug, .message, .slap, .unblock, .favorite, .unfavorite:
            return "content.input.nickname_placeholder"
        case .clear, .who:
            return nil
        }
    }
    
    var commandsPlaceholder: String? {
        guard let key = commandsPlaceholderKey else { return nil }
        return NSLocalizedString(key, comment: "placeholder for \(name) command")
    }

    var commandsDescriptionKey: String {
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

    var commandsDescription: String {
        NSLocalizedString(commandsDescriptionKey, comment: "about \(name) command")
    }
    
    static func all(isGeoPublic: Bool, isGeoDM: Bool) -> [CommandInfo] {
        let mandatory: [CommandInfo] = [.block, .clear, .hug, .message, .slap, .unblock, .who]
        let optional: [CommandInfo] = [.favorite, .unfavorite]
        
        return mandatory + (isGeoPublic || isGeoDM ? [] : optional)
    }
}

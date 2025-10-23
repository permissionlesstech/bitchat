//
// CommandsInfo.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

// MARK: - CommandInfo Enum

enum CommandInfo: String, Identifiable {
    case block
    case clear
    case hug
    case message
    case slap
    case unblock
    case who
    case favorite
    case unfavorite
    
    var id: String { rawValue }
    
    var aliases: [String] {
        switch self {
        case .message:
            return ["/m", "/msg"]
        case .who:
            return ["/w", "/who"]
        default:
            return ["/\(rawValue)"]
        }
    }
    
    var primaryAlias: String {
        aliases[0]
    }
    
    private var placeholderKey: String? {
        switch self {
        case .clear, .who:
            return nil
        default:
            return "content.input.nickname_placeholder"
        }
    }
    
    var placeholder: String? {
        guard let key = placeholderKey else { return nil }
        return NSLocalizedString(key, comment: "placeholder for \(rawValue) command")
    }
    
    private var descriptionKey: String {
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
    
    var description: String {
        NSLocalizedString(descriptionKey, comment: "about \(rawValue) command")
    }
    
    static func all(isGeoPublic: Bool, isGeoDM: Bool) -> [CommandInfo] {
        let mandatory: [CommandInfo] = [.block, .clear, .hug, .message, .slap, .unblock, .who]
        let optional: [CommandInfo] = [.favorite, .unfavorite]
        let includeOptional = !(isGeoPublic || isGeoDM)
        
        return mandatory + (includeOptional ? optional : [])
    }
}

// MARK: - Custom Init

extension CommandInfo {
    init?(from input: String) {
        let cleaned = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let rawInput = cleaned.hasPrefix("/") ? String(cleaned.dropFirst()) : cleaned
        
        for command in CommandInfo.all(isGeoPublic: false, isGeoDM: false) {
            let normalizedAliases = command.aliases.map { $0.lowercased().replacingOccurrences(of: "/", with: "") }
            if normalizedAliases.contains(rawInput) {
                self = command
                return
            }
        }

        self.init(rawValue: rawInput)
    }
}

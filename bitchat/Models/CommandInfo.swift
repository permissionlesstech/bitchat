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
    
    var placeholder: String? {
        switch self {
        case .block, .hug, .message, .slap, .unblock, .favorite, .unfavorite:
            return String(localized: "content.input.nickname_placeholder")
        case .clear, .who:
            return nil
        }
    }
    
    var description: String {
        switch self {
        case .block: return String(localized: "content.commands.block")
        case .clear: return String(localized: "content.commands.clear")
        case .hug: return String(localized: "content.commands.hug")
        case .message: return String(localized: "content.commands.message")
        case .slap: return String(localized: "content.commands.slap")
        case .unblock: return String(localized: "content.commands.unblock")
        case .who: return String(localized: "content.commands.who")
        case .favorite: return String(localized: "content.commands.favorite")
        case .unfavorite: return String(localized: "content.commands.unfavorite")
        }
    }
    
    static func all(isGeoPublic: Bool, isGeoDM: Bool) -> [CommandInfo] {
        let mandatory: [CommandInfo] = [.block, .clear, .hug, .message, .slap, .unblock, .who]
        let optional: [CommandInfo] = [.favorite, .unfavorite]
        let includeOptional = !(isGeoPublic || isGeoDM)
        
        if includeOptional {
            return mandatory + optional
        }
        
        return mandatory
    }
}

// MARK: - Custom Init

extension CommandInfo {
    static func fromAlias(_ input: String, isGeoPublic: Bool, isGeoDM: Bool) -> CommandInfo? {
        let cleaned = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let rawInput = cleaned.hasPrefix("/") ? String(cleaned.dropFirst()) : cleaned
        
        return all(isGeoPublic: isGeoPublic, isGeoDM: isGeoDM).first {
            $0.aliases.map {
                $0.lowercased().replacingOccurrences(of: "/", with: "")
            }.contains(rawInput)
        } ?? CommandInfo(rawValue: rawInput)
    }
    
    init?(from input: String, isGeoPublic: Bool, isGeoDM: Bool) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else {
            return nil
        }
        guard let command = CommandInfo.fromAlias(trimmed, isGeoPublic: isGeoPublic, isGeoDM: isGeoDM) else {
            return nil
        }
        self = command
    }
}

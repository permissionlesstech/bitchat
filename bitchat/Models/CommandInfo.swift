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
    // Raw values must match the aliases CommandProcessor actually accepts —
    // the suggestion panel is the app's only command-discovery surface, and
    // suggesting a spelling the processor rejects teaches users dead ends.
    case block
    case clear
    case group
    case help
    case hug
    case message = "msg"
    case slap
    case unblock
    case who
    case favorite = "fav"
    case unfavorite = "unfav"
    case ping
    case trace

    var id: String { rawValue }

    var alias: String { "/" + rawValue }

    var placeholder: String? {
        switch self {
        case .block, .hug, .message, .slap, .unblock, .favorite, .unfavorite, .ping, .trace:
            return "<" + String(localized: "content.input.nickname_placeholder") + ">"
        case .group:
            return "<" + String(localized: "content.input.group_placeholder") + ">"
        case .clear, .help, .who:
            return nil
        }
    }

    var description: String {
        switch self {
        case .block:        String(localized: "content.commands.block")
        case .clear:        String(localized: "content.commands.clear")
        case .group:        String(localized: "content.commands.group")
        case .help:         String(localized: "content.commands.help")
        case .hug:          String(localized: "content.commands.hug")
        case .message:      String(localized: "content.commands.message")
        case .slap:         String(localized: "content.commands.slap")
        case .unblock:      String(localized: "content.commands.unblock")
        case .who:          String(localized: "content.commands.who")
        case .favorite:     String(localized: "content.commands.favorite")
        case .unfavorite:   String(localized: "content.commands.unfavorite")
        case .ping:         String(localized: "content.commands.ping")
        case .trace:        String(localized: "content.commands.trace")
        }
    }

    static func all(isGeoPublic: Bool, isGeoDM: Bool) -> [CommandInfo] {
        let baseCommands: [CommandInfo] = [.block, .unblock, .clear, .help, .hug, .message, .slap, .who]
        // The processor rejects favorites, groups and mesh diagnostics in
        // geohash contexts, so only suggest them where they actually work: mesh.
        if isGeoPublic || isGeoDM {
            return baseCommands
        }
        return baseCommands + [.favorite, .unfavorite, .group, .ping, .trace]
    }
}

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
    case pay
    case unblock
    case who
    case favorite = "fav"
    case unfavorite = "unfav"
    case ping
    case trace
    case drop

    var id: String { rawValue }

    var alias: String { "/" + rawValue }

    var placeholder: String? {
        switch self {
        case .block, .hug, .message, .slap, .unblock, .favorite, .unfavorite, .ping, .trace:
            return "<" + String(localized: "content.input.nickname_placeholder") + ">"
        case .group:
            return "<" + String(localized: "content.input.group_placeholder") + ">"
        case .pay:
            return "<" + String(localized: "content.input.token_placeholder") + ">"
        case .drop:
            return "<" + String(localized: "content.input.note_placeholder") + ">"
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
        case .pay:          String(localized: "content.commands.pay")
        case .slap:         String(localized: "content.commands.slap")
        case .unblock:      String(localized: "content.commands.unblock")
        case .who:          String(localized: "content.commands.who")
        case .favorite:     String(localized: "content.commands.favorite")
        case .unfavorite:   String(localized: "content.commands.unfavorite")
        case .ping:         String(localized: "content.commands.ping")
        case .trace:        String(localized: "content.commands.trace")
        case .drop:         String(localized: "content.commands.drop")
        }
    }

    static func all(isGeoPublic: Bool, isGeoDM: Bool) -> [CommandInfo] {
        var commands: [CommandInfo] = [.block, .unblock, .clear, .drop, .help, .hug, .message, .slap, .who]
        // Cashu tokens are bearer instruments: in a public geohash any nearby
        // stranger can redeem one, so don't *suggest* /pay there (the
        // processor still allows it behind an explicit "public" confirm).
        // Payments make sense in every DM and in mesh public.
        if !isGeoPublic {
            commands.append(.pay)
        }
        // The processor rejects favorites, groups, and mesh diagnostics in
        // geohash contexts, so only suggest them where they work: mesh.
        if isGeoPublic || isGeoDM {
            return commands
        }
        return commands + [.favorite, .unfavorite, .ping, .trace, .group]
    }
}

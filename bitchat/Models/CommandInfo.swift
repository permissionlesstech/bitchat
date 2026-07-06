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

    var id: String { rawValue }

    var alias: String { "/" + rawValue }

    var placeholder: String? {
        switch self {
        case .block, .hug, .message, .slap, .unblock, .favorite, .unfavorite, .ping, .trace:
            return "<" + String(localized: "content.input.nickname_placeholder", defaultValue: "nickname") + ">"
        case .group:
            return "<" + String(localized: "content.input.group_placeholder", defaultValue: "create|invite|leave|list") + ">"
        case .pay:
            return "<" + String(localized: "content.input.token_placeholder", defaultValue: "token") + ">"
        case .clear, .help, .who:
            return nil
        }
    }

    var description: String {
        switch self {
        case .block:        String(localized: "content.commands.block", defaultValue: "block or list blocked peers")
        case .clear:        String(localized: "content.commands.clear", defaultValue: "clear chat messages")
        case .group:        String(localized: "content.commands.group", defaultValue: "create or manage private groups")
        case .help:         String(localized: "content.commands.help", defaultValue: "show available commands")
        case .hug:          String(localized: "content.commands.hug", defaultValue: "send someone a warm hug")
        case .message:      String(localized: "content.commands.message", defaultValue: "send private message")
        case .pay:          String(localized: "content.commands.pay", defaultValue: "send a cashu ecash token in this chat")
        case .slap:         String(localized: "content.commands.slap", defaultValue: "slap someone with a trout")
        case .unblock:      String(localized: "content.commands.unblock", defaultValue: "unblock a peer")
        case .who:          String(localized: "content.commands.who", defaultValue: "see who's online")
        case .favorite:     String(localized: "content.commands.favorite", defaultValue: "add to favorites")
        case .unfavorite:   String(localized: "content.commands.unfavorite", defaultValue: "remove from favorites")
        case .ping:         String(localized: "content.commands.ping", defaultValue: "measure round-trip time to a mesh peer")
        case .trace:        String(localized: "content.commands.trace", defaultValue: "estimate the mesh path to a peer")
        }
    }

    static func all(isGeoPublic: Bool, isGeoDM: Bool) -> [CommandInfo] {
        var commands: [CommandInfo] = [.block, .unblock, .clear, .help, .hug, .message, .slap, .who]
        // Cashu tokens are bearer instruments: in a public geohash any nearby
        // stranger can redeem one, so don't *suggest* /pay there (the
        // processor still allows it behind an explicit "public" confirm).
        // Payments make sense in every DM and in mesh public.
        if !isGeoPublic {
            commands.append(.pay)
        }
        // The processor rejects favorites, groups and mesh diagnostics in
        // geohash contexts, so only suggest them where they actually work: mesh.
        if isGeoPublic || isGeoDM {
            return commands
        }
        return commands + [.favorite, .unfavorite, .group, .ping, .trace]
    }
}

//
// CommandSuggestionNavigation.swift
// bitchat
//
// Keyboard decisions for the slash-command suggestion panel (#233).
// Kept free of SwiftUI so the return-vs-send rule can be tested without
// a field editor.
//

import Foundation

enum CommandSuggestionNavigation {
    struct Command: Equatable {
        var alias: String
        var hasPlaceholder: Bool
    }

    struct Panel: Equatable {
        var aliases: [String]
        /// Arguments have started. The row is a usage reminder, not a completion.
        var isUsageReminder: Bool
        /// The typed text is already a whole alias (`/help`). Return must send
        /// it. An incomplete prefix (`/he`) is the case return completes.
        var typedIsCompleteCommand: Bool
    }

    static func panel(typedText: String, commands: [Command]) -> Panel? {
        guard typedText.hasPrefix("/") else { return nil }
        let lower = typedText.lowercased()
        if let space = lower.firstIndex(of: " ") {
            let typed = String(lower[..<space])
            let matches = commands.filter {
                $0.alias.lowercased() == typed && $0.hasPlaceholder
            }
            guard !matches.isEmpty else { return nil }
            return Panel(
                aliases: matches.map(\.alias),
                isUsageReminder: true,
                typedIsCompleteCommand: true
            )
        }
        let matches = commands.filter { $0.alias.lowercased().hasPrefix(lower) }
        guard !matches.isEmpty else { return nil }
        let complete = commands.contains { $0.alias.lowercased() == lower }
        return Panel(
            aliases: matches.map(\.alias),
            isUsageReminder: false,
            typedIsCompleteCommand: complete
        )
    }

    /// Return completes an incomplete prefix. A finished command, or one
    /// already taking arguments, still sends (#233).
    static func returnInserts(_ panel: Panel) -> Bool {
        !panel.isUsageReminder && !panel.typedIsCompleteCommand && !panel.aliases.isEmpty
    }

    static func clamped(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }

    static func moved(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let base = clamped(index, count: count)
        let raw = base + delta
        let wrapped = raw % count
        return wrapped >= 0 ? wrapped : wrapped + count
    }
}

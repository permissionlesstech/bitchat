//
// AutocompleteService.swift
// bitchat
//
// Handles autocomplete suggestions for mentions and commands
// This is free and unencumbered software released into the public domain.
//

import Foundation

/// Manages autocomplete functionality for chat
final class AutocompleteService {
    private static let mentionRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "@([\\p{L}0-9_]*)$", options: [])
    }()

    private static let commandRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "^/([a-z]*)$", options: [.caseInsensitive])
    }()

    // Commands are lowercase - no need to call lowercased() when sorting
    private let commands = [
        "/block", "/clear", "/fav", "/hug",
        "/msg", "/slap", "/unfav", "/unblock", "/who"
    ]

    private let noArgCommands: Set<String>

    init() {
        self.noArgCommands = ["who", "clear"]
    }

    /// Get autocomplete suggestions for current text
    func getSuggestions(for text: String, peers: [String], cursorPosition: Int) -> (suggestions: [String], range: NSRange?) {
        let pos = Swift.max(0, Swift.min(cursorPosition, text.count))
        let textToPosition = String(text.prefix(pos))

        // Check for mention autocomplete
        if let (mentionSuggestions, mentionRange) = getMentionSuggestions(textToPosition, peers: peers) {
            return (mentionSuggestions, mentionRange)
        }

        // Don't handle command autocomplete here - ContentView handles it with better UI
        // if let (commandSuggestions, commandRange) = getCommandSuggestions(textToPosition) {
        //     return (commandSuggestions, commandRange)
        // }

        return ([], nil)
    }

    /// Apply selected suggestion to text
    func applySuggestion(_ suggestion: String, to text: String, range: NSRange) -> String {
        guard let textRange = Range(range, in: text) else { return text }

        var replacement = suggestion

        // Add space after command if it takes arguments
        if suggestion.hasPrefix("/") && needsArgument(command: suggestion) {
            replacement += " "
        }

        return text.replacingCharacters(in: textRange, with: replacement)
    }

    // MARK: - Private Methods

    private func getMentionSuggestions(_ text: String, peers: [String]) -> ([String], NSRange)? {
        let regex = Self.mentionRegex

        let nsText = text as NSString
        let fullRangeAll = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, options: [], range: fullRangeAll) else { return nil }

        let fullRange = match.range(at: 0)
        let captureRange = match.range(at: 1)
        let prefix = nsText.substring(with: captureRange).lowercased()

        // Normalize peers once to avoid repeated allocations
        let normalized = peers.map { (orig: $0, lower: $0.lowercased()) }

        let matches = normalized
            .filter { $0.lower.hasPrefix(prefix) }
            .sorted { $0.lower < $1.lower }
            .prefix(5)
            .map { "@\($0.orig)" }

        return matches.isEmpty ? nil : (Array(matches), fullRange)
    }

    private func getCommandSuggestions(_ text: String) -> ([String], NSRange)? {
        let regex = Self.commandRegex

        let nsText = text as NSString
        let fullRangeAll = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, options: [], range: fullRangeAll) else { return nil }

        let fullRange = match.range(at: 0)
        let captureRange = match.range(at: 1)
        let prefix = nsText.substring(with: captureRange).lowercased()

        // Commands are pre-sorted and lowercase
        let suggestions = commands
            .filter { $0.hasPrefix("/\(prefix)") }
            .prefix(5)

        return suggestions.isEmpty ? nil : (Array(suggestions), fullRange)
    }

    private func needsArgument(command: String) -> Bool {
        let name = command.hasPrefix("/") ? String(command.dropFirst()) : command
        return !noArgCommands.contains(name.lowercased())
    }
}

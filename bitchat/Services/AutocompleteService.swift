//
// AutocompleteService.swift
// bitchat
//
// Handles autocomplete suggestions for mentions
// This is free and unencumbered software released into the public domain.
//

import Foundation

/// Manages autocomplete functionality for chat
final class AutocompleteService {
    /// Compiled via `SafeRegex` so a bad pattern logs and disables matching
    /// instead of silently returning nil forever (`try?` did the latter).
    private let mentionRegex = SafeRegex.compile("@([\\p{L}0-9_]*)$")

    /// Get autocomplete suggestions for current text
    func getSuggestions(for text: String, peers: [String], cursorPosition: Int) -> (suggestions: [String], range: NSRange?) {
        let textToPosition = String(text.prefix(cursorPosition))

        // Mentions only — slash-command suggestions are owned by
        // `CommandSuggestionsView` / the composer, not this service.
        if let (mentionSuggestions, mentionRange) = getMentionSuggestions(textToPosition, peers: peers) {
            return (mentionSuggestions, mentionRange)
        }

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
        let nsText = text as NSString
        let matches = mentionRegex.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: nsText.length)
        )

        guard let match = matches.last else { return nil }

        let fullRange = match.range(at: 0)
        let captureRange = match.range(at: 1)
        let prefix = nsText.substring(with: captureRange).normalizedNickname.lowercased()

        let suggestions = peers
            .filter { $0.normalizedNickname.lowercased().hasPrefix(prefix) }
            .sorted()
            .prefix(5)
            .map { "@\($0)" }

        return suggestions.isEmpty ? nil : (Array(suggestions), fullRange)
    }

    private func needsArgument(command: String) -> Bool {
        switch command {
        case "/who", "/clear":
            return false
        default:
            return true
        }
    }
}

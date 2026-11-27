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
    private typealias Patterns = MessageFormattingEngine.Patterns

    /// Whether the text before the cursor ends in an `@` mention token: the
    /// only case `getSuggestions` can return anything for, whatever the peers.
    /// Lets callers skip assembling the peer list after every keystroke.
    static func hasMentionToken(in text: String, cursorPosition: Int) -> Bool {
        mentionPrefix(in: text, cursorPosition: cursorPosition) != nil
    }

    /// Returns the normalized lowercased prefix of a trailing `@mention` token
    /// ending at `cursorPosition`, or `nil` when the cursor is not inside one.
    /// Fast-rejects texts without `@` without allocating or bridging to NSString.
    static func mentionPrefix(in text: String, cursorPosition: Int) -> String? {
        guard cursorPosition > 0, text.contains("@") else { return nil }
        let textToPosition = cursorPosition >= text.count ? text : String(text.prefix(cursorPosition))
        let nsText = textToPosition as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = Patterns.mentionAutocomplete.firstMatch(in: textToPosition, options: [], range: range) else {
            return nil
        }
        return nsText.substring(with: match.range(at: 1)).normalizedNickname.lowercased()
    }

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
        return text.replacingCharacters(in: textRange, with: suggestion)
    }

    // MARK: - Private Methods

    private func getMentionSuggestions(_ text: String, peers: [String]) -> ([String], NSRange)? {
        let nsText = text as NSString
        let matches = Patterns.mentionAutocomplete.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: nsText.length)
        )

        guard let match = matches.last else { return nil }

        let fullRange = match.range(at: 0)
        let captureRange = match.range(at: 1)
        let prefix = nsText.substring(with: captureRange).normalizedNickname.lowercased()

        // Maintain only the top 5 lexicographically smallest matching peers so
        // typing `@` in a crowded room stays O(N) without sorting every peer.
        var top: [String] = []
        top.reserveCapacity(6)
        for peer in peers {
            if !prefix.isEmpty && !peer.normalizedNickname.lowercased().hasPrefix(prefix) {
                continue
            }
            if top.count == 5, let last = top.last, peer >= last {
                continue
            }
            let insertIdx = top.firstIndex { peer < $0 } ?? top.endIndex
            top.insert(peer, at: insertIdx)
            if top.count > 5 {
                top.removeLast()
            }
        }

        let suggestions = top.map { "@\($0)" }
        return suggestions.isEmpty ? nil : (suggestions, fullRange)
    }
}

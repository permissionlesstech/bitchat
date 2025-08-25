//
// AutocompleteService.swift
// bitchat
//
// Handles autocomplete suggestions for mentions and commands
// This is free and unencumbered software released into the public domain.
//

import Foundation

/// Manages autocomplete functionality for chat
class AutocompleteService {
    private let mentionRegex = try? NSRegularExpression(pattern: "@([\\p{L}0-9_]*)$", options: [])
    private let commandRegex = try? NSRegularExpression(pattern: "^/([a-z]*)$", options: [])
    
    private let commands = [
        "/msg", "/who", "/clear",
        "/hug", "/slap", "/fav", "/unfav",
        "/block", "/unblock"
    ]
    
    /// Get autocomplete suggestions for current text
    func getSuggestions(for text: String, peers: [String], cursorPosition: Int) -> (suggestions: [String], range: NSRange?) {
        let textToPosition = String(text.prefix(cursorPosition))
        
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
        guard let regex = mentionRegex else { return nil }
        
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        
        guard let match = matches.last else { return nil }
        
        let fullRange = match.range(at: 0)
        let captureRange = match.range(at: 1)
        let prefix = nsText.substring(with: captureRange).lowercased()
        
        let suggestions = peers
            .filter { $0.lowercased().hasPrefix(prefix) }
            .sorted()
            .prefix(5)
            .map { "@\($0)" }
        
        return suggestions.isEmpty ? nil : (Array(suggestions), fullRange)
    }
    
    private func getCommandSuggestions(_ text: String) -> ([String], NSRange)? {
        guard let regex = commandRegex else { return nil }
        
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        
        guard let match = matches.last else { return nil }
        
        let fullRange = match.range(at: 0)
        let captureRange = match.range(at: 1)
        let prefix = nsText.substring(with: captureRange).lowercased()
        
        let suggestions = commands
            .filter { $0.hasPrefix("/\(prefix)") }
            .sorted()
            .prefix(5)
        
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

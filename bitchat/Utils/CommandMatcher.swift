//
// CommandMatcher.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// A utility for finding the closest matching command from a predefined set.
///
/// CommandMatcher uses a three-step matching algorithm:
/// 1. Exact prefix matching (e.g., "/bl" matches "/block")
/// 2. Substring matching (e.g., "lock" matches "/block")
/// 3. Edit distance matching with configurable threshold
///
/// - Note: Command matching is case-sensitive. Incorrect casing returns nil.
///
/// Example Usage:
/// ```swift
/// let matcher = CommandMatcher(commands: ["/join", "/msg", "/block"])
/// matcher.findClosestCommand(to: "/jo")    // Returns "/join"
/// matcher.findClosestCommand(to: "/msgg")   // Returns "/msg" (typo correction)
/// matcher.findClosestCommand(to: "/MSG")    // Returns nil (case mismatch)
/// ```
struct CommandMatcher {
    private let commandSet: Set<String>
    private let suggestionThreshold: Int

    // Lazy computed property to avoid storing duplicate data
    private var sortedCommands: [String] {
        commandSet.sorted()
    }

    /// Initializes a new CommandMatcher
    /// - Parameters:
    ///   - commands: Set of valid commands. Should include the "/" prefix.
    ///   - suggestionThreshold: Maximum edit distance for suggestions. Default is 2.
    ///   Higher values allow more distant matches.
      init(commands: Set<String>, suggestionThreshold: Int = 2) {
          self.commandSet = commands
          self.suggestionThreshold = suggestionThreshold
      }

    // MARK: - Default Commands
    static let defaultCommands: Set<String> = [
        "/msg", "/join", "/hug", "/block", "/channels", "/clear", "/j", "/slap", "/unblock", "/w", "/m"
    ]

    /// Finds the closest matching command for the given input.
    ///
    /// - Parameter input: The user's input string to match against commands
    /// - Returns: The closest matching command, or nil if no suitable match found
    ///
    /// - Matching Priority:
    ///   1. Exact match returns immediately
    ///   2. Prefix matches (e.g., "/bl" → "/block")
    ///   3. Substring matches for inputs > 1 character
    ///   4. Edit distance matches within threshold
    ///
    /// - Special Cases:
    ///   - Empty string or "/" alone returns nil
    ///   - Non-command strings (not starting with "/") return nil
    ///   - Case mismatches return nil (e.g., "/JOIN" won't match "/join")
    func findClosestCommand(to input: String) -> String? {
        // Empty string or just "/"
        guard !input.isEmpty && input != "/" else { return nil }

        // Must be a command (start with "/")
        guard input.hasPrefix("/") else { return nil }

        // Exact match
        if commandSet.contains(input) {
            return input
        }

        /// Case Sensitivity Check:
        /// If the lowercase version exists but exact case doesn't match,
        /// return nil to avoid suggesting commands with wrong casing.
        /// Example: "/Join" won't suggest "/join"
        if commandSet.contains(input.lowercased()) && !commandSet.contains(input) {
              return nil
          }

        let commands = sortedCommands

        // Step 1: Try prefix matches first
        // Prefix matching: Commands starting with the input get highest priority
        // This enables intuitive command completion behavior
        let prefixMatches = commands.filter { $0.hasPrefix(input) }
        if let firstMatch = prefixMatches.first {
            return firstMatch
        }

        // Step 2: Try substring matches (only if input has more than 1 character)
        if input.count > 1 {
            let substringMatches = commands.filter { $0.contains(input) }
            if let firstMatch = substringMatches.first {
                return firstMatch
            }
        }

        // Step 3: Fall back to edit distance
        // Edit distance matching: Uses Levenshtein distance to find similar commands
        // within the configured threshold. Useful for typo correction.
        let matches = commands
            .compactMap { command -> (command: String, distance: Int, lengthDiff: Int)? in
                // Skip if length difference is too large
                let lengthDiff = abs(input.count - command.count)
                if lengthDiff > suggestionThreshold + 2 {
                    return nil
                }

                guard let distance = input.levenshteinDistance(to: command, maxDistance: suggestionThreshold) else {
                    return nil
                }
                return (command, distance, lengthDiff)
            }

        // Find the best match by preferring:
        // 1. Shorter distance
        // 2. Smaller length difference (closer in length)
        // 3. Alphabetically first (already sorted)
        return matches
            .min { lhs, rhs in
                if lhs.distance != rhs.distance {
                    return lhs.distance < rhs.distance
                }
                if lhs.lengthDiff != rhs.lengthDiff {
                    return lhs.lengthDiff < rhs.lengthDiff
                }
                return lhs.command < rhs.command
            }?
            .command
    }
}

extension String {
    /// Calculates the Levenshtein (edit) distance between two strings.
    ///
    /// - Parameters:
    ///   - other: The string to compare against
    ///   - maxDistance: Maximum distance to calculate. Early termination occurs
    ///                  if distance exceeds this value. Improves performance.
    /// - Returns: The edit distance, or nil if it exceeds maxDistance
    ///
    /// - Complexity: O(n*m) where n and m are string lengths, but optimized
    ///               to O(m) space complexity using only two rows.
    func levenshteinDistance(to other: String, maxDistance: Int? = nil) -> Int? {
        let sourceChars = Array(self)
        let targetChars = Array(other)
        let sourceCount = sourceChars.count
        let targetCount = targetChars.count

        // Handle empty strings
        if sourceCount == 0 { return targetCount }
        if targetCount == 0 { return sourceCount }

        // Early termination check
        if let maxDist = maxDistance {
            let lengthDiff = abs(sourceCount - targetCount)
            if lengthDiff > maxDist { return nil }
        }

        // Use only two rows for space optimization
        var previousRow = Array(0...targetCount)
        var currentRow = Array(repeating: 0, count: targetCount + 1)

        for i in 1...sourceCount {
            currentRow[0] = i
            var rowMin = i

            for j in 1...targetCount {
                let cost = sourceChars[i - 1] == targetChars[j - 1] ? 0 : 1

                currentRow[j] = Swift.min(
                    previousRow[j] + 1,        // deletion
                    currentRow[j - 1] + 1,      // insertion
                    previousRow[j - 1] + cost   // substitution
                )

                rowMin = Swift.min(rowMin, currentRow[j])
            }

            // Early termination
            if let maxDist = maxDistance, rowMin > maxDist {
                return nil
            }

            swap(&previousRow, &currentRow)
        }

        let finalDistance = previousRow[targetCount]

        if let maxDist = maxDistance, finalDistance > maxDist {
            return nil
        }

        return finalDistance
    }
}

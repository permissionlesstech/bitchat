//
// CommandMatcher.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

struct CommandMatcher {
    private let commandSet: Set<String>
    private let commands: [String]
    private let suggestionThreshold: Int

    init(commands: Set<String>, suggestionThreshold: Int = 2) {
        self.commandSet = commands
        // Sort commands for consistent ordering
        self.commands = commands.sorted()
        self.suggestionThreshold = suggestionThreshold
    }

    // MARK: - Default Commands
    static let defaultCommands: Set<String> = [
        "/msg", "/join", "/hug", "/block", "/channels", "/clear", "/j", "/slap", "/unblock", "/w", "/m"
    ]

    func findClosestCommand(to input: String) -> String? {
        // Empty string check
        guard !input.isEmpty || input.count > 0 || input != "" else { return nil }

        // Check if it is command
        guard input.contains("/") else { return nil }

        // If input is just "/", return nil
        if input == "/" {
            return nil
        }

        // Exact match
        if commandSet.contains(input) {
            return input
        }

        // If a lowercased version of the input is a command, but the input itself isn't,
        // it's a case mismatch. We should not offer a suggestion.
        if commandSet.contains(input.lowercased()) {
            return nil
        }

        // Step 1: Try prefix matches first
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
    /// Calculates the Levenshtein distance with early termination
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

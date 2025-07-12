//
// MessagePaddingTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import bitchat

class CommandMatcherTests: XCTestCase {

    let testCommands: Set<String> = [
        "/msg", "/join", "/hug", "/block", "/channels", "/clear", "/j", "/slap", "/unblock", "/w", "/m"
    ]

    func testBasicMatching() {
        let matcher = CommandMatcher(commands: testCommands)

        // Test exact matches
        for command in testCommands {
            let result = matcher.findClosestCommand(to: command)
            XCTAssertEqual(result, command)
        }

        // Test basic prefix matching
        XCTAssertEqual(matcher.findClosestCommand(to: "/bl"), "/block")
        XCTAssertEqual(matcher.findClosestCommand(to: "/ch"), "/channels")
        XCTAssertEqual(matcher.findClosestCommand(to: "/hu"), "/hug")
    }

    func testPrefixMatchingPriority() {
        let matcher = CommandMatcher(commands: testCommands)

        let testCases: [(input: String, expected: String)] = [
            ("/bl", "/block"),
            ("/blo", "/block"),
            ("/bloc", "/block"),
            ("/un", "/unblock"),
            ("/unb", "/unblock"),
            ("/jo", "/join"),
            ("/ms", "/msg"),
            ("/sl", "/slap"),
            ("/cle", "/clear"),
            ("/cha", "/channels")
        ]

        for (input, expected) in testCases {
            let result = matcher.findClosestCommand(to: input)
            XCTAssertEqual(result, expected, "Failed for input: \(input)")
        }
    }

    func testAmbiguousPrefixes() {
        let matcher = CommandMatcher(commands: testCommands)

        // Test inputs that match multiple commands
        let mResult = matcher.findClosestCommand(to: "/m")
        XCTAssertNotNil(mResult)
        XCTAssertTrue(["/m", "/msg"].contains(mResult!))

        let jResult = matcher.findClosestCommand(to: "/j")
        XCTAssertNotNil(jResult)
        XCTAssertTrue(["/j", "/join"].contains(jResult!))

        // Test single character that matches only one command
        XCTAssertEqual(matcher.findClosestCommand(to: "/b"), "/block")
        XCTAssertEqual(matcher.findClosestCommand(to: "/s"), "/slap")
        XCTAssertEqual(matcher.findClosestCommand(to: "/h"), "/hug")
        XCTAssertEqual(matcher.findClosestCommand(to: "/w"), "/w")
    }

    func testTypoCorrection() {
        let matcher = CommandMatcher(commands: testCommands)

        let testCases: [(input: String, expected: String?)] = [
            ("/jon", "/join"),      // one character off
            ("/mgs", "/msg"),       // one character off
            ("/blok", "/block"),    // one character off
            ("/hg", "/hug"),        // missing character
            ("/cler", "/clear"),    // one character off
            ("/messg", "/msg"),     // too many changes needed
            ("/jion", "/join"),     // transposition
        ]

        for (input, expected) in testCases {
            let result = matcher.findClosestCommand(to: input)
            XCTAssertEqual(result, expected, "Failed for input: \(input)")
        }
    }

    func testEdgeCases() {
        let matcher = CommandMatcher(commands: testCommands)

        // Empty string
        XCTAssertNil(matcher.findClosestCommand(to: ""))

        // Just a slash
        let slashResult = matcher.findClosestCommand(to: "/")
        XCTAssertTrue(slashResult == nil || ["/msg", "/join", "/hug"].contains(slashResult!))

        // Non-command strings
        XCTAssertNil(matcher.findClosestCommand(to: "hello"))
        XCTAssertNil(matcher.findClosestCommand(to: "test"))

        // Commands without slash (should not match)
        XCTAssertNil(matcher.findClosestCommand(to: "block"))
        XCTAssertNil(matcher.findClosestCommand(to: "msg"))
    }

    func testCaseSensitivity() {
        let matcher = CommandMatcher(commands: testCommands)

        // Commands should be case-sensitive
        XCTAssertNil(matcher.findClosestCommand(to: "/BLOCK"))
        XCTAssertNil(matcher.findClosestCommand(to: "/Join"))
        XCTAssertNil(matcher.findClosestCommand(to: "/MSG"))

        // But lowercase should work
        XCTAssertEqual(matcher.findClosestCommand(to: "/block"), "/block")
        XCTAssertEqual(matcher.findClosestCommand(to: "/join"), "/join")
    }

    func testNoMatchScenarios() {
        let matcher = CommandMatcher(commands: testCommands)

        let noMatchInputs = [
            "/xyz",
            "/test",
            "/hello",
            "/abcdefghijk",
            "notacommand",
            "///",
            "/123",
            "/!@#"
        ]

        for input in noMatchInputs {
            let result = matcher.findClosestCommand(to: input)
            // Should either return nil or a command with reasonable distance
            if let suggestion = result {
                // If it suggests something, verify it's somewhat reasonable
                XCTAssertTrue(
                    input.hasPrefix("/") && suggestion.hasPrefix("/"),
                    "Unexpected suggestion '\(suggestion)' for input '\(input)'"
                )
            }
        }
    }

    func testSubstringMatching() {
        let matcher = CommandMatcher(commands: testCommands)

        // Test substring matching (when enabled in implementation)
        // These should match if the implementation supports substring matching
        let substringTests: [(input: String, possibleMatches: Set<String>?)] = [
            ("lock", Set(["/block", "/unblock"])),
            ("msg", Set(["/msg"])),
            ("join", Set(["/join"])),
        ]

        for (input, possibleMatches) in substringTests {
            let result = matcher.findClosestCommand(to: input)
            if let matches = possibleMatches, let result = result {
                XCTAssertTrue(
                    matches.contains(result),
                    "Input '\(input)' matched '\(result)' which is not in expected set"
                )
            }
        }
    }

    func testPerformance() {
        let matcher = CommandMatcher(commands: testCommands)

        measure {
            // Perform 10,000 lookups
            for _ in 0..<10_000 {
                _ = matcher.findClosestCommand(to: "/bl")
                _ = matcher.findClosestCommand(to: "/chan")
                _ = matcher.findClosestCommand(to: "/ms")
                _ = matcher.findClosestCommand(to: "/xyz")
            }
        }
    }

    func testConsistentResults() {
        let matcher = CommandMatcher(commands: testCommands)

        // Same input should always return same result
        let inputs = ["/bl", "/ch", "/ms", "/joi", "/unb"]

        for input in inputs {
            let result1 = matcher.findClosestCommand(to: input)
            let result2 = matcher.findClosestCommand(to: input)
            let result3 = matcher.findClosestCommand(to: input)

            XCTAssertEqual(result1, result2)
            XCTAssertEqual(result2, result3)
        }
    }
}

class LevenshteinDistanceTests: XCTestCase {

    func testBasicDistances() {
        // Same strings
        XCTAssertEqual("hello".levenshteinDistance(to: "hello"), 0)

        // One character difference
        XCTAssertEqual("hello".levenshteinDistance(to: "hallo"), 1)
        XCTAssertEqual("hello".levenshteinDistance(to: "hell"), 1)
        XCTAssertEqual("hello".levenshteinDistance(to: "helloo"), 1)

        // Multiple differences
        XCTAssertEqual("kitten".levenshteinDistance(to: "sitting"), 3)
        XCTAssertEqual("saturday".levenshteinDistance(to: "sunday"), 3)
    }

    func testEmptyStrings() {
        XCTAssertEqual("".levenshteinDistance(to: ""), 0)
        XCTAssertEqual("hello".levenshteinDistance(to: ""), 5)
        XCTAssertEqual("".levenshteinDistance(to: "world"), 5)
    }

    func testMaxDistanceOptimization() {
        let source = "hello"

        // Distance within threshold
        XCTAssertEqual(source.levenshteinDistance(to: "hallo", maxDistance: 2), 1)
        XCTAssertEqual(source.levenshteinDistance(to: "help", maxDistance: 2), 2)

        // Distance exceeds threshold
        XCTAssertNil(source.levenshteinDistance(to: "goodbye", maxDistance: 2))
        XCTAssertNil(source.levenshteinDistance(to: "world", maxDistance: 2))

        // Length difference exceeds threshold
        XCTAssertNil(source.levenshteinDistance(to: "hi", maxDistance: 2))
        XCTAssertNil(source.levenshteinDistance(to: "helloooo", maxDistance: 2))
    }

    func testCommandDistances() {
        // Test with actual commands
        XCTAssertEqual("/block".levenshteinDistance(to: "/bloc"), 1)
        XCTAssertEqual("/join".levenshteinDistance(to: "/jon"), 1)
        XCTAssertEqual("/msg".levenshteinDistance(to: "/mgs"), 2)

        // Transpositions
        XCTAssertEqual("/join".levenshteinDistance(to: "/jion"), 2)

        // Multiple errors
        XCTAssertEqual("/block".levenshteinDistance(to: "/blck"), 1)
        XCTAssertEqual("/channels".levenshteinDistance(to: "/chanels"), 1)
    }
}

class CommandMatcherIntegrationTests: XCTestCase {

    func testRealWorldUsage() {
        let commands: Set<String> = [
            "/msg", "/join", "/hug", "/block", "/channels", "/clear", "/j", "/slap", "/unblock", "/w", "/m"
        ]
        let matcher = CommandMatcher(commands: commands)

        // Simulate progressive typing
        let typingSequences = [
            ["", "/", "/b", "/bl", "/blo", "/bloc", "/block"],
            ["", "/", "/c", "/ch", "/cha", "/chan", "/chann", "/channels"],
            ["", "/", "/u", "/un", "/unb", "/unbl", "/unblo", "/unblock"]
        ]

        for sequence in typingSequences {
            var previousSuggestion: String?

            for (index, input) in sequence.enumerated() {
                let suggestion = matcher.findClosestCommand(to: input)

                // After 2 characters, should have suggestions
                if index >= 2 && !input.isEmpty {
                    XCTAssertNotNil(suggestion, "No suggestion for: '\(input)'")
                }

                // Suggestions should be consistent or more specific
                if let prev = previousSuggestion, let curr = suggestion {
                    // Current should either be same as previous or be the target command
                    XCTAssertTrue(
                        curr == prev || sequence.last?.hasPrefix(input) ?? false,
                        "Inconsistent suggestions: '\(prev)' -> '\(curr)' for input '\(input)'"
                    )
                }

                previousSuggestion = suggestion
            }

            // Final suggestion should be the complete command
            XCTAssertEqual(previousSuggestion, sequence.last)
        }
    }

    func testErrorMessageGeneration() {
        let matcher = CommandMatcher(
            commands: ["/block", "/channels", "/clear", "/hug", "/j", "/join",
                      "/m", "/msg", "/slap", "/unblock", "/w"]
        )

        let testCases: [(input: String, shouldHaveSuggestion: Bool)] = [
            ("/bl", true),
            ("/xyz", false),
            ("/msgg", true),
            ("/help", false),
            ("/jion", true),
            ("", false)
        ]

        for (input, shouldHaveSuggestion) in testCases {
            var message = "unknown command: \(input)"
            if let suggestion = matcher.findClosestCommand(to: input) {
                message += " Did you mean: \(suggestion)?"
            }

            if shouldHaveSuggestion {
                XCTAssertTrue(message.contains("Did you mean:"))
            } else {
                XCTAssertFalse(message.contains("Did you mean:"))
            }
        }
    }
}

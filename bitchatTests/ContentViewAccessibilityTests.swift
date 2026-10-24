//
// ContentViewAccessibilityTests.swift
// bitchatTests
//
// The split layout's two panes are accessibility containers, so VoiceOver
// reads one conversation at a time rather than across the hinge row by row
// (both bars, then both timelines, then both composers). SwiftUI builds
// its accessibility tree only for an assistive technology: a hosting view
// in a test exposes no elements at all, containers or not. So this reads
// ContentView's source, as MessageListChannelPolicyTests does for the
// list's selection reads.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(iOS)
import Foundation
import Testing

struct ContentViewAccessibilityTests {
    private static func contentViewLines() throws -> [String] {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // bitchatTests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("bitchat/Views/ContentView.swift")
        return try String(contentsOf: source, encoding: .utf8).components(separatedBy: .newlines)
    }

    /// The modifiers chained onto the pane built on the line that starts
    /// with `pane`: the lines after it, up to the next blank or
    /// non-modifier line.
    private static func modifiers(of pane: String, in lines: [String]) -> [String]? {
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(pane)
        }) else { return nil }
        var chain: [String] = []
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            guard trimmed.hasPrefix(".") else { break }
            chain.append(trimmed)
        }
        return chain
    }

    /// Both panes, unconditionally: the leading pane keeps one identity
    /// across folds (its bar hosts the app-wide presentations), so no `if`
    /// may wrap the modifier; as the single column it is the only
    /// container, and VoiceOver's order there doesn't change.
    @Test
    func bothPanesAreAccessibilityContainers() throws {
        let lines = try Self.contentViewLines()
        for pane in ["appChromePane(split: split, corners: corners)", "trailingPane(width: split.trailingWidth"] {
            let chain = try #require(Self.modifiers(of: pane, in: lines), "\(pane) not found")
            #expect(chain.contains(".accessibilityElement(children: .contain)"), "\(pane): \(chain)")
        }
    }
}
#endif

import Foundation
import XCTest

/// Keeps `arti_stop()` off the main actor.
///
/// The Rust side of `arti_stop()` sleeps for ~200 ms while it holds Arti's
/// state lock, so the old runtime can wind down before the next `arti_start`.
/// `TorManager` is `@MainActor`, so calling it directly from one of its
/// methods stalls the UI for that long. That is what every iOS return to the
/// foreground did while `restartArti()` called it inline: one ~190 ms
/// main-thread stall per resume in the simulator.
///
/// The FFI declaration is private to TorManager.swift, so that file is the
/// only place a call can appear. This scans it and requires every call to sit
/// inside a `Task.detached` closure.
final class TorManagerTests: XCTestCase {
    private static let torManagerSource = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Services
        .deletingLastPathComponent()  // bitchatTests
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("localPackages/Arti/Sources/TorManager.swift")

    func test_artiStop_isOnlyCalledInsideTaskDetached() throws {
        let source = try String(contentsOf: Self.torManagerSource, encoding: .utf8)
        let calls = Self.artiStopCalls(in: source)

        XCTAssertFalse(
            calls.isEmpty,
            "Found no arti_stop() call in TorManager.swift. Fix the path, or move this guard along with the call."
        )
        let blocking = calls.filter { !$0.insideTaskDetached }.map { "TorManager.swift:\($0.line)" }
        XCTAssertEqual(
            blocking,
            [],
            "arti_stop() blocks for ~200 ms. Call it inside Task.detached (await .value when the caller has to wait for the stop), never directly on the main actor."
        )
    }

    // MARK: - Scanner

    private struct ArtiStopCall {
        let line: Int
        let insideTaskDetached: Bool
    }

    /// Finds every use of `arti_stop` other than its declaration, and whether
    /// one of the braces enclosing it opened a `Task.detached` closure.
    /// Comments and string literals are skipped, so neither the name nor a
    /// brace inside them counts.
    private static func artiStopCalls(in source: String) -> [ArtiStopCall] {
        let text = Array(source)
        var calls: [ArtiStopCall] = []
        var openBraces: [Bool] = []  // one per unclosed `{`: did it open a Task.detached closure?
        var nextBraceOpensTaskDetached = false
        var line = 1
        var index = 0

        func hasPrefix(_ token: String) -> Bool {
            text[index...].starts(with: token)
        }
        func isIdentifierCharacter(at position: Int) -> Bool {
            guard text.indices.contains(position) else { return false }
            let character = text[position]
            return character.isLetter || character.isNumber || character == "_"
        }
        func followsFuncKeyword() -> Bool {
            var position = index - 1
            while position >= 0, text[position].isWhitespace { position -= 1 }
            return position >= 3 && String(text[(position - 3)...position]) == "func"
        }
        /// Moves past the next `terminator`, counting the lines it crosses.
        func skip(past terminator: String, honoringEscapes: Bool) {
            while index < text.count, !hasPrefix(terminator) {
                if honoringEscapes, text[index] == "\\" { index += 1 }
                if index < text.count, text[index].isNewline { line += 1 }
                index += 1
            }
            index += terminator.count
        }

        while index < text.count {
            if hasPrefix("//") {
                while index < text.count, !text[index].isNewline { index += 1 }
            } else if hasPrefix("/*") {
                index += 2
                skip(past: "*/", honoringEscapes: false)
            } else if hasPrefix("\"\"\"") {
                index += 3
                skip(past: "\"\"\"", honoringEscapes: true)
            } else if hasPrefix("\"") {
                index += 1
                skip(past: "\"", honoringEscapes: true)
            } else {
                let character = text[index]
                if character.isNewline {
                    line += 1
                } else if character == "{" {
                    openBraces.append(nextBraceOpensTaskDetached)
                    nextBraceOpensTaskDetached = false
                } else if character == "}" {
                    _ = openBraces.popLast()
                } else if hasPrefix("Task.detached"), !isIdentifierCharacter(at: index - 1) {
                    nextBraceOpensTaskDetached = true
                } else if hasPrefix("arti_stop"),
                          !isIdentifierCharacter(at: index - 1),
                          !isIdentifierCharacter(at: index + "arti_stop".count),
                          !followsFuncKeyword() {
                    calls.append(ArtiStopCall(line: line, insideTaskDetached: openBraces.contains(true)))
                }
                index += 1
            }
        }
        return calls
    }
}

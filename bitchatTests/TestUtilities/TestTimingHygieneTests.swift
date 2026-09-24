import Foundation
import Testing

/// Guards the test suite against the flake class that produced four separate
/// red builds in July 2026: **treating a wait deadline as a latency budget.**
///
/// A CI runner executes many suites at once, so work behind `@MainActor`,
/// `Task.detached(priority: .utility)`, or `DispatchQueue.asyncAfter` can be
/// starved for seconds. One observed run took 3.75 s for a 1 s operation.
/// Deadlines sized to how long the operation "should" take turn that starvation
/// into a red build that reads like a product bug, and the debugging cost lands
/// on whoever opened an unrelated PR.
///
/// Two rules, both enforced below:
///
/// 1. A wait helper's default deadline must be at least
///    `TestConstants.minimumSettleTimeout`. Waits return as soon as their
///    condition holds, so a generous deadline is free in the passing case.
/// 2. No test asserts an *upper bound* on elapsed wall-clock time. Such an
///    assertion cannot distinguish the behaviour under test from a slow
///    machine, so it can only be flaky. Assert the property somewhere it is
///    computable — with an injected clock, on the pure logic — instead.
///
/// Both rules can be waived per line with `\(Self.waiver)` plus a reason, for
/// the rare case where the timing itself is genuinely the thing under test.
struct TestTimingHygieneTests {
    /// Opt-out marker. Reviewers should expect a reason next to it.
    static let waiver = "test-timing-ok:"

    private static let testsRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // TestUtilities
        .deletingLastPathComponent()  // bitchatTests

    private struct Line {
        let file: String
        let number: Int
        let text: String
        /// True when the waiver appears on this line or in the comment block
        /// immediately above it, so a reason can be written at readable length
        /// rather than crammed onto the end of the code line.
        let waived: Bool
    }

    private static func swiftLines() throws -> [Line] {
        let enumerator = FileManager.default.enumerator(
            at: testsRoot,
            includingPropertiesForKeys: nil
        )
        var out: [Line] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            // This file necessarily contains the patterns it bans.
            guard url.lastPathComponent != "TestTimingHygieneTests.swift" else { continue }
            let name = url.lastPathComponent
            let texts = try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: .newlines)
            for (index, text) in texts.enumerated() {
                // Scan back over an unbroken run of comment lines.
                var waived = text.contains(waiver)
                var back = index - 1
                while !waived, back >= 0 {
                    let above = texts[back].trimmingCharacters(in: .whitespaces)
                    guard above.hasPrefix("//") else { break }
                    waived = above.contains(waiver)
                    back -= 1
                }
                out.append(Line(file: name, number: index + 1, text: text, waived: waived))
            }
        }
        return out
    }

    private static func isWaived(_ line: Line) -> Bool {
        line.waived
    }

    /// Rule 1: no wait helper may default to a deadline below the floor.
    @Test func waitHelpersDoNotDefaultToShortDeadlines() throws {
        let lines = try Self.swiftLines()
        #expect(!lines.isEmpty, "hygiene scan found no test sources — check the path")

        // Two shapes, both of which have flaked here:
        //   a declaration default — `timeout: TimeInterval = 2.5`
        //   a wait call site      — `wait(for:…, timeout: 1.0)`, `waitUntil(timeout: 5.0)`
        //
        // Deliberately NOT matched: a bare `timeout:` label on something that is
        // not a wait, such as the injected production handshake timeouts in the
        // Noise tests. Those are the behaviour under test, and a short value is
        // correct there.
        let patterns = [
            #"(?:timeout|deadline)\s*:\s*TimeInterval\s*=\s*([0-9]+(?:\.[0-9]+)?)"#,
            #"(?:wait|waitUntil|waitFor|fulfillment)\s*\([^)]*\btimeout:\s*([0-9]+(?:\.[0-9]+)?)"#
        ].map { try? NSRegularExpression(pattern: $0) }.compactMap { $0 }
        #expect(patterns.count == 2, "hygiene regexes failed to compile")

        // Named constants hide the same mistake behind a symbol, and did: the
        // fifth flake of the session was `timeout: TestConstants.shortTimeout`
        // (1 s) on a positive wait, which a literals-only scan cannot see.
        // `shortTimeout` itself is deleted (Periphery flagged it dead once its
        // last wait site converted); the ban stays so it cannot come back.
        // `negativeWaitWindow` is deliberately absent — short is correct there.
        let bannedConstants = ["shortTimeout", "defaultTimeout"]

        var offenders: [String] = []
        for line in lines where !Self.isWaived(line) {
            let range = NSRange(line.text.startIndex..., in: line.text)
            var flagged = false
            for pattern in patterns {
                guard let match = pattern.firstMatch(in: line.text, range: range),
                      let valueRange = Range(match.range(at: 1), in: line.text),
                      let value = TimeInterval(line.text[valueRange]),
                      value < TestConstants.minimumSettleTimeout else { continue }
                offenders.append("\(line.file):\(line.number) — \(value)s: \(line.text.trimmingCharacters(in: .whitespaces))")
                flagged = true
                break
            }
            guard !flagged else { continue }
            for name in bannedConstants
            where line.text.contains("timeout: TestConstants.\(name)") {
                offenders.append("\(line.file):\(line.number) — TestConstants.\(name): \(line.text.trimmingCharacters(in: .whitespaces))")
                break
            }
        }

        #expect(
            offenders.isEmpty,
            """
            Wait deadlines below \(TestConstants.minimumSettleTimeout)s are latency \
            assumptions and will flake on a loaded runner. Use \
            TestConstants.settleTimeout, or add "\(Self.waiver) <reason>" if the \
            timing really is what the test asserts.

            \(offenders.joined(separator: "\n"))
            """
        )
    }

    /// Rule 2: no test bounds elapsed wall-clock time from above.
    ///
    /// This is the assertion that started it all — `XCTAssertLessThan(
    /// Date().timeIntervalSince(start), 1.4)` proving a debounce deadline was
    /// not restarted. It cannot separate "behaved correctly" from "runner was
    /// busy", so it only ever fails for the wrong reason.
    @Test func testsDoNotAssertUpperBoundsOnElapsedTime() throws {
        let lines = try Self.swiftLines()

        let elapsedAssertion = try NSRegularExpression(
            pattern: #"(?:XCTAssertLessThan|XCTAssertLessThanOrEqual)\s*\(\s*(?:Date\(\)\.timeIntervalSince|[A-Za-z_][A-Za-z0-9_]*\.timeIntervalSince|ContinuousClock)"#
        )

        var offenders: [String] = []
        for line in lines where !Self.isWaived(line) {
            let range = NSRange(line.text.startIndex..., in: line.text)
            guard elapsedAssertion.firstMatch(in: line.text, range: range) != nil else { continue }
            offenders.append("\(line.file):\(line.number) — \(line.text.trimmingCharacters(in: .whitespaces))")
        }

        #expect(
            offenders.isEmpty,
            """
            An upper bound on elapsed wall-clock time cannot distinguish the \
            behaviour under test from a slow machine. Assert the property where \
            it is computable — inject a clock, or test the pure logic — or add \
            "\(Self.waiver) <reason>".

            \(offenders.joined(separator: "\n"))
            """
        )
    }

    /// The floor must stay meaningfully above the operations being waited on,
    /// and the default must satisfy the rule this file enforces.
    @Test func settleTimeoutsAreSelfConsistent() {
        #expect(TestConstants.settleTimeout >= TestConstants.minimumSettleTimeout)
        #expect(TestConstants.minimumSettleTimeout > TestConstants.defaultTimeout)
    }
}

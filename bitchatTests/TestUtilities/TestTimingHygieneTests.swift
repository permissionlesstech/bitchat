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
/// Three rules, all enforced below:
///
/// 1. A wait helper's default deadline must be at least
///    `TestConstants.minimumSettleTimeout`. Waits return as soon as their
///    condition holds, so a generous deadline is free in the passing case.
/// 2. No test asserts an *upper bound* on elapsed wall-clock time. Such an
///    assertion cannot distinguish the behaviour under test from a slow
///    machine, so it can only be flaky. Assert the property somewhere it is
///    computable — with an injected clock, on the pure logic — instead.
/// 3. A Noise handshake timeout is never sized to the work. The timer arms
///    on the first handshake message and a stalled runner lets it fire before
///    the next, so it is made unlosable and expiry is fired by hook.
///
/// All rules can be waived per line with `\(Self.waiver)` plus a reason, for
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
        // Noise tests. A floor is the wrong rule for those; rule 3 covers them.
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

    /// Rule 3: a Noise handshake timeout is never sized to the work.
    ///
    /// Rule 1 deliberately leaves injected production timeouts alone, and
    /// that was the blind spot: the ordinary initiator and responder
    /// timeouts arm on the first handshake message, and tests step a
    /// handshake as consecutive synchronous calls. A runner that stalls
    /// between two of them lets the timer tear the half-open session down,
    /// and message 3 is then answered as a fresh initiation. It kept
    /// recurring while the injected value was raised from 20 ms to 1 s
    /// (#1483, #1491), and then outran the 20 s production default (#1737).
    ///
    /// Services are built with `TestConstants.unlosableInterval` instead, and
    /// a test whose subject is expiry fires it through a `_test_fire…Timeout`
    /// hook. Two checks hold that in place:
    ///
    /// - In `NoiseEncryptionServiceTests`, which drives more handshakes than
    ///   any other suite, a service may only come from the factory. The
    ///   factory takes no timing parameters, so there a real timer needs a
    ///   waived construction.
    /// - In every test file, a numeric handshake timeout written next to its
    ///   label is flagged. A value passed through a variable, or wrapped onto
    ///   the next line, is not seen; outside the file above this check is a
    ///   tripwire and not a guarantee.
    @Test func noiseHandshakeTimeoutsAreNotSizedToTheWork() throws {
        let lines = try Self.swiftLines()

        let factoryOnlyFile = "NoiseEncryptionServiceTests.swift"
        #expect(
            lines.contains { $0.file == factoryOnlyFile },
            "hygiene scan did not find \(factoryOnlyFile) — was it renamed?"
        )
        let directConstruction = try NSRegularExpression(
            pattern: #"\bNoiseEncryptionService\s*\("#
        )
        let literalTimeout = try NSRegularExpression(
            pattern: #"[Hh]andshakeTimeout\s*:\s*[0-9]"#
        )

        var offenders: [String] = []
        for line in lines where !Self.isWaived(line) {
            let range = NSRange(line.text.startIndex..., in: line.text)
            let isOffender =
                literalTimeout.firstMatch(in: line.text, range: range) != nil
                || (line.file == factoryOnlyFile
                    && directConstruction.firstMatch(
                        in: line.text,
                        range: range
                    ) != nil)
            guard isOffender else { continue }
            offenders.append("\(line.file):\(line.number) — \(line.text.trimmingCharacters(in: .whitespaces))")
        }

        #expect(
            offenders.isEmpty,
            """
            A Noise handshake timeout sized to the work will fire mid-handshake \
            on a stalled runner. Build the service with \
            TestConstants.unlosableInterval (in \(factoryOnlyFile), through \
            makeNoiseService) and fire expiry with a _test_fire…Timeout hook, \
            or add "\(Self.waiver) <reason>" if the real deadline is what the \
            test measures.

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

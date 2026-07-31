import Foundation
import Testing

/// Pins the BLE transport's sync-edge order so it stays structural instead
/// of decaying back into per-site discipline:
///
///     main / test threads ──sync──▶ engine ──sync──▶ bleQueue
///                                       └──sync──▶ noise / identity queues
///
/// and never the reverse. `onEngine` is the single place allowed to
/// sync-enter the engine — it carries the debug trap that catches a
/// bleQueue caller before it can pair with `readLinkState` into an ABBA
/// deadlock (the class of the July 9 field freeze). A raw
/// `messageQueue.sync` bypasses that trap, and a `DispatchQueue.main.sync`
/// from transport code completes a cycle with the main actor's sync reads.
///
/// Waive a line with `queue-contract-ok:` plus a reason.
struct BLEQueueContractTests {
    static let waiver = "queue-contract-ok:"

    private static let bleRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Services
        .deletingLastPathComponent()  // bitchatTests
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("bitchat/Services/BLE")

    private struct Line {
        let file: String
        let number: Int
        let text: String
        let waived: Bool
    }

    private static func bleLines() throws -> [Line] {
        let enumerator = FileManager.default.enumerator(
            at: bleRoot,
            includingPropertiesForKeys: nil
        )
        var out: [Line] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let name = url.lastPathComponent
            let texts = try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: .newlines)
            for (index, text) in texts.enumerated() {
                var waived = text.contains(waiver)
                var back = index - 1
                while !waived, back >= 0 {
                    let previous = texts[back].trimmingCharacters(in: .whitespaces)
                    guard previous.hasPrefix("//") else { break }
                    waived = previous.contains(waiver)
                    back -= 1
                }
                out.append(Line(file: name, number: index + 1, text: text, waived: waived))
            }
        }
        return out
    }

    private func offenders(matching pattern: String) throws -> [String] {
        try Self.bleLines()
            .filter { !$0.waived && $0.text.contains(pattern) }
            .map { "\($0.file):\($0.number): \($0.text.trimmingCharacters(in: .whitespaces))" }
    }

    @Test func onlyOnEngineSyncEntersTheEngine() throws {
        let hits = try offenders(matching: "messageQueue.sync")
        #expect(hits.isEmpty, "Raw messageQueue.sync bypasses onEngine's bleQueue trap; route through onEngine (or waive with a reason): \(hits)")
    }

    @Test func transportCodeNeverSyncDispatchesToMain() throws {
        let hits = try offenders(matching: "DispatchQueue.main.sync")
        #expect(hits.isEmpty, "A main.sync from transport code can complete an ABBA cycle with the main actor's sync reads: \(hits)")
    }

    @Test func theCollectionsQueueStaysDeleted() throws {
        let hits = try offenders(matching: "collectionsQueue")
        #expect(hits.isEmpty, "Engine state has exactly one serial domain; do not reintroduce a side queue: \(hits)")
    }

    @Test func deferredEngineWorkGoesThroughTheScheduler() throws {
        let hits = try offenders(matching: "messageQueue.asyncAfter")
        #expect(hits.isEmpty, "Engine delays must use BLEEngineScheduling so tests can drive protocol deadlines with a manual clock: \(hits)")
    }
}

import Foundation
import Testing
@testable import bitchat

struct ReadDMRecordTests {
    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "chat.bitchat.tests.readDMs.\(UUID().uuidString)")!
    }

    @Test
    func recordedIDsSurviveANewInstance() {
        let defaults = scratchDefaults()
        var record = ReadDMRecord(defaults: defaults)
        record.record("a")
        record.record("b")

        let reloaded = ReadDMRecord(defaults: defaults)
        #expect(reloaded.contains("a"))
        #expect(reloaded.contains("b"))
        #expect(!reloaded.contains("c"))
    }

    @Test
    func theCapDropsTheOldestFirst() {
        let defaults = scratchDefaults()
        var record = ReadDMRecord(defaults: defaults, cap: 2)
        record.record("a")
        record.record("b")
        record.record("c")
        #expect(!record.contains("a"))
        #expect(record.contains("b"))
        #expect(record.contains("c"))

        let reloaded = ReadDMRecord(defaults: defaults, cap: 2)
        #expect(!reloaded.contains("a"))
        #expect(reloaded.contains("c"))
    }

    @Test
    func removeAllForgetsEverythingOnDiskToo() {
        let defaults = scratchDefaults()
        var record = ReadDMRecord(defaults: defaults)
        record.record("a")
        record.removeAll()
        #expect(!record.contains("a"))
        #expect(!ReadDMRecord(defaults: defaults).contains("a"))
    }
}

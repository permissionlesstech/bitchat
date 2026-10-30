//
// GroupListTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import bitchat

struct GroupListTests {
    private let alice = Data(repeating: 0xA1, count: 32)
    private let bob = Data(repeating: 0xB0, count: 32)
    private let carol = Data(repeating: 0xC0, count: 32)

    private func itemID(_ seed: UInt8) -> Data {
        Data(repeating: seed, count: GroupList.itemIDLength)
    }

    /// `#require` can't wrap a mutating call, so edits go through this.
    @discardableResult
    private func require(_ delta: GroupListDelta?, sourceLocation: SourceLocation = #_sourceLocation) throws -> GroupListDelta {
        try #require(delta, sourceLocation: sourceLocation)
    }

    // MARK: Local edits

    @Test
    func addCheckAndRemoveShowUpInItems() throws {
        var list = GroupList()
        try require(list.add(text: "water", id: itemID(1), author: alice, nowMs: 1_000))
        try require(list.add(text: "maps", id: itemID(2), author: alice, nowMs: 2_000))
        #expect(list.items.map(\.text) == ["water", "maps"])

        try require(list.setChecked(true, id: itemID(1), author: bob, nowMs: 3_000))
        #expect(list.items.first?.isChecked == true)

        try require(list.remove(id: itemID(2), author: bob, nowMs: 4_000))
        #expect(list.items.map(\.text) == ["water"])
    }

    @Test
    func noOpEditsProduceNoDelta() throws {
        var list = GroupList()
        try require(list.add(text: "water", id: itemID(1), author: alice, nowMs: 1_000))
        let duplicateAdd = list.add(text: "again", id: itemID(1), author: alice, nowMs: 2_000)
        let alreadyUnchecked = list.setChecked(false, id: itemID(1), author: alice, nowMs: 2_000)
        let unknownRow = list.setChecked(true, id: itemID(9), author: alice, nowMs: 2_000)
        #expect(duplicateAdd == nil)
        #expect(alreadyUnchecked == nil)
        #expect(unknownRow == nil)

        try require(list.remove(id: itemID(1), author: alice, nowMs: 3_000))
        let removedTwice = list.remove(id: itemID(1), author: alice, nowMs: 4_000)
        let checkAfterRemoval = list.setChecked(true, id: itemID(1), author: alice, nowMs: 4_000)
        #expect(removedTwice == nil)
        #expect(checkAfterRemoval == nil)
    }

    @Test
    func textIsCleanedUpAndCapped() {
        #expect(GroupList.sanitizedText("  two\nlines  ") == "two lines")
        #expect(GroupList.sanitizedText(" \n ") == nil)
        let long = String(repeating: "é", count: 150) // 300 UTF-8 bytes
        let capped = GroupList.sanitizedText(long)
        #expect(capped?.utf8.count ?? 0 <= GroupList.maxTextBytes)
        #expect(capped?.allSatisfy { $0 == "é" } == true)
    }

    @Test
    func localEditBeatsALaterStampedRemoteEditEvenWithASlowClock() throws {
        var list = GroupList()
        try require(list.add(text: "water", id: itemID(1), author: alice, nowMs: 1_000))
        // Bob's clock is far ahead.
        list.merge([itemID(1): GroupListItemState(checked: .init(stamp: GroupListStamp(timestampMs: 90_000, author: bob), value: true))])
        #expect(list.items.first?.isChecked == true)

        // Our clock still says 2_000, but unchecking must win locally and remotely.
        let delta = try require(list.setChecked(false, id: itemID(1), author: alice, nowMs: 2_000))
        #expect(list.items.first?.isChecked == false)
        #expect(delta[itemID(1)]?.checked?.stamp.timestampMs ?? 0 > 90_000)
    }

    @Test
    func addsAreRefusedOnceTheListIsFull() throws {
        var list = GroupList()
        for index in 0..<GroupList.maxVisibleItems {
            var id = itemID(0)
            id[0] = UInt8(index)
            try require(list.add(text: "item \(index)", id: id, author: alice, nowMs: UInt64(index)))
        }
        let overflow = list.add(text: "one more", id: itemID(0xFF), author: alice, nowMs: 999)
        #expect(overflow == nil)
    }

    // MARK: Merge

    @Test
    func removalIsPermanentEvenAgainstALaterCheck() throws {
        var list = GroupList()
        let add = try require(list.add(text: "water", id: itemID(1), author: alice, nowMs: 1_000))
        let removal = try require(list.remove(id: itemID(1), author: alice, nowMs: 2_000))

        var other = GroupList()
        other.merge(add)
        let lateCheck = try require(other.setChecked(true, id: itemID(1), author: bob, nowMs: 5_000))
        other.merge(removal)
        list.merge(lateCheck)

        #expect(list.items.isEmpty)
        #expect(other.items.isEmpty)
        #expect(list == other)
    }

    @Test
    func checkArrivingBeforeItsAddIsKept() {
        var list = GroupList()
        let id = itemID(1)
        list.merge([id: GroupListItemState(checked: .init(stamp: GroupListStamp(timestampMs: 2_000, author: bob), value: true))])
        #expect(list.items.isEmpty)
        list.merge([id: GroupListItemState(added: .init(stamp: GroupListStamp(timestampMs: 1_000, author: alice), text: "water"))])
        #expect(list.items.map(\.isChecked) == [true])
    }

    @Test
    func concurrentChecksResolveTheSameWayEverywhere() {
        let id = itemID(1)
        let add: GroupListDelta = [id: GroupListItemState(added: .init(stamp: GroupListStamp(timestampMs: 1, author: alice), text: "water"))]
        // Same millisecond, different authors: the author bytes break the tie.
        let bobChecks: GroupListDelta = [id: GroupListItemState(checked: .init(stamp: GroupListStamp(timestampMs: 5, author: bob), value: true))]
        let carolUnchecks: GroupListDelta = [id: GroupListItemState(checked: .init(stamp: GroupListStamp(timestampMs: 5, author: carol), value: false))]

        var first = GroupList()
        [add, bobChecks, carolUnchecks].forEach { first.merge($0) }
        var second = GroupList()
        [carolUnchecks, add, bobChecks].forEach { second.merge($0) }

        #expect(first == second)
        #expect(first.items.first?.isChecked == false) // carol's key sorts after bob's
    }

    @Test
    func mergeIsIdempotentAndReportsChanges() throws {
        var source = GroupList()
        let delta = try require(source.add(text: "water", id: itemID(1), author: alice, nowMs: 1))
        var list = GroupList()
        let first = list.merge(delta)
        let repeated = list.merge(delta)
        let snapshot = list.merge(source.records)
        #expect(first)
        #expect(repeated == false)
        #expect(snapshot == false)
    }

    @Test
    func malformedItemIDsAreIgnored() {
        var list = GroupList()
        let state = GroupListItemState(added: .init(stamp: GroupListStamp(timestampMs: 1, author: alice), text: "x"))
        let changed = list.merge([Data([1, 2, 3]): state])
        #expect(changed == false)
        #expect(list.records.isEmpty)
    }

    @Test
    func everyDeliveryOrderConvergesOnTheSameList() throws {
        // Three members edit apart; each produces a handful of deltas.
        var aliceList = GroupList()
        var bobList = GroupList()
        var deltas: [GroupListDelta] = []
        deltas.append(try require(aliceList.add(text: "water", id: itemID(1), author: alice, nowMs: 10)))
        deltas.append(try require(aliceList.add(text: "maps", id: itemID(2), author: alice, nowMs: 11)))
        bobList.merge(deltas[0])
        deltas.append(try require(bobList.setChecked(true, id: itemID(1), author: bob, nowMs: 12)))
        deltas.append(try require(bobList.add(text: "stove", id: itemID(3), author: bob, nowMs: 13)))
        deltas.append(try require(aliceList.remove(id: itemID(2), author: alice, nowMs: 14)))
        deltas.append(try require(aliceList.setChecked(true, id: itemID(1), author: alice, nowMs: 12)))
        bobList.merge(deltas[4])
        deltas.append(try require(bobList.setChecked(false, id: itemID(1), author: bob, nowMs: 20)))

        var reference = GroupList()
        deltas.forEach { reference.merge($0) }

        var generator = SeededGenerator(seed: 7)
        for _ in 0..<200 {
            var shuffled = GroupList()
            for delta in deltas.shuffled(using: &generator) {
                shuffled.merge(delta)
            }
            #expect(shuffled == reference)
        }
        #expect(reference.items.map(\.text) == ["water", "stove"])
        #expect(reference.items.first?.isChecked == false)
    }

    @Test
    func tombstonesAreTrimmedFirstWhenOverTheRecordCap() {
        var list = GroupList()
        var delta: GroupListDelta = [:]
        for index in 0..<GroupList.maxRecords {
            var id = itemID(0)
            id[0] = UInt8(index & 0xFF)
            id[1] = UInt8(index >> 8)
            delta[id] = GroupListItemState(
                added: .init(stamp: GroupListStamp(timestampMs: UInt64(index), author: alice), text: "row"),
                removed: GroupListStamp(timestampMs: UInt64(1_000 + index), author: alice)
            )
        }
        list.merge(delta)
        #expect(list.records.count == GroupList.maxRecords)

        let liveID = itemID(0xEE)
        list.merge([liveID: GroupListItemState(added: .init(stamp: GroupListStamp(timestampMs: 5, author: bob), text: "keep"))])
        #expect(list.records.count == GroupList.maxRecords)
        #expect(list.items.map(\.text) == ["keep"])
        // The oldest tombstone made room.
        #expect(list.records[itemID(0)] == nil)
    }

    @Test
    func listSurvivesACodableRoundTrip() throws {
        var list = GroupList()
        try require(list.add(text: "water", id: itemID(1), author: alice, nowMs: 1))
        try require(list.setChecked(true, id: itemID(1), author: bob, nowMs: 2))
        let decoded = try JSONDecoder().decode(GroupList.self, from: JSONEncoder().encode(list))
        #expect(decoded == list)
    }
}

/// Deterministic shuffles so a convergence failure reproduces.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

//
// PeopleListOrderingTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
@testable import bitchat

struct PeopleListOrderingTests {

    @Test func firstLayoutUsesProducerOrder() {
        let order = PeopleListOrdering.stableOrder(previous: [], current: ["c", "a", "b"])
        #expect(order == ["c", "a", "b"])
    }

    @Test func shownRowsKeepTheirPlaceWhenTheProducerReorders() {
        // A heartbeat moved "b" to the front of the recency-sorted roster;
        // the open list must not reshuffle under the reader.
        let order = PeopleListOrdering.stableOrder(previous: ["a", "b", "c"], current: ["b", "c", "a"])
        #expect(order == ["a", "b", "c"])
    }

    @Test func newcomersAppendInProducerOrder() {
        let order = PeopleListOrdering.stableOrder(previous: ["a", "b"], current: ["e", "b", "d", "a"])
        #expect(order == ["a", "b", "e", "d"])
    }

    @Test func departuresDropOut() {
        let order = PeopleListOrdering.stableOrder(previous: ["a", "b", "c"], current: ["c", "a"])
        #expect(order == ["a", "c"])
    }

    @Test func duplicateIDsCollapseToTheFirstOccurrence() {
        let order = PeopleListOrdering.stableOrder(previous: ["a", "a"], current: ["b", "a", "b"])
        #expect(order == ["a", "b"])
    }

    @Test func emptyRosterClearsTheOrder() {
        #expect(PeopleListOrdering.stableOrder(previous: ["a", "b"], current: []).isEmpty)
    }
}

//
// BridgeStatusSummaryTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
@testable import bitchat

struct BridgeStatusSummaryTests {
    @Test func offStateDoesNotMentionBridgePeople() {
        let text = BridgeStatusSummary.formatted(enabled: false, cell: "u4pruy", bridgedCount: 3, nearbyOnly: false)
        #expect(text.lowercased().contains("bridge off"))
    }

    @Test func enabledStateIncludesCellAndCount() {
        let text = BridgeStatusSummary.formatted(enabled: true, cell: "u4pruy", bridgedCount: 2, nearbyOnly: true)
        #expect(text.contains("u4pruy"))
        #expect(text.contains("nearby"))
    }
}

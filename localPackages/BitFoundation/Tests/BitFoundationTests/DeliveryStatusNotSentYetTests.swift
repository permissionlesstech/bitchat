//
// DeliveryStatusNotSentYetTests.swift
// bitchatTests
//
// DeliveryStatus is a total state machine: every message carries a concrete
// status from creation. Public messages start .notSentYet, private messages
// keep their historical .sending default, and archives persisted while the
// field was optional decode with the absent field mapped to .notSentYet.
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import BitFoundation

struct DeliveryStatusNotSentYetTests {

    private func makeMessage(isPrivate: Bool, deliveryStatus: DeliveryStatus? = nil) -> BitchatMessage {
        BitchatMessage(
            sender: "alice",
            content: "hello",
            timestamp: Date(timeIntervalSince1970: 1_000),
            isRelay: false,
            isPrivate: isPrivate,
            deliveryStatus: deliveryStatus
        )
    }

    @Test
    func publicMessagesStartNotSentYetAndPrivateStartSending() {
        #expect(makeMessage(isPrivate: false).deliveryStatus == .notSentYet)
        #expect(makeMessage(isPrivate: true).deliveryStatus == .sending)
        // An explicit status always wins over the defaults.
        #expect(makeMessage(isPrivate: false, deliveryStatus: .sent).deliveryStatus == .sent)
    }

    @Test
    func decodingLegacyArchiveWithoutStatusYieldsNotSentYet() throws {
        // Pre-existing archives omitted the key for public messages while the
        // field was optional; absent must map to .notSentYet, not fail.
        let encoded = try JSONEncoder().encode(makeMessage(isPrivate: false))
        var json = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        json.removeValue(forKey: "deliveryStatus")
        let legacyData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(BitchatMessage.self, from: legacyData)
        #expect(decoded.deliveryStatus == .notSentYet)
    }

    @Test
    func decodingRoundTripPreservesConcreteStatus() throws {
        let message = makeMessage(isPrivate: true, deliveryStatus: .delivered(to: "bob", at: Date(timeIntervalSince1970: 2_000)))
        let decoded = try JSONDecoder().decode(BitchatMessage.self, from: JSONEncoder().encode(message))
        #expect(decoded.deliveryStatus == .delivered(to: "bob", at: Date(timeIntervalSince1970: 2_000)))
    }
}

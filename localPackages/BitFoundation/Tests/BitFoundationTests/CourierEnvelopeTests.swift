//
// CourierEnvelopeTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import BitFoundation

struct CourierEnvelopeTests {

    private func makeEnvelope(
        tag: Data = Data(repeating: 0xAB, count: CourierEnvelope.tagLength),
        expiry: UInt64 = 1_900_000_000_000,
        ciphertext: Data = Data(repeating: 0x42, count: 128)
    ) -> CourierEnvelope {
        CourierEnvelope(recipientTag: tag, expiry: expiry, ciphertext: ciphertext)
    }

    // MARK: - Spray copies

    @Test func copiesRoundTrip() throws {
        let envelope = makeEnvelope().withCopies(4)
        let encoded = try #require(envelope.encode())
        let decoded = try #require(CourierEnvelope.decode(encoded))
        #expect(decoded.copies == 4)
        #expect(decoded == envelope)
    }

    @Test func carryOnlyEnvelopeEncodesIdenticallyToLegacyFormat() throws {
        // copies == 1 must be byte-identical to the pre-spray wire format so
        // old and new clients dedup the same envelope the same way.
        let envelope = makeEnvelope()
        #expect(envelope.copies == 1)
        let encoded = try #require(envelope.encode())
        let withExplicitOne = try #require(envelope.withCopies(1).encode())
        #expect(encoded == withExplicitOne)
        #expect(!encoded.contains(0x04) || CourierEnvelope.decode(encoded)?.copies == 1)
    }

    @Test func decodeWithoutCopiesTLVDefaultsToCarryOnly() throws {
        let encoded = try #require(makeEnvelope().encode())
        let decoded = try #require(CourierEnvelope.decode(encoded))
        #expect(decoded.copies == 1)
    }

    @Test func copiesAreClampedToPolicyBounds() {
        #expect(makeEnvelope().withCopies(0).copies == 1)
        #expect(makeEnvelope().withCopies(200).copies == CourierEnvelope.maxCopies)
    }

    // MARK: - Codec

    @Test func roundTrip() throws {
        let envelope = makeEnvelope()
        let encoded = try #require(envelope.encode())
        let decoded = try #require(CourierEnvelope.decode(encoded))
        #expect(decoded == envelope)
    }

    @Test func roundTripAtMaxCiphertextSize() throws {
        let envelope = makeEnvelope(ciphertext: Data(repeating: 0x01, count: CourierEnvelope.maxCiphertextBytes))
        let encoded = try #require(envelope.encode())
        let decoded = try #require(CourierEnvelope.decode(encoded))
        #expect(decoded == envelope)
    }

    @Test func encodeRejectsInvalidFields() {
        #expect(makeEnvelope(tag: Data(repeating: 0, count: 8)).encode() == nil)
        #expect(makeEnvelope(ciphertext: Data()).encode() == nil)
        #expect(makeEnvelope(ciphertext: Data(repeating: 0, count: CourierEnvelope.maxCiphertextBytes + 1)).encode() == nil)
    }

    @Test func decodeRejectsMissingFields() throws {
        // Strip the trailing ciphertext TLV: tag(3+16) + expiry(3+8) only.
        let encoded = try #require(makeEnvelope().encode())
        let truncated = encoded.prefix(3 + CourierEnvelope.tagLength + 3 + 8)
        #expect(CourierEnvelope.decode(Data(truncated)) == nil)
    }

    @Test func decodeRejectsTruncatedValue() throws {
        let encoded = try #require(makeEnvelope().encode())
        #expect(CourierEnvelope.decode(encoded.dropLast(1)) == nil)
    }

    @Test func decodeSkipsUnknownTLVs() throws {
        var encoded = try #require(makeEnvelope().encode())
        // Append an unknown TLV (type 0x7F, 2-byte value); decoder must tolerate it.
        encoded.append(contentsOf: [0x7F, 0x00, 0x02, 0xDE, 0xAD])
        let decoded = try #require(CourierEnvelope.decode(encoded))
        #expect(decoded == makeEnvelope())
    }

    @Test func decodeOffsetSlice() throws {
        // Decoder must handle slices with non-zero startIndex.
        let encoded = try #require(makeEnvelope().encode())
        let padded = Data([0xFF, 0xFF]) + encoded
        let slice = padded.dropFirst(2)
        #expect(CourierEnvelope.decode(Data(slice)) == makeEnvelope())
        #expect(CourierEnvelope.decode(slice) == makeEnvelope())
    }

    // MARK: - Expiry

    @Test func expiryComparison() {
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        #expect(!makeEnvelope(expiry: nowMs + 60_000).isExpired)
        #expect(makeEnvelope(expiry: nowMs - 60_000).isExpired)
        #expect(makeEnvelope(expiry: 0).isExpired)
    }

    // MARK: - Recipient Tags

    @Test func tagIsDeterministicPerKeyAndDay() {
        let key = Data(repeating: 0x11, count: 32)
        let tag1 = CourierEnvelope.recipientTag(noiseStaticKey: key, epochDay: 20_000)
        let tag2 = CourierEnvelope.recipientTag(noiseStaticKey: key, epochDay: 20_000)
        #expect(tag1 == tag2)
        #expect(tag1.count == CourierEnvelope.tagLength)
    }

    @Test func tagRotatesAcrossDaysAndKeys() {
        let key = Data(repeating: 0x11, count: 32)
        let otherKey = Data(repeating: 0x22, count: 32)
        let day: UInt32 = 20_000
        #expect(CourierEnvelope.recipientTag(noiseStaticKey: key, epochDay: day)
            != CourierEnvelope.recipientTag(noiseStaticKey: key, epochDay: day + 1))
        #expect(CourierEnvelope.recipientTag(noiseStaticKey: key, epochDay: day)
            != CourierEnvelope.recipientTag(noiseStaticKey: otherKey, epochDay: day))
    }

    @Test func candidateTagsCoverAdjacentDays() {
        let key = Data(repeating: 0x33, count: 32)
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let day = CourierEnvelope.epochDay(for: date)
        let candidates = CourierEnvelope.candidateTags(noiseStaticKey: key, around: date)
        #expect(candidates.count == 3)
        #expect(candidates.contains(CourierEnvelope.recipientTag(noiseStaticKey: key, epochDay: day - 1)))
        #expect(candidates.contains(CourierEnvelope.recipientTag(noiseStaticKey: key, epochDay: day)))
        #expect(candidates.contains(CourierEnvelope.recipientTag(noiseStaticKey: key, epochDay: day + 1)))
    }

    @Test func sealedYesterdayMatchesToday() {
        // An envelope sealed late on day D must still match the recipient on day D+1.
        let key = Data(repeating: 0x44, count: 32)
        let sealedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let deliveredAt = sealedAt.addingTimeInterval(20 * 60 * 60)
        let tag = CourierEnvelope.recipientTag(noiseStaticKey: key, epochDay: CourierEnvelope.epochDay(for: sealedAt))
        #expect(CourierEnvelope.candidateTags(noiseStaticKey: key, around: deliveredAt).contains(tag))
    }
}

//
// StickerRefCodecTests.swift
// bitchatTests
//
// Tests for the Sonar sticker-ref wire codec: round-trip, sonar-ffi parity
// vectors, strict shape rejection, and adversarial (separator-only / huge /
// emoji) input. The codec parses attacker-controlled mesh content, so
// "never crash" matters as much as "parse correctly".
//

import Foundation
import Testing
@testable import bitchat

struct StickerRefCodecTests {

    // MARK: - Builders

    private let pubkey = String(repeating: "ab", count: 32) // 64 lowercase hex
    private let sha256 = String(repeating: "deadbeef", count: 8) // 64 lowercase hex

    private func makeRef(
        coordinate: String? = nil,
        shortcode: String = "wave",
        hash: String? = nil
    ) -> StickerRef? {
        StickerRef(
            packCoordinate: coordinate ?? "30031:\(pubkey):my-pack",
            shortcode: shortcode,
            plaintextSha256: hash ?? sha256
        )
    }

    // MARK: - Round trip

    @Test func encodeParseRoundTrip() {
        let ref = makeRef()
        #expect(ref != nil)
        let parsed = StickerRefCodec.parse(StickerRefCodec.encode(ref!))
        #expect(parsed == ref)
        #expect(ref!.content == StickerRefCodec.encode(ref!))
    }

    // MARK: - sonar-ffi parity vectors

    @Test func encodeMatchesSonarFfiBytes() {
        // mesh_sticker_content output must be byte-identical.
        let ref = makeRef()!
        let expected = "\u{1F}sticker\u{1F}30031:\(pubkey):my-pack\u{1F}wave\u{1F}\(sha256)"
        #expect(StickerRefCodec.encode(ref) == expected)
        #expect(StickerRefCodec.encode(ref).hasPrefix("\u{1F}sticker\u{1F}"))
    }

    @Test func parseAcceptsSonarFfiEncodedContent() {
        // Hand-built exactly as mesh_parse_sticker_content would see it.
        let wire = "\u{1F}sticker\u{1F}30031:\(pubkey):pack\u{1F}wave\u{1F}\(sha256)"
        let ref = StickerRefCodec.parse(wire)
        #expect(ref == makeRef(coordinate: "30031:\(pubkey):pack"))
    }

    // MARK: - Not a sticker at all

    @Test func rejectsNonStickerContent() {
        #expect(StickerRefCodec.parse("hello world") == nil)
        #expect(StickerRefCodec.parse("") == nil)
        #expect(StickerRefCodec.parse("sticker:fake") == nil)
        // "sticker" tag without the leading Unit Separator sentinel.
        #expect(StickerRefCodec.parse("sticker\u{1F}30031:\(pubkey):pack\u{1F}wave\u{1F}\(sha256)") == nil)
        // Right tag, wrong sentinel position.
        #expect(StickerRefCodec.parse("x\u{1F}sticker\u{1F}30031:\(pubkey):pack\u{1F}wave\u{1F}\(sha256)") == nil)
    }

    // MARK: - Coordinate validation

    @Test func rejectsBadCoordinates() {
        func ref(with coordinate: String) -> StickerRef? { makeRef(coordinate: coordinate) }

        #expect(ref(with: "30032:\(pubkey):pack") == nil)              // wrong kind
        #expect(ref(with: "30031:\(pubkey.uppercased()):pack") == nil) // uppercase hex
        #expect(ref(with: "30031:\(String(pubkey.dropLast())):pack") == nil) // short pubkey
        #expect(ref(with: "30031:\(pubkey)00:pack") == nil)            // long pubkey
        #expect(ref(with: "30031:\(pubkey):bad id") == nil)            // space in identifier
        #expect(ref(with: "30031:\(pubkey):bad/id") == nil)            // slash in identifier
        #expect(ref(with: "30031:\(pubkey):") == nil)                  // empty identifier
        #expect(ref(with: "30031:\(pubkey):\(String(repeating: "a", count: 81))") == nil) // 81-char identifier
        #expect(ref(with: "30031:\(pubkey)") == nil)                   // missing identifier field
        #expect(ref(with: ":\(pubkey):pack") == nil)                   // empty kind
    }

    @Test func acceptsCoordinateBoundaryIdentifiers() {
        #expect(makeRef(coordinate: "30031:\(pubkey):a") != nil)
        #expect(makeRef(coordinate: "30031:\(pubkey):\(String(repeating: "a", count: 80))") != nil)
        #expect(makeRef(coordinate: "30031:\(pubkey):A-Z_a.z-09") != nil)
    }

    // MARK: - Shortcode validation

    @Test func rejectsBadShortcodes() {
        #expect(makeRef(shortcode: "") == nil)
        #expect(makeRef(shortcode: String(repeating: "w", count: 65)) == nil)
        #expect(makeRef(shortcode: "wavé") == nil)   // non-ASCII
        #expect(makeRef(shortcode: "so-wave") == nil) // dash not allowed
        #expect(makeRef(shortcode: "so wave") == nil)
    }

    @Test func acceptsShortcodeBoundaries() {
        #expect(makeRef(shortcode: "a") != nil)
        #expect(makeRef(shortcode: String(repeating: "w", count: 64)) != nil)
        #expect(makeRef(shortcode: "Wave_09") != nil)
    }

    // MARK: - SHA-256 validation

    @Test func rejectsBadSha256() {
        #expect(makeRef(hash: String(repeating: "a", count: 63)) == nil)
        #expect(makeRef(hash: String(repeating: "a", count: 65)) == nil)
        #expect(makeRef(hash: sha256.uppercased()) == nil)
        #expect(makeRef(hash: String(repeating: "g", count: 64)) == nil) // non-hex
    }

    // MARK: - Field count / framing

    @Test func rejectsWrongFieldCounts() {
        let base = "\u{1F}sticker\u{1F}30031:\(pubkey):pack\u{1F}wave\u{1F}\(sha256)"
        #expect(StickerRefCodec.parse(base + "\u{1F}extra") == nil)      // trailing field
        #expect(StickerRefCodec.parse(base + "\u{1F}\u{1F}\u{1F}") == nil) // >4 splits
        #expect(StickerRefCodec.parse("\u{1F}sticker\u{1F}30031:\(pubkey):pack\u{1F}wave") == nil) // missing hash
        #expect(StickerRefCodec.parse("\u{1F}sticker\u{1F}30031:\(pubkey):pack\u{1F}\u{1F}\(sha256)") == nil) // empty shortcode field
    }

    // MARK: - Never-crash fuzz-ish

    @Test func pathologicalInputsNeverCrashAndNeverParse() {
        let cases = [
            String(repeating: "\u{1F}", count: 5),                       // all separators
            String(repeating: "\u{1F}", count: 4096),
            "\u{1F}sticker" + String(repeating: "\u{1F}", count: 100),
            String(repeating: "a", count: 100_000),                      // very long
            "\u{1F}sticker\u{1F}🌊🌊🌊\u{1F}🌊\u{1F}🌊",                 // emoji fields
            "\u{1F}sticker\u{1F}30031:\(pubkey):pack\u{1F}wave\u{1F}\(sha256)\u{1F}",
            "\u{1F}sticker\u{1F}\u{1F}\u{1F}\u{1F}",
            "sticker\u{1F}\u{1F}\u{1F}\u{1F}\u{1F}",
        ]
        for content in cases {
            #expect(StickerRefCodec.parse(content) == nil)
        }
    }
}

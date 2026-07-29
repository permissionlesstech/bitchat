//
// StickerPackValidationTests.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import bitchat

/// Pure validation tests for `StickerPackService.parsePackEvent` — no relay,
/// Tor, or network access; `NostrEvent` fixtures are built in code.
@Suite("Sticker Pack Validation Tests")
struct StickerPackValidationTests {

    private let pubkey = String(repeating: "a", count: 64)
    private let hash1 = String(repeating: "1", count: 64)
    private let hash2 = String(repeating: "2", count: 64)

    // MARK: - Fixture builders

    private func makeEvent(
        kind: Int = 30031,
        pubkey: String? = nil,
        createdAt: Int = 1_700_000_000,
        tags: [[String]]
    ) -> NostrEvent {
        // Raw-kind init (internal, @testable): bypasses the inbound relay
        // tag-count cap so >64-tag packs can be exercised for unit tests.
        NostrEvent(
            pubkey: pubkey ?? self.pubkey,
            createdAt: createdAt,
            kind: kind,
            tags: tags,
            content: ""
        )
    }

    private func stickerTag(
        shortcode: String = "party_blob",
        hash: String? = nil,
        mime: String = "image/webp",
        dim: String? = "128x128",
        url: String? = nil
    ) -> [String] {
        let h = hash ?? hash1
        var tag = ["sticker", shortcode, url ?? "https://cdn.example.com/stickers/\(h).webp", h, mime]
        if let dim { tag.append(dim) }
        return tag
    }

    private func validTags(stickers: [[String]]? = nil) -> [[String]] {
        [
            ["d", "cool-pack"],
            ["title", "Cool Pack"],
            ["pack_format", "sonar-sticker-pack-v1"]
        ] + (stickers ?? [stickerTag()])
    }

    // MARK: - Valid pack

    @Test("spec-compliant pack event parses with all fields")
    func validPackParses() {
        let event = makeEvent(tags: [
            ["d", "cool-pack"],
            ["title", "Cool Pack"],
            ["description", "A very cool pack"],
            ["image", "https://cdn.example.com/cover.png"],
            ["pack_format", "sonar-sticker-pack-v1"],
            ["sticker", "party_blob", "https://cdn.example.com/stickers/\(hash1).webp",
             hash1, "image/webp", "128x128", "Party blob", "🎉"]
        ])

        let pack = StickerPackService.parsePackEvent(event)
        #expect(pack != nil)
        #expect(pack?.coordinate == "30031:\(pubkey):cool-pack")
        #expect(pack?.authorPubkey == pubkey)
        #expect(pack?.identifier == "cool-pack")
        #expect(pack?.title == "Cool Pack")
        #expect(pack?.description == "A very cool pack")
        #expect(pack?.coverURL?.absoluteString == "https://cdn.example.com/cover.png")
        #expect(pack?.stickers.count == 1)
        let sticker = pack?.stickers.first
        #expect(sticker?.shortcode == "party_blob")
        #expect(sticker?.sha256 == hash1)
        #expect(sticker?.mime == "image/webp")
        #expect(sticker?.dim == StickerDimensions(width: 128, height: 128))
        #expect(sticker?.alt == "Party blob")
        #expect(sticker?.emoji == "🎉")
        #expect(pack?.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("optional dim/alt/emoji may be absent")
    func optionalFieldsMayBeAbsent() {
        let event = makeEvent(tags: validTags(stickers: [
            ["sticker", "blob", "https://cdn.example.com/\(hash1).png", hash1, "image/png"]
        ]))
        let pack = StickerPackService.parsePackEvent(event)
        #expect(pack?.stickers.first?.dim == nil)
        #expect(pack?.stickers.first?.alt == nil)
        #expect(pack?.stickers.first?.emoji == nil)
    }

    // MARK: - Envelope rules

    @Test("wrong kind is rejected", arguments: [30032, 1, 10031, 30311])
    func wrongKindRejected(kind: Int) {
        #expect(StickerPackService.parsePackEvent(makeEvent(kind: kind, tags: validTags())) == nil)
    }

    @Test("missing pack_format tag is rejected")
    func missingPackFormatRejected() {
        let tags = validTags().filter { $0.first != "pack_format" }
        #expect(StickerPackService.parsePackEvent(makeEvent(tags: tags)) == nil)
    }

    @Test("wrong pack_format value is rejected")
    func wrongPackFormatRejected() {
        let tags = validTags().map { $0.first == "pack_format" ? ["pack_format", "other-v1"] : $0 }
        #expect(StickerPackService.parsePackEvent(makeEvent(tags: tags)) == nil)
    }

    @Test("missing or invalid d tag is rejected", arguments: [nil, "", "has spaces", String(repeating: "x", count: 300)])
    func invalidDTagRejected(identifier: String?) {
        var tags = validTags().filter { $0.first != "d" }
        if let identifier { tags.append(["d", identifier]) }
        #expect(StickerPackService.parsePackEvent(makeEvent(tags: tags)) == nil)
    }

    @Test("missing or blank title is rejected", arguments: [nil, "", "   "])
    func invalidTitleRejected(title: String?) {
        var tags = validTags().filter { $0.first != "title" }
        if let title { tags.append(["title", title]) }
        #expect(StickerPackService.parsePackEvent(makeEvent(tags: tags)) == nil)
    }

    @Test("malformed pubkey is rejected")
    func invalidPubkeyRejected() {
        #expect(StickerPackService.parsePackEvent(makeEvent(pubkey: "nothex", tags: validTags())) == nil)
        #expect(StickerPackService.parsePackEvent(
            makeEvent(pubkey: String(repeating: "A", count: 64), tags: validTags())
        ) == nil)
    }

    // MARK: - Sticker tag rules

    @Test("pack with zero stickers is rejected")
    func noStickersRejected() {
        #expect(StickerPackService.parsePackEvent(makeEvent(tags: validTags(stickers: []))) == nil)
    }

    @Test("non-HTTPS sticker URL is rejected", arguments: [
        "http://cdn.example.com/x.webp",
        "ftp://cdn.example.com/x.webp",
        "not-a-url",
        "https://user:pass@cdn.example.com/x.webp"
    ])
    func nonHTTPSRejected(url: String) {
        let tags = validTags(stickers: [stickerTag(url: url)])
        #expect(StickerPackService.parsePackEvent(makeEvent(tags: tags)) == nil)
    }

    @Test("sticker URL whose path lacks the sha256 is rejected")
    func urlMissingHashRejected() {
        let tags = validTags(stickers: [
            stickerTag(url: "https://cdn.example.com/stickers/other.webp")
        ])
        #expect(StickerPackService.parsePackEvent(makeEvent(tags: tags)) == nil)
    }

    @Test("disallowed MIME is rejected", arguments: ["image/jpeg", "image/svg+xml", "video/mp4", "application/octet-stream"])
    func badMimeRejected(mime: String) {
        let tags = validTags(stickers: [stickerTag(mime: mime)])
        #expect(StickerPackService.parsePackEvent(makeEvent(tags: tags)) == nil)
    }

    @Test("all allowed MIMEs parse", arguments: ["image/webp", "image/png", "image/apng", "image/gif"])
    func allowedMimesParse(mime: String) {
        let tags = validTags(stickers: [stickerTag(mime: mime)])
        #expect(StickerPackService.parsePackEvent(makeEvent(tags: tags))?.stickers.first?.mime == mime)
    }

    @Test("malformed sha256 is rejected", arguments: [
        "xyz", String(repeating: "1", count: 63), String(repeating: "F", count: 64)
    ])
    func badSHA256Rejected(hash: String) {
        let tags = validTags(stickers: [
            ["sticker", "blob", "https://cdn.example.com/\(hash).webp", hash, "image/webp", "10x10"]
        ])
        #expect(StickerPackService.parsePackEvent(makeEvent(tags: tags)) == nil)
    }

    // Shortcode rules come from the wire codec (`StickerRef.isValidShortcode`):
    // `[A-Za-z0-9_]{1,64}` — uppercase is valid, dash is not.
    @Test("invalid shortcode is rejected", arguments: ["", "has space", "emoji🎉", "so-wave", String(repeating: "a", count: 65)])
    func badShortcodeRejected(shortcode: String) {
        let tags = validTags(stickers: [stickerTag(shortcode: shortcode)])
        #expect(StickerPackService.parsePackEvent(makeEvent(tags: tags)) == nil)
    }

    @Test("codec-valid shortcode parses (pack and wire rules cannot drift)")
    func codecValidShortcodeParses() {
        let tags = validTags(stickers: [stickerTag(shortcode: "Wave_09")])
        let pack = StickerPackService.parsePackEvent(makeEvent(tags: tags))
        #expect(pack?.stickers.first?.shortcode == "Wave_09")
        // …and the same shortcode is encodable into a wire reference.
        #expect(StickerRef.isValidShortcode("Wave_09"))
    }

    @Test("duplicate shortcodes are rejected")
    func duplicateShortcodeRejected() {
        let tags = validTags(stickers: [
            stickerTag(shortcode: "dup", hash: hash1),
            stickerTag(shortcode: "dup", hash: hash2)
        ])
        #expect(StickerPackService.parsePackEvent(makeEvent(tags: tags)) == nil)
    }

    @Test("duplicate hashes are rejected")
    func duplicateHashRejected() {
        let tags = validTags(stickers: [
            stickerTag(shortcode: "one", hash: hash1),
            stickerTag(shortcode: "two", hash: hash1)
        ])
        #expect(StickerPackService.parsePackEvent(makeEvent(tags: tags)) == nil)
    }

    @Test("packs with more than 200 stickers are rejected")
    func tooManyStickersRejected() {
        let stickers = (0..<201).map { i -> [String] in
            let hash = String(format: "%064d", i + 1) // decimal digits are valid lowercase hex
            return ["sticker", "s\(i)", "https://cdn.example.com/\(hash).webp", hash, "image/webp", "10x10"]
        }
        #expect(StickerPackService.parsePackEvent(makeEvent(tags: validTags(stickers: stickers))) == nil)
    }

    @Test("200 stickers exactly parses")
    func exactlyMaxStickersParses() {
        let stickers = (0..<200).map { i -> [String] in
            let hash = String(format: "%064d", i + 1)
            return ["sticker", "s\(i)", "https://cdn.example.com/\(hash).webp", hash, "image/webp", "10x10"]
        }
        let pack = StickerPackService.parsePackEvent(makeEvent(tags: validTags(stickers: stickers)))
        #expect(pack?.stickers.count == 200)
    }

    @Test("invalid dim is rejected", arguments: ["0x10", "10x0", "5000x10", "10x5000", "abc", "10x20x30", "-5x10", "10X20", "10 x20"])
    func badDimRejected(dim: String) {
        let tags = validTags(stickers: [stickerTag(dim: dim)])
        #expect(StickerPackService.parsePackEvent(makeEvent(tags: tags)) == nil)
    }

    @Test("boundary dims parse", arguments: ["1x1", "4096x4096", "1x4096"])
    func boundaryDimsParse(dim: String) {
        let tags = validTags(stickers: [stickerTag(dim: dim)])
        #expect(StickerPackService.parsePackEvent(makeEvent(tags: tags))?.stickers.first?.dim != nil)
    }

    @Test("truncated sticker tag is rejected")
    func truncatedStickerTagRejected() {
        let tags = validTags(stickers: [
            ["sticker", "blob", "https://cdn.example.com/\(hash1).webp", hash1] // missing mime
        ])
        #expect(StickerPackService.parsePackEvent(makeEvent(tags: tags)) == nil)
    }

    // MARK: - Cover image

    @Test("non-HTTPS cover image is rejected")
    func nonHTTPSCoverRejected() {
        var tags = validTags()
        tags.append(["image", "http://cdn.example.com/cover.png"])
        #expect(StickerPackService.parsePackEvent(makeEvent(tags: tags)) == nil)
    }

    // MARK: - Ref validation (pack-edit attack)

    @Test("validateStickerRef requires both shortcode and pinned hash in the current pack")
    @MainActor
    func validateStickerRefAgainstPack() {
        let event = makeEvent(tags: validTags(stickers: [
            stickerTag(shortcode: "party_blob", hash: hash1)
        ]))
        guard let pack = StickerPackService.parsePackEvent(event) else {
            Issue.record("fixture pack failed to parse")
            return
        }
        let service = StickerPackService(
            cache: StickerCache(baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("sticker-svc-tests-\(UUID().uuidString)", isDirectory: true)),
            relayQuery: { _ in [] },
            downloader: { _ in throw URLError(.networkConnectionLost) },
            networkActivationAllowed: { false },
            metadataURL: nil
        )

        // Happy path: coordinate + shortcode + pinned hash all match.
        #expect(service.validateStickerRef(
            packCoordinate: pack.coordinate, shortcode: "party_blob",
            plaintextSha256: hash1, against: pack
        ))
        // Pack edited: shortcode still present but hash changed → untrusted.
        #expect(!service.validateStickerRef(
            packCoordinate: pack.coordinate, shortcode: "party_blob",
            plaintextSha256: hash2, against: pack
        ))
        // Shortcode removed from the pack → untrusted.
        #expect(!service.validateStickerRef(
            packCoordinate: pack.coordinate, shortcode: "gone",
            plaintextSha256: hash1, against: pack
        ))
        // Different pack entirely → untrusted.
        #expect(!service.validateStickerRef(
            packCoordinate: "30031:\(String(repeating: "b", count: 64)):cool-pack",
            shortcode: "party_blob", plaintextSha256: hash1, against: pack
        ))
    }
}

//
// CashuTokenDecoderTests.swift
// bitchatTests
//
// Tests for the Cashu token summary decoder: V3 JSON decode, minimal V4
// CBOR traversal, URI normalization, detection ranges, and adversarial
// (truncated / garbage / huge) input. The decoder renders attacker-controlled
// message content, so "never crash" matters as much as "decode correctly".
// This is free and unencumbered software released into the public domain.
//

import Foundation
import Testing
@testable import bitchat

struct CashuTokenDecoderTests {

    // MARK: - Token Builders

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func makeV3Token(
        entries: [(mint: String, amounts: [Int])],
        unit: String? = "sat",
        memo: String? = nil
    ) -> String {
        var json: [String: Any] = [
            "token": entries.map { entry in
                [
                    "mint": entry.mint,
                    "proofs": entry.amounts.map {
                        ["amount": $0, "id": "009a1f293253e41e", "secret": "s", "C": "02c"] as [String: Any]
                    }
                ] as [String: Any]
            }
        ]
        if let unit { json["unit"] = unit }
        if let memo { json["memo"] = memo }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return "cashuA" + base64URL(data)
    }

    /// Tiny deterministic CBOR encoder (definite lengths only) for building
    /// V4 test tokens without depending on the decoder under test.
    private enum CBOREncode {
        static func head(_ major: UInt8, _ value: UInt64) -> [UInt8] {
            switch value {
            case 0...23:
                return [(major << 5) | UInt8(value)]
            case 24...0xFF:
                return [(major << 5) | 24, UInt8(value)]
            case 0x100...0xFFFF:
                return [(major << 5) | 25, UInt8(value >> 8), UInt8(value & 0xFF)]
            default:
                return [(major << 5) | 26,
                        UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                        UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
            }
        }
        static func uint(_ v: UInt64) -> [UInt8] { head(0, v) }
        static func bytes(_ b: [UInt8]) -> [UInt8] { head(2, UInt64(b.count)) + b }
        static func text(_ s: String) -> [UInt8] {
            let utf8 = Array(s.utf8)
            return head(3, UInt64(utf8.count)) + utf8
        }
        static func array(_ items: [[UInt8]]) -> [UInt8] {
            head(4, UInt64(items.count)) + items.flatMap { $0 }
        }
        static func map(_ pairs: [(String, [UInt8])]) -> [UInt8] {
            head(5, UInt64(pairs.count)) + pairs.flatMap { text($0.0) + $0.1 }
        }
    }

    private func makeV4Token(
        mint: String = "https://mint.example.com",
        unit: String = "sat",
        memo: String? = nil,
        amounts: [UInt64] = [1, 4]
    ) -> String {
        var pairs: [(String, [UInt8])] = [
            ("m", CBOREncode.text(mint)),
            ("u", CBOREncode.text(unit))
        ]
        if let memo { pairs.append(("d", CBOREncode.text(memo))) }
        let proofs = amounts.map { amount in
            CBOREncode.map([
                ("a", CBOREncode.uint(amount)),
                ("s", CBOREncode.text("secret")),
                ("c", CBOREncode.bytes([0x02, 0xAB, 0xCD]))
            ])
        }
        pairs.append(("t", CBOREncode.array([
            CBOREncode.map([
                ("i", CBOREncode.bytes([0x00, 0xAD, 0x26, 0x8C])),
                ("p", CBOREncode.array(proofs))
            ])
        ])))
        return "cashuB" + base64URL(Data(CBOREncode.map(pairs)))
    }

    // MARK: - V3 Decode

    @Test func v3DecodeValidToken() {
        let token = makeV3Token(
            entries: [("https://mint.example.com", [2, 8])],
            unit: "sat",
            memo: "thanks!"
        )
        let info = CashuTokenDecoder.decode(token)
        #expect(info != nil)
        #expect(info?.version == "A")
        #expect(info?.amount == 10)
        #expect(info?.unit == "sat")
        #expect(info?.mintHost == "mint.example.com")
        #expect(info?.memo == "thanks!")
        #expect(info?.displayAmount == "10 sat")
    }

    @Test func v3AmountSumsAcrossEntriesAndProofs() {
        let token = makeV3Token(entries: [
            ("https://a.mint.example", [1, 2, 4]),
            ("https://b.mint.example", [8, 16])
        ])
        let info = CashuTokenDecoder.decode(token)
        #expect(info?.amount == 31)
        // First mint wins for the display host
        #expect(info?.mintHost == "a.mint.example")
    }

    @Test func v3MissingUnitDefaultsToSatForDisplay() {
        let token = makeV3Token(entries: [("https://mint.example.com", [5])], unit: nil)
        let info = CashuTokenDecoder.decode(token)
        #expect(info?.unit == nil)
        #expect(info?.displayAmount == "5 sat")
    }

    @Test func v3RejectsNonsenseAmounts() {
        // Negative and absurd amounts must not poison the sum
        let json: [String: Any] = [
            "token": [[
                "mint": "https://mint.example.com",
                "proofs": [
                    ["amount": -5, "id": "x", "secret": "s", "C": "c"],
                    ["amount": 3, "id": "x", "secret": "s", "C": "c"]
                ]
            ] as [String: Any]]
        ]
        let token = "cashuA" + base64URL(try! JSONSerialization.data(withJSONObject: json))
        #expect(CashuTokenDecoder.decode(token)?.amount == 3)
    }

    @Test func v3MemoIsSanitizedForDisplay() {
        let token = makeV3Token(
            entries: [("https://mint.example.com", [1])],
            memo: "line1\nline2\u{0007}" + String(repeating: "x", count: 300)
        )
        let memo = CashuTokenDecoder.decode(token)?.memo
        #expect(memo != nil)
        #expect(memo?.contains("\n") == false)
        #expect(memo?.contains("\u{0007}") == false)
        #expect((memo?.count ?? 0) <= 80)
    }

    // MARK: - V4 (CBOR) Decode

    @Test func v4DecodeValidToken() {
        let token = makeV4Token(memo: "Thank you", amounts: [1, 4, 16])
        let info = CashuTokenDecoder.decode(token)
        #expect(info?.version == "B")
        #expect(info?.amount == 21)
        #expect(info?.unit == "sat")
        #expect(info?.mintHost == "mint.example.com")
        #expect(info?.memo == "Thank you")
    }

    @Test func v4UnparseableCBORDegradesToGenericToken() {
        // Valid base64 payload, but not CBOR we can walk: still a token,
        // rendered as a generic chip with no amount.
        let token = "cashuB" + base64URL(Data([0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x01, 0x02]))
        let info = CashuTokenDecoder.decode(token)
        #expect(info?.version == "B")
        #expect(info?.amount == nil)
        #expect(info?.mintHost == nil)
    }

    // MARK: - Strict Mode (used by the /pay SEND path)

    @Test func strictAcceptsValidV3WithPositiveAmount() {
        let token = makeV3Token(entries: [("https://mint.example.com", [2, 8])])
        let info = CashuTokenDecoder.decode(token, strict: true)
        #expect(info?.version == "A")
        #expect(info?.amount == 10)
    }

    @Test func strictAcceptsValidDefiniteLengthV4() {
        let token = makeV4Token(amounts: [1, 4, 16])
        let info = CashuTokenDecoder.decode(token, strict: true)
        #expect(info?.version == "B")
        #expect(info?.amount == 21)
    }

    @Test func strictRejectsUnwalkableV4() {
        // Valid base64, but not CBOR we can walk: permissive mode returns a
        // generic chip, strict mode refuses it.
        let token = "cashuB" + base64URL(Data([0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x01, 0x02]))
        #expect(CashuTokenDecoder.decode(token)?.version == "B")
        #expect(CashuTokenDecoder.decode(token, strict: true) == nil)
    }

    @Test func strictRejectsTruncatedV4() {
        let token = makeV4Token(amounts: [1, 4, 16])
        // Lop off the tail of the base64 payload — CBOR can no longer be walked.
        let truncated = String(token.prefix(token.count - 12))
        #expect(CashuTokenDecoder.decode(truncated, strict: true) == nil)
    }

    @Test func strictRejectsAmountlessToken() {
        // A well-formed V3 token that carries no positive proof amount.
        let json: [String: Any] = [
            "token": [[
                "mint": "https://mint.example.com",
                "proofs": [["amount": 0, "id": "x", "secret": "s", "C": "c"] as [String: Any]]
            ] as [String: Any]]
        ]
        let token = "cashuA" + base64URL(try! JSONSerialization.data(withJSONObject: json))
        #expect(CashuTokenDecoder.decode(token)?.amount == nil)
        #expect(CashuTokenDecoder.decode(token, strict: true) == nil)
    }

    // MARK: - URI Form and Normalization

    @Test func uriFormsDecode() {
        let token = makeV3Token(entries: [("https://mint.example.com", [7])])
        for wrapped in ["cashu:\(token)", "cashu://\(token)", "CASHU:\(token)"] {
            #expect(CashuTokenDecoder.bareToken(from: wrapped) == token, "failed for \(wrapped)")
            #expect(CashuTokenDecoder.decode(wrapped)?.amount == 7)
        }
    }

    @Test func percentEncodedURIDecodes() {
        let token = makeV3Token(entries: [("https://mint.example.com", [7])])
        let encoded = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        #expect(CashuTokenDecoder.decode("cashu:\(encoded)")?.amount == 7)
    }

    @Test func bareTokenRejectsNonTokens() {
        #expect(CashuTokenDecoder.bareToken(from: "hello world") == nil)
        #expect(CashuTokenDecoder.bareToken(from: "cashuC" + String(repeating: "a", count: 50)) == nil)
        #expect(CashuTokenDecoder.bareToken(from: "cashuA{not-base64!}") == nil)
        #expect(CashuTokenDecoder.bareToken(from: "cashuA") == nil) // too short
    }

    // MARK: - Adversarial Input (never crash, fail closed)

    @Test func truncatedTokensNeverCrash() {
        let v3 = makeV3Token(entries: [("https://mint.example.com", [1, 2, 4, 8])], memo: "memo")
        let v4 = makeV4Token(memo: "memo", amounts: [1, 2, 4, 8])
        for token in [v3, v4] {
            for length in stride(from: 0, to: token.count, by: 3) {
                _ = CashuTokenDecoder.decode(String(token.prefix(length)))
            }
        }
        // Truncating the payload must not produce a phantom V3 summary
        #expect(CashuTokenDecoder.decode(String(v3.prefix(v3.count - 10))) == nil)
    }

    @Test func garbagePayloadsNeverCrash() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let length = Int.random(in: 0..<600, using: &rng)
            let junk = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) })
            _ = CashuTokenDecoder.decode("cashuA" + base64URL(junk))
            _ = CashuTokenDecoder.decode("cashuB" + base64URL(junk))
        }
    }

    @Test func hugeInputIsRejectedQuickly() {
        let huge = "cashuA" + String(repeating: "Q", count: 500_000)
        #expect(CashuTokenDecoder.bareToken(from: huge) == nil)
        #expect(CashuTokenDecoder.decode(huge) == nil)
    }

    @Test func absurdAmountsFailClosed() {
        // Each proof exceeds the per-proof sanity cap: skipped, no amount.
        let perProofJSON: [String: Any] = [
            "token": [[
                "mint": "https://mint.example.com",
                "proofs": [["amount": Int64.max / 2, "id": "x", "secret": "s", "C": "c"] as [String: Any]]
            ] as [String: Any]]
        ]
        let perProofToken = "cashuA" + base64URL(try! JSONSerialization.data(withJSONObject: perProofJSON))
        #expect(CashuTokenDecoder.decode(perProofToken)?.amount == nil)

        // Individually plausible proofs whose *sum* overflows the cap: the
        // token is nonsense, reject it entirely (never trap on the add).
        let sumJSON: [String: Any] = [
            "token": [[
                "mint": "https://mint.example.com",
                "proofs": (0..<3).map { _ in
                    ["amount": 1_500_000_000_000_000, "id": "x", "secret": "s", "C": "c"] as [String: Any]
                }
            ] as [String: Any]]
        ]
        let sumToken = "cashuA" + base64URL(try! JSONSerialization.data(withJSONObject: sumJSON))
        #expect(CashuTokenDecoder.decode(sumToken) == nil)
    }

    @Test func deeplyNestedCBORIsBounded() {
        // 64 nested single-element arrays around an int: deeper than the
        // reader's depth cap, must fail cleanly.
        var payload = CBOREncode.uint(1)
        for _ in 0..<64 { payload = CBOREncode.array([payload]) }
        let token = "cashuB" + base64URL(Data(payload))
        let info = CashuTokenDecoder.decode(token)
        #expect(info?.amount == nil)
    }

    // MARK: - Detection Ranges (message scanning)

    @Test func detectionFindsWholeMessageToken() {
        let token = makeV3Token(entries: [("https://mint.example.com", [1])])
        #expect(token.extractCashuLinks() == [token])
    }

    @Test func detectionFindsEmbeddedAndURITokens() {
        let token = makeV3Token(entries: [("https://mint.example.com", [1])])
        let message = "here you go: cashu:\(token) enjoy!"
        // The regex matches the token embedded after the scheme
        #expect(message.extractCashuLinks() == [token])

        let embedded = "prefix \(token) suffix"
        #expect(embedded.extractCashuLinks() == [token])
    }

    @Test func detectionDeduplicatesRepeatedTokens() {
        let token = makeV3Token(entries: [("https://mint.example.com", [1])])
        let message = "\(token) and again \(token)"
        #expect(message.extractCashuLinks() == [token])
    }

    @Test func detectionIgnoresNonTokens() {
        #expect("just talking about cashu here".extractCashuLinks().isEmpty)
        #expect("cashuAshort".extractCashuLinks().isEmpty)
    }
}

//
// CashuTokenDecoder.swift
// bitchat
//
// Decodes Cashu ecash tokens (V3 `cashuA` = base64url JSON, V4 `cashuB` =
// base64url CBOR) just far enough to summarize them for the UI: total
// amount, unit, mint host, and memo. The app never contacts a mint — tokens
// are bearer strings and redemption is delegated to an external wallet.
//
// This parses attacker-controlled message content, so every path is
// bounds-checked, size-capped, and returns nil instead of trapping.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

enum CashuTokenDecoder {

    struct TokenInfo: Equatable {
        /// Token serialization version: "A" (JSON) or "B" (CBOR).
        let version: String
        /// Sum of all proof amounts; nil when no valid amounts were found.
        let amount: Int?
        /// Currency unit as declared by the token (commonly "sat"), if any.
        let unit: String?
        /// Host of the (first) mint URL, for display.
        let mintHost: String?
        /// Optional sender memo, sanitized for display.
        let memo: String?

        /// "500 sat" style summary, defaulting the unit to sats per NUT-00.
        var displayAmount: String? {
            amount.map { "\($0) \(unit ?? "sat")" }
        }
    }

    /// Upper bound on accepted token length in characters. Real tokens are a
    /// few KB; anything much bigger is abuse we shouldn't spend CPU on.
    static let maxTokenLength = 60_000
    /// Per-proof and total amount sanity caps (order of total sats in existence).
    private static let maxAmount: Int64 = 2_100_000_000_000_000

    // MARK: - Public API

    /// Extracts the bare `cashuA…`/`cashuB…` token from raw text that may be
    /// a `cashu:`/`cashu://` URI and/or percent-encoded. Returns nil when the
    /// input doesn't look like a Cashu token at all.
    static func bareToken(from raw: String) -> String? {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = token.lowercased()
        if lower.hasPrefix("cashu://") {
            token = String(token.dropFirst(8))
        } else if lower.hasPrefix("cashu:") {
            token = String(token.dropFirst(6))
        }
        if token.contains("%"), let decoded = token.removingPercentEncoding {
            token = decoded
        }
        guard token.count >= 12, token.count <= maxTokenLength else { return nil }
        guard token.hasPrefix("cashuA") || token.hasPrefix("cashuB") else { return nil }
        // Base64 / base64url payload charset ('.' appears in some legacy multi-part tokens)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_+/=."))
        guard token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return token
    }

    /// Decodes a token (raw or `cashu:` URI form) into a display summary.
    ///
    /// In the default (permissive) mode this is for *rendering*: V3 tokens
    /// must parse as JSON, but a V4 token whose CBOR we cannot walk still
    /// returns a generic `TokenInfo` (version "B", no amount) because the
    /// payload may use encodings this minimal reader doesn't support — an
    /// unknown chip is fine for display.
    ///
    /// In `strict` mode (used by the `/pay` SEND path) there is no permissive
    /// fallback: the token must cleanly decode to a known version *and* carry
    /// a positive amount, otherwise this returns nil. This stops base64 junk
    /// and truncated V4 tokens from being relayed as if they were valid money.
    static func decode(_ raw: String, strict: Bool = false) -> TokenInfo? {
        guard let token = bareToken(from: raw) else { return nil }
        let version = String(token[token.index(token.startIndex, offsetBy: 5)])
        guard let payload = base64URLDecode(String(token.dropFirst(6))), !payload.isEmpty else {
            return nil
        }
        let info: TokenInfo?
        switch version {
        case "A":
            info = decodeV3(payload)
        case "B":
            if let walked = decodeV4(payload) {
                info = walked
            } else if strict {
                // Couldn't cleanly walk the CBOR — refuse to send it.
                return nil
            } else {
                info = TokenInfo(version: "B", amount: nil, unit: nil, mintHost: nil, memo: nil)
            }
        default:
            return nil
        }
        guard let info else { return nil }
        if strict {
            // A sendable token must resolve to a positive, sane amount.
            guard let amount = info.amount, amount > 0 else { return nil }
        }
        return info
    }

    // MARK: - Base64url

    private static func base64URLDecode(_ input: String) -> Data? {
        var s = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Normalize padding (wallets emit both padded and unpadded forms)
        s = s.replacingOccurrences(of: "=", with: "")
        let remainder = s.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }

    // MARK: - V3 (JSON)

    private static func decodeV3(_ payload: Data) -> TokenInfo? {
        guard let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let entries = obj["token"] as? [[String: Any]],
              !entries.isEmpty else {
            return nil
        }
        var total: Int64 = 0
        var sawAmount = false
        var mintHost: String?
        for entry in entries {
            if mintHost == nil, let mint = entry["mint"] as? String {
                mintHost = sanitizedHost(from: mint)
            }
            for proof in (entry["proofs"] as? [[String: Any]]) ?? [] {
                guard let number = proof["amount"] as? NSNumber else { continue }
                let value = number.int64Value
                guard value > 0, value <= maxAmount else { continue }
                total += value
                guard total <= maxAmount else { return nil }
                sawAmount = true
            }
        }
        return TokenInfo(
            version: "A",
            amount: sawAmount ? Int(total) : nil,
            unit: sanitizedUnit(obj["unit"] as? String),
            mintHost: mintHost,
            memo: sanitizedMemo(obj["memo"] as? String)
        )
    }

    // MARK: - V4 (CBOR)

    /// Minimal walk of the NUT-00 TokenV4 CBOR map:
    /// { "m": mint, "u": unit, "d": memo, "t": [ { "i": bytes, "p": [ { "a": amount, … } ] } ] }
    private static func decodeV4(_ payload: Data) -> TokenInfo? {
        var reader = CBORReader(data: payload)
        guard case .map(let pairs)? = reader.parseValue(depth: 0) else { return nil }
        var mintHost: String?
        var unit: String?
        var memo: String?
        var total: Int64 = 0
        var sawAmount = false
        for (key, value) in pairs {
            guard case .text(let name) = key else { continue }
            switch (name, value) {
            case ("m", .text(let mint)):
                mintHost = sanitizedHost(from: mint)
            case ("u", .text(let u)):
                unit = sanitizedUnit(u)
            case ("d", .text(let d)):
                memo = sanitizedMemo(d)
            case ("t", .array(let groups)):
                for case .map(let group) in groups {
                    for case (.text("p"), .array(let proofs)) in group {
                        for case .map(let proof) in proofs {
                            for case (.text("a"), .unsigned(let amount)) in proof {
                                guard amount > 0, amount <= UInt64(maxAmount) else { continue }
                                total += Int64(amount)
                                guard total <= maxAmount else { return nil }
                                sawAmount = true
                            }
                        }
                    }
                }
            default:
                break
            }
        }
        return TokenInfo(
            version: "B",
            amount: sawAmount ? Int(total) : nil,
            unit: unit,
            mintHost: mintHost,
            memo: memo
        )
    }

    // MARK: - Display Sanitization (values are attacker-controlled)

    private static func sanitizedHost(from mint: String) -> String? {
        guard mint.count <= 512, let host = URL(string: mint)?.host, !host.isEmpty else { return nil }
        return String(host.lowercased().prefix(48))
    }

    private static func sanitizedUnit(_ unit: String?) -> String? {
        guard let unit, !unit.isEmpty, unit.count <= 12,
              unit.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            return nil
        }
        return unit
    }

    private static func sanitizedMemo(_ memo: String?) -> String? {
        guard let memo, memo.count <= 512 else { return nil }
        let stripped = CharacterSet.controlCharacters.union(.newlines)
        var cleaned = ""
        cleaned.unicodeScalars.append(contentsOf: memo.unicodeScalars.filter { !stripped.contains($0) })
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(80))
    }
}

// MARK: - Minimal CBOR Reader

/// Just enough definite-length CBOR to traverse a TokenV4 map. Bounded in
/// depth, item count, and byte length; indefinite-length items and anything
/// else exotic make the parse fail (the caller degrades to a generic chip).
private struct CBORReader {
    indirect enum Value {
        case unsigned(UInt64)
        case text(String)
        case array([Value])
        case map([(Value, Value)])
        /// Parsed-and-skipped content we don't need (byte strings, negatives, floats…)
        case opaque
    }

    private let bytes: [UInt8]
    private var index = 0
    /// Total item budget so hostile nesting can't run away.
    private var itemBudget = 50_000
    private static let maxDepth = 16
    private static let maxContainerCount: UInt64 = 10_000

    init(data: Data) {
        bytes = [UInt8](data)
    }

    mutating func parseValue(depth: Int) -> Value? {
        guard depth < Self.maxDepth, itemBudget > 0 else { return nil }
        itemBudget -= 1
        guard let (major, argument) = readHead() else { return nil }
        switch major {
        case 0: // unsigned int
            return .unsigned(argument)
        case 1: // negative int (argument already consumed)
            return .opaque
        case 2: // byte string
            return readBytes(count: argument) != nil ? .opaque : nil
        case 3: // text string
            guard let raw = readBytes(count: argument) else { return nil }
            return String(bytes: raw, encoding: .utf8).map(Value.text) ?? .opaque
        case 4: // array
            guard argument <= Self.maxContainerCount else { return nil }
            var items: [Value] = []
            items.reserveCapacity(Int(min(argument, 64)))
            for _ in 0..<argument {
                guard let item = parseValue(depth: depth + 1) else { return nil }
                items.append(item)
            }
            return .array(items)
        case 5: // map
            guard argument <= Self.maxContainerCount else { return nil }
            var pairs: [(Value, Value)] = []
            pairs.reserveCapacity(Int(min(argument, 64)))
            for _ in 0..<argument {
                guard let key = parseValue(depth: depth + 1),
                      let value = parseValue(depth: depth + 1) else { return nil }
                pairs.append((key, value))
            }
            return .map(pairs)
        case 6: // tag: skip the tag number, parse the tagged value
            return parseValue(depth: depth + 1)
        case 7: // simple values / floats (payload consumed by readHead)
            return .opaque
        default:
            return nil
        }
    }

    /// Reads a CBOR head byte plus its argument. Rejects indefinite lengths.
    private mutating func readHead() -> (major: UInt8, argument: UInt64)? {
        guard index < bytes.count else { return nil }
        let head = bytes[index]
        index += 1
        let major = head >> 5
        let info = head & 0x1F
        switch info {
        case 0...23:
            return (major, UInt64(info))
        case 24:
            return readUInt(width: 1).map { (major, $0) }
        case 25:
            return readUInt(width: 2).map { (major, $0) }
        case 26:
            return readUInt(width: 4).map { (major, $0) }
        case 27:
            return readUInt(width: 8).map { (major, $0) }
        default: // 28-30 reserved, 31 indefinite
            return nil
        }
    }

    private mutating func readUInt(width: Int) -> UInt64? {
        guard bytes.count - index >= width else { return nil }
        var value: UInt64 = 0
        for _ in 0..<width {
            value = (value << 8) | UInt64(bytes[index])
            index += 1
        }
        return value
    }

    private mutating func readBytes(count: UInt64) -> [UInt8]? {
        guard count <= UInt64(bytes.count - index) else { return nil }
        let length = Int(count)
        let slice = Array(bytes[index..<(index + length)])
        index += length
        return slice
    }
}

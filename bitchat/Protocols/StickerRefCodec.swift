import Foundation

/// A reference to a single sticker inside a Sonar sticker pack, carried as
/// ordinary message content.
///
/// Interop-identical to sonar-ffi's `mesh_sticker_content` /
/// `mesh_parse_sticker_content`: a ref encodes to
/// `␟sticker␟<pack-coordinate>␟<shortcode>␟<plaintext-sha256>`
/// where `␟` is ASCII Unit Separator (0x1F). The full upstream pack spec
/// lives at https://sonarprivacy.xyz/docs#SONAR-STICKERS.
struct StickerRef: Equatable, Sendable {
    /// Nostr addressable coordinate of the pack: `30031:<64 lowercase hex pubkey>:<identifier>`.
    let packCoordinate: String
    /// Sticker shortcode within the pack: 1-64 chars of `[A-Za-z0-9_]`.
    let shortcode: String
    /// Lowercase hex SHA-256 of the decrypted sticker plaintext (64 chars).
    let plaintextSha256: String

    /// Validated factory. Returns nil unless every field matches the wire
    /// shape exactly; encoding an invalid ref is not representable.
    init?(packCoordinate: String, shortcode: String, plaintextSha256: String) {
        guard StickerRef.isValidCoordinate(packCoordinate),
              StickerRef.isValidShortcode(shortcode),
              StickerRef.isValidSha256(plaintextSha256)
        else { return nil }
        self.packCoordinate = packCoordinate
        self.shortcode = shortcode
        self.plaintextSha256 = plaintextSha256
    }

    /// The wire-format message content for this ref.
    var content: String { StickerRefCodec.encode(self) }

    // MARK: - Validation helpers (reused by the pack service)

    /// `30031:<64 lowercase hex>:<identifier>` where identifier is 1-80
    /// chars of `[A-Za-z0-9._-]`.
    static func isValidCoordinate(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "30031" else { return false }
        guard isLowerHex(parts[1], count: 64) else { return false }
        let identifier = parts[2]
        guard (1...80).contains(identifier.count) else { return false }
        return identifier.allSatisfy { byte in
            byte.isASCII && (byte.isLetter || byte.isNumber || byte == "." || byte == "_" || byte == "-")
        }
    }

    /// 1-64 chars of `[A-Za-z0-9_]`.
    static func isValidShortcode(_ value: String) -> Bool {
        guard (1...64).contains(value.count) else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// Exactly 64 lowercase hex chars.
    static func isValidSha256(_ value: String) -> Bool {
        isLowerHex(Substring(value), count: 64)
    }

    private static func isLowerHex(_ value: Substring, count: Int) -> Bool {
        guard value.count == count else { return false }
        return value.allSatisfy { ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") }
    }
}

/// Pure-Swift codec for the Sonar sticker-ref wire format, byte-identical to
/// sonar-ffi's `mesh_sticker_content` / `mesh_parse_sticker_content`.
enum StickerRefCodec {
    /// ASCII Unit Separator; field delimiter and leading sentinel.
    static let separator: Character = "\u{1F}"

    /// `\u{1F}sticker\u{1F}<coordinate>\u{1F}<shortcode>\u{1F}<sha256>`
    static func encode(_ ref: StickerRef) -> String {
        "\u{1F}sticker\u{1F}\(ref.packCoordinate)\u{1F}\(ref.shortcode)\u{1F}\(ref.plaintextSha256)"
    }

    /// Parses message content into a ref. Returns nil for anything that is
    /// not exactly five `\u{1F}`-separated fields with an empty leading
    /// field, the literal tag `sticker`, and three validated fields.
    ///
    /// This parses attacker-controlled mesh content: it must never crash and
    /// must never accept a malformed ref, so old clients render the literal
    /// text instead of a bogus sticker.
    static func parse(_ content: String) -> StickerRef? {
        let parts = content.split(separator: separator, maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0].isEmpty, parts[1] == "sticker" else { return nil }
        return StickerRef(
            packCoordinate: String(parts[2]),
            shortcode: String(parts[3]),
            plaintextSha256: String(parts[4])
        )
    }
}

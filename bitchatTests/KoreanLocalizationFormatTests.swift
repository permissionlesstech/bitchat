import Foundation
import Testing

/// Regression coverage for the positional-placeholder mismatch found during
/// the Korean localization review.
struct KoreanLocalizationFormatTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let positionalObjectPlaceholder = try! NSRegularExpression(
        pattern: #"%\d+\$@"#
    )

    private static func placeholders(in value: String) -> [String] {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return positionalObjectPlaceholder.matches(in: value, range: range).compactMap { match in
            guard let tokenRange = Range(match.range, in: value) else { return nil }
            return String(value[tokenRange])
        }
    }

    @Test func locationChannelSubtitlePreservesPositionalArguments() throws {
        let catalogURL = Self.repoRoot.appendingPathComponent("bitchat/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try #require(root["strings"] as? [String: Any])
        let entry = try #require(
            strings["location_channels.subtitle_prefix"] as? [String: Any]
        )
        let localizations = try #require(entry["localizations"] as? [String: Any])

        func value(for locale: String) throws -> String {
            let localization = try #require(localizations[locale] as? [String: Any])
            let unit = try #require(localization["stringUnit"] as? [String: Any])
            return try #require(unit["value"] as? String)
        }

        let english = try value(for: "en")
        let korean = try value(for: "ko")
        let expected = ["%1$@", "%2$@"]

        #expect(Self.placeholders(in: english) == expected)
        #expect(Self.placeholders(in: korean) == expected)
    }
}

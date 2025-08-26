import XCTest
@testable import bitchat

final class LocalizationMatrixTests: XCTestCase {

    // Curated list of locales to validate. Some locales have known translations; others are seeded with English.
    private let locales: [String] = LocalizationTestUtils.locales

    // Expected values for a small set of keys where we know translations exist
    private let expected: [String: [String: String]] = LocalizationTestUtils.expected

    private func bundle(for locale: String) -> Bundle {
        if let path = Bundle.main.path(forResource: locale, ofType: "lproj"), let b = Bundle(path: path) {
            return b
        }
        if let basePath = Bundle.main.path(forResource: "Base", ofType: "lproj"), let base = Bundle(path: basePath) {
            return base
        }
        return .main
    }

    func testKeyMatrixResolvesAndMatchesWhereExpected() {
        let keys = ["nav.settings", "help.title", "accessibility.location_channels"]
        for locale in locales {
            let b = bundle(for: locale)
            for key in keys {
                let value = NSLocalizedString(key, tableName: nil, bundle: b, value: "", comment: "")
                XCTAssertFalse(value.isEmpty, "Expected non-empty for key=\(key) in locale=\(locale)")
                if let expectedLocaleMap = expected[key], let expectedValue = expectedLocaleMap[locale] {
                    XCTAssertEqual(value, expectedValue, "Mismatched translation for key=\(key) in locale=\(locale)")
                }
            }
        }
    }

    func testPluralizationSpanishAndRussian() {
        // Spanish plural via our helper
        XCTAssertEqual(Localization.plural("accessibility.people_count", count: 1, locale: "es"), "1 persona")
        XCTAssertEqual(Localization.plural("accessibility.people_count", count: 2, locale: "es"), "2 personas")

        // Russian plural (one/few/many)
        XCTAssertEqual(Localization.plural("accessibility.people_count", count: 1, locale: "ru"), "1 человек")
        XCTAssertEqual(Localization.plural("accessibility.people_count", count: 2, locale: "ru"), "2 человека")
        XCTAssertEqual(Localization.plural("accessibility.people_count", count: 5, locale: "ru"), "5 человек")
    }
}

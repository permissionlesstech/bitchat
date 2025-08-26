import XCTest
@testable import bitchat

final class LocalizationTests: XCTestCase {

    private func bundle(for locale: String) -> Bundle {
        if let path = Bundle.main.path(forResource: locale, ofType: "lproj"),
           let b = Bundle(path: path) {
            return b
        }
        // Fallback to Base if requested locale not found
        if let basePath = Bundle.main.path(forResource: "Base", ofType: "lproj"),
           let baseBundle = Bundle(path: basePath) {
            return baseBundle
        }
        return Bundle.main
    }

    func testLocalizedStringsResolveForEachLocale() {
        var locales = Bundle.main.localizations
        if !locales.contains("Base") { locales.append("Base") }
        for locale in locales {
            let b = bundle(for: locale)
            let keys = [
                "nav.settings",
                "nav.people",
                "alert.bluetooth_required",
                "actions.title"
            ]
            for key in keys {
                let value = NSLocalizedString(key, tableName: nil, bundle: b, value: "", comment: "")
                XCTAssertFalse(value.isEmpty, "Expected a localized value for \(key) in locale: \(locale)")
            }
        }
    }

    func testFallbackToBaseWhenKeyMissingInLocale() {
        // "test.baseOnly" exists only in the source language (en/Base).
        // Looking up via our helper in a non-English locale should fall back to Base value.
        let valueViaHelper = Localization.localized("test.baseOnly", locale: "es")
        XCTAssertEqual(valueViaHelper, "Base Fallback")
    }

    func testCommandMetaLocalizationResolves() {
        var locales = Bundle.main.localizations
        if !locales.contains("Base") { locales.append("Base") }
        for locale in locales {
            let b = bundle(for: locale)
            for meta in CommandRegistry.all {
                let title = NSLocalizedString(meta.titleKey, tableName: nil, bundle: b, value: "", comment: "")
                let help = NSLocalizedString(meta.helpKey, tableName: nil, bundle: b, value: "", comment: "")
                XCTAssertFalse(title.isEmpty, "Missing title for \(meta.id) in locale: \(locale)")
                XCTAssertFalse(help.isEmpty, "Missing help for \(meta.id) in locale: \(locale)")
            }
        }
    }

    func testInfoPlistStringsResolve() {
        let esBundle = bundle(for: "es")
        let esPerm = NSLocalizedString("NSBluetoothAlwaysUsageDescription", tableName: "InfoPlist", bundle: esBundle, value: "", comment: "")
        XCTAssertTrue(esPerm.contains("Bluetooth") || !esPerm.isEmpty)

        let frBundle = bundle(for: "fr")
        let frPerm = NSLocalizedString("NSBluetoothPeripheralUsageDescription", tableName: "InfoPlist", bundle: frBundle, value: "", comment: "")
        XCTAssertFalse(frPerm.isEmpty)
    }

    func testPluralizationPeopleCount() {
        // English: singular vs plural
        let oneEN = Localization.plural("accessibility.people_count", count: 1, locale: "en")
        let manyEN = Localization.plural("accessibility.people_count", count: 2, locale: "en")
        XCTAssertTrue(oneEN.contains("1") && oneEN.contains("person"))
        XCTAssertTrue(manyEN.contains("2") && manyEN.contains("people"))

        // French: personne/personnes
        let oneFR = Localization.plural("accessibility.people_count", count: 1, locale: "fr")
        let manyFR = Localization.plural("accessibility.people_count", count: 3, locale: "fr")
        XCTAssertTrue(oneFR.contains("1") && oneFR.contains("personne"))
        XCTAssertTrue(manyFR.contains("3") && manyFR.contains("personnes"))

        // Arabic/Russian: just ensure result is non-empty
        XCTAssertFalse(Localization.plural("accessibility.people_count", count: 1, locale: "ar").isEmpty)
        XCTAssertFalse(Localization.plural("accessibility.people_count", count: 5, locale: "ru").isEmpty)
    }

    func testPluralizationPartialMembersEnglish() {
        // Uses total to select singular/plural for the word 'member'
        let one = Localization.plural("delivery.partial_members", count: 1, locale: "en", 1, 1)
        let many = Localization.plural("delivery.partial_members", count: 2, locale: "en", 1, 2)
        XCTAssertTrue(one.contains("1 of 1 member"))
        XCTAssertTrue(many.contains("1 of 2 members"))
    }
}

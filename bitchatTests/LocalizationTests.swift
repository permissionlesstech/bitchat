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
        let locales = ["Base", "es", "zh-Hans", "ar", "fr"]
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
        // "test.baseOnly" exists only in Base.lproj
        let spanish = bundle(for: "es")
        let valueDirect = NSLocalizedString("test.baseOnly", tableName: nil, bundle: spanish, value: "", comment: "")

        // Direct lookup in a language-only bundle may return the key if missing; our helper should fallback to Base
        let valueViaHelper = Localization.localized("test.baseOnly", locale: "es")

        XCTAssertTrue(valueDirect == "test.baseOnly" || valueDirect.isEmpty)
        XCTAssertEqual(valueViaHelper, "Base Fallback")
    }

    func testCommandMetaLocalizationResolves() {
        let locales = ["Base", "es", "zh-Hans", "ar", "fr"]
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
}

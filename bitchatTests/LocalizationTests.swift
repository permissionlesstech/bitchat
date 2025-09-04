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
            let value = NSLocalizedString("nav.settings", tableName: nil, bundle: b, value: "", comment: "")
            XCTAssertFalse(value.isEmpty, "Expected a localized value for locale: \(locale)")
        }
    }

    func testFallbackToBaseWhenKeyMissingInLocale() {
        // In .xcstrings format, all languages have all keys with fallback to English values
        let spanish = bundle(for: "es")
        let valueDirect = NSLocalizedString("test.baseOnly", tableName: nil, bundle: spanish, value: "", comment: "")
        let valueViaHelper = Localization.localized("test.baseOnly", locale: "es")

        // Both should now return the base value since .xcstrings ensures all languages have all keys
        XCTAssertEqual(valueDirect, "Base Fallback")
        XCTAssertEqual(valueViaHelper, "Base Fallback")
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


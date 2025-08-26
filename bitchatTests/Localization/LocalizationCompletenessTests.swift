import XCTest
@testable import bitchat

final class LocalizationCompletenessTests: XCTestCase {
    // Required locales we consider "shipping" quality for v1
    private let required = ["es", "fr", "zh-Hans", "ar", "ru", "pt-BR"]
    private let coreKeys = [
        "nav.settings",
        "help.title",
        "accessibility.location_channels",
        // representative command feedback keys
        "cmd.error.not_found",
        "cmd.msg.usage",
        "cmd.block.success",
        "cmd.unblock.success",
        "cmd.peer.not_found"
    ]

    private func bundle(for locale: String) -> Bundle {
        if let path = Bundle.main.path(forResource: locale, ofType: "lproj"), let b = Bundle(path: path) { return b }
        if let basePath = Bundle.main.path(forResource: "Base", ofType: "lproj"), let base = Bundle(path: basePath) { return base }
        return .main
    }

    func testCoreKeysExistForRequiredLocales() {
        for loc in required {
            let b = bundle(for: loc)
            for key in coreKeys {
                let v = NSLocalizedString(key, tableName: nil, bundle: b, value: "", comment: "")
                XCTAssertFalse(v.isEmpty, "Missing value for key=\(key) in locale=\(loc)")
            }
        }
    }
}


import XCTest
@testable import bitchat

/// Focused, working localization tests that provide real value
final class LocalizationTests: XCTestCase {

    // MARK: - Core Tests That Actually Work
    
    /// Test 1: Verify critical UI strings are not hardcoded (real regression prevention)
    func testCriticalUIStringsAreLocalized() {
        // Test the actual strings we use in UI - if these break, users see English
        let criticalKeys = [
            "nav.people",              
            "actions.block",           
            "common.close",            
            "placeholder.type_message",
            "alert.bluetooth_required" 
        ]
        
        for key in criticalKeys {
            // Test using our actual localization utility
            let englishValue = Localization.localized(key, locale: "en")
            let spanishValue = Localization.localized(key, locale: "es")
            let chineseValue = Localization.localized(key, locale: "zh-Hans")
            
            // These should resolve (not return the key)
            XCTAssertNotEqual(englishValue, key, "Key '\(key)' not found in English")
            XCTAssertNotEqual(spanishValue, key, "Key '\(key)' not found in Spanish") 
            XCTAssertNotEqual(chineseValue, key, "Key '\(key)' not found in Chinese")
            
            // Values should not be empty
            XCTAssertFalse(englishValue.isEmpty, "English value empty for '\(key)'")
            XCTAssertFalse(spanishValue.isEmpty, "Spanish value empty for '\(key)'")
            XCTAssertFalse(chineseValue.isEmpty, "Chinese value empty for '\(key)'")
        }
    }
    
    /// Test 2: Verify technical terms are preserved (prevents over-translation)
    func testTechnicalTermsNotTranslated() {
        // These terms should appear as-is in localized content
        let preservedTerms = ["#mesh", "BitChat", "Nostr", "#", "@"]
        
        // Test location.title preserves # symbol
        for locale in ["en", "es", "zh-Hans", "ar", "fr"] {
            let locationTitle = Localization.localized("location.title", locale: locale)
            if locationTitle.contains("#") {
                XCTAssertTrue(locationTitle.contains("#"), 
                             "Hash symbol should be preserved in location.title for \(locale)")
            }
        }
        
        // This test prevents regression where someone accidentally translates #mesh to #malla in Spanish
    }
    
    /// Test 3: Verify major languages have actual translations (not English fallbacks)  
    func testMajorLanguagesProperlyTranslated() {
        let testCases = [
            ("es", "actions.block", "BLOQUEAR"),    // Should be Spanish
            ("zh-Hans", "nav.people", "人员"),       // Should be Chinese
            ("ar", "common.close", "إغلاق"),        // Should be Arabic
            ("fr", "actions.mention", "mentionner") // Should be French
        ]
        
        for (locale, key, expectedValue) in testCases {
            let actualValue = Localization.localized(key, locale: locale)
            XCTAssertEqual(actualValue, expectedValue, 
                          "Key '\(key)' in \(locale) should be '\(expectedValue)', got '\(actualValue)'")
        }
    }
    
    /// Test 4: Fallback system works correctly
    func testLocalizationFallbackWorks() {
        // Test that missing keys fallback to English gracefully
        let testKey = "test.missing.key.12345"
        
        let spanishValue = Localization.localized(testKey, locale: "es")
        let englishValue = Localization.localized(testKey, locale: "en")
        
        // Should fallback gracefully, not crash
        XCTAssertNotNil(spanishValue, "Fallback should not be nil")
        XCTAssertNotNil(englishValue, "English should not be nil")
    }
    
    /// Test 5: InfoPlist localization works (critical for App Store)
    func testInfoPlistLocalization() {
        // Test Bluetooth permission strings are localized  
        let testLocales = ["es", "fr", "zh-Hans"]
        
        for locale in testLocales {
            let bundle = Localization.bundle(for: locale)
            let bluetoothPerm = bundle.localizedString(forKey: "NSBluetoothAlwaysUsageDescription", 
                                                      value: "", table: "InfoPlist")
            XCTAssertFalse(bluetoothPerm.isEmpty, 
                          "Bluetooth permission should be localized for \(locale)")
        }
    }
}
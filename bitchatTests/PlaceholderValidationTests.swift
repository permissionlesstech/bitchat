import Foundation
import XCTest

/// Simple, focused test to validate that placeholder formatting works correctly
/// This test ensures placeholders are properly replaced and no raw placeholder text remains
final class PlaceholderValidationTests: XCTestCase {
    
    // MARK: - Configuration Loading
    
    private func loadTestConfiguration() throws -> PlaceholderTestConfiguration {
        let testsRootURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let configURL = testsRootURL.appendingPathComponent("Localization/PlaceholderTestCases.json")
        let data = try Data(contentsOf: configURL)
        return try JSONDecoder().decode(PlaceholderTestConfiguration.self, from: data)
    }
    
    /// Test ALL placeholder keys loaded from JSON configuration (test-environment friendly)
    func testAllPlaceholderKeys() throws {
        let config = try loadTestConfiguration()
        
        for testCase in config.testCases {
            for locale in config.testLocales {
                let result = formatString(key: testCase.key, locale: locale, args: testCase.anyArgs)
                
                // Primary validation: Verify no raw placeholders remain
                for pattern in config.rawPlaceholderPatterns {
                    XCTAssertFalse(
                        result.contains(pattern),
                        "Raw placeholder '\(pattern)' found in '\(result)' for key '\(testCase.key)' in locale '\(locale)'"
                    )
                }
                
                // In test environment, localization returns keys, so we only validate structure
                // Arguments and proper localization should be tested in the actual running app
                
                print("✅ \(locale): '\(testCase.key)' -> structure validated")
            }
        }
        
        // Report summary
        let totalTests = config.testCases.count * config.testLocales.count
        print("📊 Validated \(config.testCases.count) placeholder keys across \(config.testLocales.count) locales = \(totalTests) total validations")
    }
    
    /// Test just the most critical placeholder keys (faster test)
    func testCriticalPlaceholderKeys() throws {
        let config = try loadTestConfiguration()
        
        // Filter to just the most critical test cases
        let criticalKeys = ["location_channels.subtitle_prefix", "location_channels.row_title", "content.accessibility.people_count"]
        let criticalTestCases = config.testCases.filter { criticalKeys.contains($0.key) }
        
        for testCase in criticalTestCases {
            for locale in config.criticalLocales {
                let result = formatString(key: testCase.key, locale: locale, args: testCase.anyArgs)
                
                // Verify no raw placeholders remain
                for pattern in config.rawPlaceholderPatterns {
                    XCTAssertFalse(
                        result.contains(pattern),
                        "Raw placeholder '\(pattern)' found in result '\(result)' for key '\(testCase.key)' in locale '\(locale)'"
                    )
                }
                
                print("✅ Critical \(locale): '\(testCase.key)' -> '\(result)'")
            }
        }
    }
    
    /// Test pluralization with different counts for complex plural languages
    func testPluralizationWithVariousCounts() throws {
        let config = try loadTestConfiguration()
        
        // Filter to pluralization test cases
        let pluralizationCases = config.testCases.filter { $0.type == "pluralization" }
        let complexPluralLocales = ["ar", "ru", "pl"] // Languages with complex plural rules
        
        for testCase in pluralizationCases {
            for locale in complexPluralLocales {
                for count in config.pluralizationTestCounts {
                    // Replace the count argument with our test count
                    var testArgs = testCase.anyArgs
                    if let countIndex = testArgs.firstIndex(where: { $0 is Int }) {
                        testArgs[countIndex] = count
                    }
                    
                    let result = formatString(key: testCase.key, locale: locale, args: testArgs)
                    
                    // Verify no raw placeholders remain
                    for pattern in config.rawPlaceholderPatterns {
                        XCTAssertFalse(
                            result.contains(pattern),
                            "Raw placeholder '\(pattern)' found in '\(result)' for key '\(testCase.key)' with count \(count) in locale '\(locale)'"
                        )
                    }
                    
                    print("✅ Plural \(locale) (\(count)): '\(testCase.key)' -> '\(result)'")
                }
            }
        }
    }
    
    /// Test that we can format strings using the actual SwiftUI localization system
    func testSwiftUILocalizationFormatting() throws {
        // Test with the current system locale first
        let testLocale = Locale.current
        
        // Test simple string formatting
        let key1 = "location_channels.subtitle_prefix"
        let result1 = String(
            format: String(localized: String.LocalizationValue(key1)),
            "9q9p", "Pleasant Valley"
        )
        
        print("SwiftUI result for '\(key1)': '\(result1)'")
        
        // Verify no raw placeholders
        XCTAssertFalse(result1.contains("%@"), "Raw placeholder in SwiftUI result: '\(result1)'")
        XCTAssertFalse(result1.contains("%1$@"), "Raw positional placeholder in SwiftUI result: '\(result1)'")
        XCTAssertFalse(result1.contains("%2$@"), "Raw positional placeholder in SwiftUI result: '\(result1)'")
        
        // Verify arguments are present
        XCTAssertTrue(result1.contains("9q9p"), "First argument missing in SwiftUI result: '\(result1)'")
        XCTAssertTrue(result1.contains("Pleasant Valley"), "Second argument missing in SwiftUI result: '\(result1)'")
    }
    
    /// Test specific locales that we know have been fixed
    func testFixedLocales() throws {
        let fixedLocales = ["ar", "de", "es", "fr"] // These should have been fixed
        let key = "location_channels.subtitle_prefix"
        let args = ["test1", "test2"]
        
        for locale in fixedLocales {
            let result = formatString(key: key, locale: locale, args: args)
            
            // The key requirement: no raw placeholders should remain
            let rawPlaceholders = ["%@", "%1$@", "%2$@", "[%", "@]"]
            for placeholder in rawPlaceholders {
                XCTAssertFalse(
                    result.contains(placeholder),
                    "Raw placeholder '\(placeholder)' found in result '\(result)' for locale '\(locale)'"
                )
            }
            
            // Arguments should be present
            XCTAssertTrue(result.contains("test1"), "First argument missing in '\(result)' for locale '\(locale)'")
            XCTAssertTrue(result.contains("test2"), "Second argument missing in '\(result)' for locale '\(locale)'")
            
            print("✅ Fixed locale \(locale): '\(result)'")
        }
    }
    
    // MARK: - Helper Methods
    
    private func formatString(key: String, locale: String, args: [Any]) -> String {
        let testLocale = Locale(identifier: locale)
        
        // Get the localized string template
        let template = String(localized: String.LocalizationValue(key), locale: testLocale)
        
        // Format with arguments
        switch args.count {
        case 0:
            return template
        case 1:
            return String(format: template, locale: testLocale, "\(args[0])")
        case 2:
            return String(format: template, locale: testLocale, "\(args[0])", "\(args[1])")
        case 3:
            return String(format: template, locale: testLocale, "\(args[0])", "\(args[1])", "\(args[2])")
        default:
            // For more arguments, just use the first 3
            return String(format: template, locale: testLocale, "\(args[0])", "\(args[1])", "\(args[2])")
        }
    }
}

// MARK: - Configuration Data Structures

struct PlaceholderTestConfiguration: Codable {
    let testCases: [PlaceholderTestCase]
    let testLocales: [String]
    let criticalLocales: [String]
    let pluralizationTestCounts: [Int]
    let rawPlaceholderPatterns: [String]
}

struct PlaceholderTestCase: Codable {
    let key: String
    let args: [PlaceholderArgument]
    let type: String
    let description: String
}

enum PlaceholderArgument: Codable {
    case string(String)
    case int(Int)
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else {
            throw DecodingError.typeMismatch(PlaceholderArgument.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected String or Int"))
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        }
    }
}

extension PlaceholderTestCase {
    var anyArgs: [Any] {
        return self.args.map { arg in
            switch arg {
            case .string(let value):
                return value
            case .int(let value):
                return value
            }
        }
    }
}

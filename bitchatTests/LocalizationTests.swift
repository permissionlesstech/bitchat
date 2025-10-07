//
// LocalizationTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
import Foundation
@testable import bitchat

/// Comprehensive localization tests for bitchat.
/// Validates configuration integrity, structural consistency, content quality, and format consistency.
final class LocalizationTests: XCTestCase {
    
    // MARK: - Instance Variables
    
    private let testsDirectoryURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    private let repoRootURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    
    /// Path to the main app's localization catalog
    private let appCatalogPath = "bitchat/Localizable.xcstrings"
    
    /// Path to the share extension's localization catalog
    private let shareExtCatalogPath = "bitchatShareExtension/Localization/Localizable.xcstrings"
    
    // MARK: - Configuration Validation
    
    /// Tests that configured keys actually exist in their respective catalogs.
    func testConfiguredKeysExistInCatalogs() throws {
        let appCatalog = try loadCatalog(relativePath: appCatalogPath, repoRootURL: repoRootURL)
        let shareExtCatalog = try loadCatalog(relativePath: shareExtCatalogPath, repoRootURL: repoRootURL)
        let config = try loadConfig(testsDirectoryURL: testsDirectoryURL)
        
        // Verify all required app keys exist in app catalog
        let allAppKeys = getAllAppKeys(from: config)
        for key in allAppKeys {
            XCTAssertTrue(appCatalog.strings.keys.contains(key), 
                         "Configured app key '\(key)' not found in app catalog")
        }
        
        // Verify all required share extension keys exist in share extension catalog
        let allShareKeys = getAllShareExtensionKeys(from: config)
        for key in allShareKeys {
            XCTAssertTrue(shareExtCatalog.strings.keys.contains(key), 
                         "Configured share extension key '\(key)' not found in share extension catalog")
        }
    }
    
    /// Tests that expected values reference valid keys and locales.
    func testExpectedValuesConfiguration() throws {
        let appCatalog = try loadCatalog(relativePath: appCatalogPath, repoRootURL: repoRootURL)
        let shareExtCatalog = try loadCatalog(relativePath: shareExtCatalogPath, repoRootURL: repoRootURL)
        let config = try loadConfig(testsDirectoryURL: testsDirectoryURL)
        
        for (locale, localeConfig) in config.testLocales {
            guard localeConfig.enabled else { continue }
            
            for (key, expectedValue) in localeConfig.assertValues {
                // Key should exist in either app or share extension
                let keyExistsInApp = appCatalog.strings.keys.contains(key)
                let keyExistsInShare = shareExtCatalog.strings.keys.contains(key)
                
                XCTAssertTrue(keyExistsInApp || keyExistsInShare, 
                             "Expected value key '\(key)' for locale '\(locale)' not found in any catalog")
                
                // Expected value should not be empty
                XCTAssertFalse(expectedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, 
                              "Expected value for key '\(key)' in locale '\(locale)' should not be empty")
            }
        }
    }
    
    // MARK: - Structure Validation
    
    /// Ensures every locale includes exactly the same keys as base locale.
    func testCatalogLocaleParity() throws {
        // Test app catalog
        let appContext = try loadContextWithKeys(relativePath: appCatalogPath, repoRootURL: repoRootURL)
        assertLocaleParity(context: appContext, catalogName: "App")
        
        // Test share extension catalog
        let shareExtContext = try loadContextWithKeys(relativePath: shareExtCatalogPath, repoRootURL: repoRootURL)
        assertLocaleParity(context: shareExtContext, catalogName: "ShareExtension")
    }
    
    /// Validates that enabled locales have translated state for all required keys.
    func testEnabledLocalesHaveTranslations() throws {
        let appCatalog = try loadCatalog(relativePath: appCatalogPath, repoRootURL: repoRootURL)
        let shareExtCatalog = try loadCatalog(relativePath: shareExtCatalogPath, repoRootURL: repoRootURL)
        let config = try loadConfig(testsDirectoryURL: testsDirectoryURL)
        
        let enabledLocales = getEnabledTestLocales(from: config)
        
        for locale in enabledLocales {
            // Skip base locale as it's the source
            if locale == appCatalog.sourceLanguage { continue }
            
            // Check app required keys have translated state
            let allAppKeys = getAllAppKeys(from: config)
            for key in allAppKeys {
                guard let entry = appCatalog.strings[key],
                      let localization = entry.localizations[locale],
                      let unit = localization.stringUnit else {
                    XCTFail("Required app key '\(key)' missing localization for enabled locale '\(locale)'")
                    continue
                }
                
                XCTAssertEqual(unit.state, "translated", 
                              "Required app key '\(key)' not marked as translated in enabled locale '\(locale)' (state: '\(unit.state)')")
            }
            
            // Check share extension required keys have translated state
            let allShareKeys = getAllShareExtensionKeys(from: config)
            for key in allShareKeys {
                guard let entry = shareExtCatalog.strings[key],
                      let localization = entry.localizations[locale],
                      let unit = localization.stringUnit else {
                    XCTFail("Required share extension key '\(key)' missing localization for enabled locale '\(locale)'")
                    continue
                }
                
                XCTAssertEqual(unit.state, "translated", 
                              "Required share extension key '\(key)' not marked as translated in enabled locale '\(locale)' (state: '\(unit.state)')")
            }
        }
    }
    
    /// Validates that configured test locales are present and complete in both catalogs.
    func testConfiguredLocalesCompleteness() throws {
        let appContext = try loadContextWithKeys(relativePath: appCatalogPath, repoRootURL: repoRootURL)
        let shareExtContext = try loadContextWithKeys(relativePath: shareExtCatalogPath, repoRootURL: repoRootURL)
        let config = try loadConfig(testsDirectoryURL: testsDirectoryURL)
        
        let enabledLocales = getEnabledTestLocales(from: config)
        let baseLocale = appContext.baseLocale
        let baseAppKeys = appContext.keysByLocale?[baseLocale] ?? Set()
        let baseShareKeys = shareExtContext.keysByLocale?[baseLocale] ?? Set()
        
        for locale in enabledLocales {
            // Skip base locale comparison with itself
            if locale == baseLocale { continue }
            
            // Verify locale is present in both catalogs
            XCTAssertTrue(appContext.locales.contains(locale), 
                         "Locale '\(locale)' missing from app catalog")
            XCTAssertTrue(shareExtContext.locales.contains(locale), 
                         "Locale '\(locale)' missing from share extension catalog")
            
            // Verify locale has same number of keys as base locale
            let appLocaleKeys = appContext.keysByLocale?[locale] ?? Set()
            XCTAssertEqual(appLocaleKeys.count, baseAppKeys.count, 
                          "Locale '\(locale)' app catalog missing keys compared to \(baseLocale)")
            
            let shareLocaleKeys = shareExtContext.keysByLocale?[locale] ?? Set()
            XCTAssertEqual(shareLocaleKeys.count, baseShareKeys.count, 
                          "Locale '\(locale)' share extension catalog missing keys compared to \(baseLocale)")
        }
    }
    
    // MARK: - Content Validation
    
    /// Guards required strings from going empty per enabled locale.
    func testRequiredKeysNonEmpty() throws {
        let config = try loadConfig(testsDirectoryURL: testsDirectoryURL)
        let enabledLocales = getEnabledTestLocales(from: config)
        
        // Test app required keys
        let appContext = try loadContext(relativePath: appCatalogPath, repoRootURL: repoRootURL)
        let allAppKeys = getAllAppKeys(from: config)
        assertRequiredKeysPresent(context: appContext, keys: allAppKeys, 
                                enabledLocales: enabledLocales, catalogName: "App")
        
        // Test share extension required keys
        let shareExtContext = try loadContext(relativePath: shareExtCatalogPath, repoRootURL: repoRootURL)
        let allShareKeys = getAllShareExtensionKeys(from: config)
        assertRequiredKeysPresent(context: shareExtContext, keys: allShareKeys, 
                                enabledLocales: enabledLocales, catalogName: "ShareExtension")
    }
    
    /// Validates that configured locales contain expected string values.
    func testLocalizationExpectedValues() throws {
        let appContext = try loadContext(relativePath: appCatalogPath, repoRootURL: repoRootURL)
        let shareExtContext = try loadContext(relativePath: shareExtCatalogPath, repoRootURL: repoRootURL)
        let config = try loadConfig(testsDirectoryURL: testsDirectoryURL)
        
        let enabledLocales = getEnabledTestLocales(from: config)
        
        for locale in enabledLocales {
            guard let localeConfig = config.testLocales[locale],
                  !localeConfig.assertValues.isEmpty else {
                continue // Skip locales with no expected values configured
            }
            
            // Test each expected key/value pair for this locale
            let allAppKeys = getAllAppKeys(from: config)
            let allShareKeys = getAllShareExtensionKeys(from: config)
            
            for (key, expectedValue) in localeConfig.assertValues {
                if allAppKeys.contains(key) {
                    assertLocaleStringValue(context: appContext, locale: locale, 
                                          key: key, expectedValue: expectedValue, 
                                          catalogName: "App")
                } else if allShareKeys.contains(key) {
                    assertLocaleStringValue(context: shareExtContext, locale: locale, 
                                          key: key, expectedValue: expectedValue, 
                                          catalogName: "ShareExtension")
                }
            }
        }
    }
    
    // MARK: - Format Validation
    
    /// Verifies format placeholders stay consistent across locales for required keys.
    func testPlaceholderConsistency() throws {
        let config = try loadConfig(testsDirectoryURL: testsDirectoryURL)
        let enabledLocales = getEnabledTestLocales(from: config)
        
        // Test app catalog placeholder consistency
        let appContext = try loadContextWithPlaceholders(relativePath: appCatalogPath, repoRootURL: repoRootURL)
        let allAppKeys = getAllAppKeys(from: config)
        assertPlaceholderConsistencyForKeys(context: appContext, keys: allAppKeys, 
                                          enabledLocales: enabledLocales, catalogName: "App")
        
        // Test share extension catalog placeholder consistency
        let shareExtContext = try loadContextWithPlaceholders(relativePath: shareExtCatalogPath, repoRootURL: repoRootURL)
        let allShareKeys = getAllShareExtensionKeys(from: config)
        assertPlaceholderConsistencyForKeys(context: shareExtContext, keys: allShareKeys, 
                                          enabledLocales: enabledLocales, catalogName: "ShareExtension")
    }
    
    // MARK: - Private Assertion Helpers
    
    private func assertLocaleParity(context: CatalogContext, catalogName: String, 
                                   file: StaticString = #filePath, line: UInt = #line) {
        let baseLocale = context.baseLocale
        guard let keysByLocale = context.keysByLocale,
              let baseKeys = keysByLocale[baseLocale] else {
            return XCTFail("Missing base locale \(baseLocale) in \(catalogName) catalog", 
                          file: file, line: line)
        }

        for (locale, keys) in keysByLocale.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(keys, baseKeys, 
                          "Locale \(locale) has key mismatch in \(catalogName) catalog", 
                          file: file, line: line)
        }
    }
    
    private func assertRequiredKeysPresent(context: CatalogContext, keys: [String], 
                                         enabledLocales: [String], catalogName: String, 
                                         file: StaticString = #filePath, line: UInt = #line) {
        for key in keys {
            guard let entry = context.catalog.strings[key] else {
                XCTFail("Missing required key \(key) in \(catalogName) catalog", 
                       file: file, line: line)
                continue
            }
            
            // Only test enabled locales
            for locale in enabledLocales.sorted() {
                guard let localization = entry.localizations[locale], 
                      let unit = localization.stringUnit else {
                    XCTFail("Missing localization for key \(key) in enabled locale \(locale) (\(catalogName))", 
                           file: file, line: line)
                    continue
                }
                
                let segments = gatherSegments(from: unit)
                XCTAssertFalse(segments.isEmpty, 
                              "No content for key \(key) in enabled locale \(locale) (\(catalogName))", 
                              file: file, line: line)
                
                for segment in segments {
                    let trimmed = segment.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    XCTAssertFalse(trimmed.isEmpty, 
                                  "Empty translation for key \(key) at \(segment.path) in enabled locale \(locale) (\(catalogName))", 
                                  file: file, line: line)
                }
            }
        }
    }
    
    private func assertLocaleStringValue(context: CatalogContext, locale: String, key: String, 
                                        expectedValue: String, catalogName: String, 
                                        file: StaticString = #filePath, line: UInt = #line) {
        guard let entry = context.catalog.strings[key] else {
            XCTFail("Missing key \(key) in \(catalogName) catalog", file: file, line: line)
            return
        }
        
        guard let localization = entry.localizations[locale], 
              let unit = localization.stringUnit else {
            XCTFail("Missing \(locale) localization for key \(key) in \(catalogName) catalog", 
                   file: file, line: line)
            return
        }
        
        // For simple strings (non-pluralized)
        if let actualValue = unit.value {
            XCTAssertEqual(actualValue, expectedValue, 
                          "\(locale) translation mismatch for key \(key) in \(catalogName) catalog. Expected: '\(expectedValue)', Actual: '\(actualValue)'", 
                          file: file, line: line)
        } else {
            XCTFail("Key \(key) has no value in \(locale) localization for \(catalogName) catalog", 
                   file: file, line: line)
        }
    }
    
    private func assertPlaceholderConsistencyForKeys(context: CatalogContext, keys: [String], 
                                                   enabledLocales: [String], catalogName: String, 
                                                   file: StaticString = #filePath, line: UInt = #line) {
        let baseLocale = context.baseLocale
        guard let placeholderSignature = context.placeholderSignature,
              let baseSignatures = placeholderSignature[baseLocale] else {
            return XCTFail("Missing base placeholder signature for \(catalogName)", 
                          file: file, line: line)
        }

        for (locale, localeSignatures) in placeholderSignature.sorted(by: { $0.key < $1.key }) {
            guard locale != baseLocale else { continue }
            guard enabledLocales.contains(locale) else { continue } // Only test enabled locales
            
            // Only check required keys
            for key in keys.sorted() {
                guard let baseMap = baseSignatures[key] else { continue }
                guard let localeMap = localeSignatures[key] else {
                    return XCTFail("Key \(key) missing for locale \(locale) in \(catalogName) catalog", 
                                  file: file, line: line)
                }
                
                for path in baseMap.keys.sorted() {
                    let expected = normalizedPlaceholders(baseMap[path, default: []])
                    let actual = normalizedPlaceholders(localeMap[path, default: []])
                    XCTAssertEqual(actual, expected, 
                                  "Placeholder mismatch for key \(key) at \(path) in locale \(locale) (\(catalogName))", 
                                  file: file, line: line)
                }
            }
        }
    }
}
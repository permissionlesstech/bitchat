//
// LocalizationTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import bitchat

/// Comprehensive localization tests for bitchat.
/// Validates configuration integrity, structural consistency, content quality, and format consistency.
/// 
@Suite
struct LocalizationTests {
    
    // MARK: - Static Configuration Loading
    
    private static let testsDirectoryURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    private static let repoRootURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    
    /// Dynamically loaded enabled locales from configuration
    private static let enabledLocales: [String] = {
        do {
            let config = try loadConfig(testsDirectoryURL: testsDirectoryURL)
            return getEnabledTestLocales(from: config)
        } catch {
            // Log the error for debugging while providing graceful fallback
            print("⚠️ Failed to load localization config: \(error). Falling back to [\"en\"]")
            return ["en"]
        }
    }()
    
    /// Cached configuration for reuse across tests
    private static let testConfig: LocalizationTestConfig = {
        do {
            return try loadConfig(testsDirectoryURL: testsDirectoryURL)
        } catch {
            // Fail fast with clear context - localization config is critical for proper test coverage
            fatalError("""
                ❌ LOCALIZATION CONFIG MISSING ❌
                
                Error: \(error)
                
                Expected: \(testsDirectoryURL.appendingPathComponent("LocalizationTestsConfig.json"))
                
                This file is required for comprehensive localization testing across all supported locales.
                Without it, we cannot validate translations, placeholder consistency, or locale completeness.
                
                To fix: Ensure LocalizationTestsConfig.json exists in bitchatTests/ directory.
                """)
        }
    }()
    
    // MARK: - Instance Variables
    
    private let testsDirectoryURL = Self.testsDirectoryURL
    private let repoRootURL = Self.repoRootURL
    
    /// Path to the main app's localization catalog
    private let appCatalogPath = "bitchat/Localizable.xcstrings"
    
    /// Path to the share extension's localization catalog
    private let shareExtCatalogPath = "bitchatShareExtension/Localization/Localizable.xcstrings"
    
    // MARK: - Configuration Validation
    
    /// Tests that configured keys actually exist in their respective catalogs.
    @Test func configuredKeysExistInCatalogs() throws {
        let appCatalog = try loadCatalog(relativePath: appCatalogPath, repoRootURL: repoRootURL)
        let shareExtCatalog = try loadCatalog(relativePath: shareExtCatalogPath, repoRootURL: repoRootURL)
        let config = Self.testConfig
        
        // Verify all required app keys exist in app catalog
        let allAppKeys = getAllAppKeys(from: config)
        for key in allAppKeys {
            #expect(appCatalog.strings.keys.contains(key), 
                   "Configured app key '\(key)' not found in app catalog")
        }
        
        // Verify all required share extension keys exist in share extension catalog
        let allShareKeys = getAllShareExtensionKeys(from: config)
        for key in allShareKeys {
            #expect(shareExtCatalog.strings.keys.contains(key), 
                   "Configured share extension key '\(key)' not found in share extension catalog")
        }
    }
    
    /// Tests that expected values reference valid keys and locales.
    @Test func expectedValuesConfiguration() throws {
        let appCatalog = try loadCatalog(relativePath: appCatalogPath, repoRootURL: repoRootURL)
        let shareExtCatalog = try loadCatalog(relativePath: shareExtCatalogPath, repoRootURL: repoRootURL)
        let config = Self.testConfig
        
        for (locale, localeConfig) in config.testLocales {
            guard localeConfig.enabled else { continue }
            
            for (key, expectedValue) in localeConfig.assertValues {
                // Key should exist in either app or share extension
                let keyExistsInApp = appCatalog.strings.keys.contains(key)
                let keyExistsInShare = shareExtCatalog.strings.keys.contains(key)
                
                #expect(keyExistsInApp || keyExistsInShare, 
                       "Expected value key '\(key)' for locale '\(locale)' not found in any catalog")
                
                // Expected value should not be empty
                #expect(!expectedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, 
                       "Expected value for key '\(key)' in locale '\(locale)' should not be empty")
            }
        }
    }
    
    // MARK: - Structure Validation
    
    /// Ensures every locale includes exactly the same keys as base locale.
    @Test func catalogLocaleParity() throws {
        // Test app catalog
        let appContext = try loadContextWithKeys(relativePath: appCatalogPath, repoRootURL: repoRootURL)
        assertLocaleParity(context: appContext, catalogName: "App")
        
        // Test share extension catalog
        let shareExtContext = try loadContextWithKeys(relativePath: shareExtCatalogPath, repoRootURL: repoRootURL)
        assertLocaleParity(context: shareExtContext, catalogName: "ShareExtension")
    }
    
    /// Validates that a specific enabled locale has complete translations.
    @Test("Locale completeness", arguments: enabledLocales)
    func localeCompleteness(locale: String) throws {
        let appContext = try loadContextWithKeys(relativePath: appCatalogPath, repoRootURL: repoRootURL)
        let shareExtContext = try loadContextWithKeys(relativePath: shareExtCatalogPath, repoRootURL: repoRootURL)
        
        let baseLocale = appContext.baseLocale
        let baseAppKeys = appContext.keysByLocale?[baseLocale] ?? Set()
        let baseShareKeys = shareExtContext.keysByLocale?[baseLocale] ?? Set()
        
        // Skip base locale comparison with itself
        if locale == baseLocale { return }
        
        // Verify locale is present in both catalogs
        #expect(appContext.locales.contains(locale), 
               "Locale '\(locale)' missing from app catalog")
        #expect(shareExtContext.locales.contains(locale), 
               "Locale '\(locale)' missing from share extension catalog")
        
        // Verify locale has same number of keys as base locale
        let appLocaleKeys = appContext.keysByLocale?[locale] ?? Set()
        #expect(appLocaleKeys.count == baseAppKeys.count, 
               "Locale '\(locale)' app catalog missing keys compared to \(baseLocale)")
        
        let shareLocaleKeys = shareExtContext.keysByLocale?[locale] ?? Set()
        #expect(shareLocaleKeys.count == baseShareKeys.count, 
               "Locale '\(locale)' share extension catalog missing keys compared to \(baseLocale)")
    }
    
    /// Validates that a specific enabled locale has translated state for all required keys.
    @Test("Locale translation state", arguments: enabledLocales)
    func localeTranslationState(locale: String) throws {
        let appCatalog = try loadCatalog(relativePath: appCatalogPath, repoRootURL: repoRootURL)
        let shareExtCatalog = try loadCatalog(relativePath: shareExtCatalogPath, repoRootURL: repoRootURL)
        let config = Self.testConfig
        
        // Skip base locale as it's the source
        if locale == appCatalog.sourceLanguage { return }
        
        // Check app required keys have translated state
        let allAppKeys = getAllAppKeys(from: config)
        for key in allAppKeys {
            guard let entry = appCatalog.strings[key],
                  let localization = entry.localizations[locale],
                  let unit = localization.stringUnit else {
                Issue.record("Required app key '\(key)' missing localization for enabled locale '\(locale)'")
                continue
            }
            
            #expect(unit.state == "translated", 
                   "Required app key '\(key)' not marked as translated in enabled locale '\(locale)' (state: '\(unit.state)')")
        }
        
        // Check share extension required keys have translated state
        let allShareKeys = getAllShareExtensionKeys(from: config)
        for key in allShareKeys {
            guard let entry = shareExtCatalog.strings[key],
                  let localization = entry.localizations[locale],
                  let unit = localization.stringUnit else {
                Issue.record("Required share extension key '\(key)' missing localization for enabled locale '\(locale)'")
                continue
            }
            
            #expect(unit.state == "translated", 
                   "Required share extension key '\(key)' not marked as translated in enabled locale '\(locale)' (state: '\(unit.state)')")
        }
    }
    
    
    // MARK: - Content Validation
    
    /// Guards required strings from going empty per enabled locale.
    @Test func requiredKeysNonEmpty() throws {
        let config = Self.testConfig
        let enabledLocales = Self.enabledLocales
        
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
    
    /// Validates that a specific locale contains expected string values.
    @Test("Locale expected values", arguments: enabledLocales)
    func localeExpectedValues(locale: String) throws {
        let appContext = try loadContext(relativePath: appCatalogPath, repoRootURL: repoRootURL)
        let shareExtContext = try loadContext(relativePath: shareExtCatalogPath, repoRootURL: repoRootURL)
        let config = Self.testConfig
        
        guard let localeConfig = config.testLocales[locale],
              !localeConfig.assertValues.isEmpty else {
            return // Skip locales with no expected values configured
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
    
    
    // MARK: - Format Validation
    
    /// Verifies format placeholders stay consistent across locales for required keys.
    @Test func placeholderConsistency() throws {
        let config = Self.testConfig
        let enabledLocales = Self.enabledLocales
        
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
    
    /// Validates that a specific locale has consistent placeholders with the base locale.
    @Test("Locale placeholder consistency", arguments: enabledLocales)
    func localePlaceholderConsistency(locale: String) throws {
        let config = Self.testConfig
        
        // Test app catalog placeholder consistency for this locale
        let appContext = try loadContextWithPlaceholders(relativePath: appCatalogPath, repoRootURL: repoRootURL)
        let allAppKeys = getAllAppKeys(from: config)
        assertPlaceholderConsistencyForKeys(context: appContext, keys: allAppKeys, 
                                          enabledLocales: [locale], catalogName: "App")
        
        // Test share extension catalog placeholder consistency for this locale
        let shareExtContext = try loadContextWithPlaceholders(relativePath: shareExtCatalogPath, repoRootURL: repoRootURL)
        let allShareKeys = getAllShareExtensionKeys(from: config)
        assertPlaceholderConsistencyForKeys(context: shareExtContext, keys: allShareKeys, 
                                          enabledLocales: [locale], catalogName: "ShareExtension")
    }
    
    // MARK: - Test Coverage Validation
    
    /// Ensures all configured enabled locales are covered by parameterized tests.
    @Test func allConfiguredLocalesAreTested() throws {
        let config = Self.testConfig
        let configuredEnabledLocales = Set(getEnabledTestLocales(from: config))
        let testedLocales = Set(Self.enabledLocales)
        
        #expect(configuredEnabledLocales == testedLocales, 
               "Mismatch between configured enabled locales and tested locales. Configured: \(configuredEnabledLocales.sorted()), Tested: \(testedLocales.sorted())")
        
        // Verify we have a reasonable number of locales
        #expect(testedLocales.count >= 1, 
               "Should have at least one enabled locale for testing")
        
        // Verify base locale is included
        let appCatalog = try loadCatalog(relativePath: appCatalogPath, repoRootURL: repoRootURL)
        #expect(testedLocales.contains(appCatalog.sourceLanguage), 
               "Base locale '\(appCatalog.sourceLanguage)' should be included in enabled locales")
    }
    
    // MARK: - Private Assertion Helpers
    
    private func assertLocaleParity(context: CatalogContext, catalogName: String) {
        let baseLocale = context.baseLocale
        guard let keysByLocale = context.keysByLocale,
              let baseKeys = keysByLocale[baseLocale] else {
            Issue.record("Missing base locale \(baseLocale) in \(catalogName) catalog")
            return
        }

        for (locale, keys) in keysByLocale.sorted(by: { $0.key < $1.key }) {
            #expect(keys == baseKeys, 
                   "Locale \(locale) has key mismatch in \(catalogName) catalog")
        }
    }
    
    private func assertRequiredKeysPresent(context: CatalogContext, keys: [String], 
                                         enabledLocales: [String], catalogName: String) {
        for key in keys {
            guard let entry = context.catalog.strings[key] else {
                Issue.record("Missing required key \(key) in \(catalogName) catalog")
                continue
            }
            
            // Only test enabled locales
            for locale in enabledLocales.sorted() {
                guard let localization = entry.localizations[locale], 
                      let unit = localization.stringUnit else {
                    Issue.record("Missing localization for key \(key) in enabled locale \(locale) (\(catalogName))")
                    continue
                }
                
                let segments = gatherSegments(from: unit)
                #expect(!segments.isEmpty, 
                       "No content for key \(key) in enabled locale \(locale) (\(catalogName))")
                
                for segment in segments {
                    let trimmed = segment.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    #expect(!trimmed.isEmpty, 
                           "Empty translation for key \(key) at \(segment.path) in enabled locale \(locale) (\(catalogName))")
                }
            }
        }
    }
    
    private func assertLocaleStringValue(context: CatalogContext, locale: String, key: String, 
                                        expectedValue: String, catalogName: String) {
        guard let entry = context.catalog.strings[key] else {
            Issue.record("Missing key \(key) in \(catalogName) catalog")
            return
        }
        
        guard let localization = entry.localizations[locale], 
              let unit = localization.stringUnit else {
            Issue.record("Missing \(locale) localization for key \(key) in \(catalogName) catalog")
            return
        }
        
        // For simple strings (non-pluralized)
        if let actualValue = unit.value {
            #expect(actualValue == expectedValue, 
                   "\(locale) translation mismatch for key \(key) in \(catalogName) catalog. Expected: '\(expectedValue)', Actual: '\(actualValue)'")
        } else {
            Issue.record("Key \(key) has no value in \(locale) localization for \(catalogName) catalog")
        }
    }
    
    private func assertPlaceholderConsistencyForKeys(context: CatalogContext, keys: [String], 
                                                   enabledLocales: [String], catalogName: String) {
        let baseLocale = context.baseLocale
        guard let placeholderSignature = context.placeholderSignature,
              let baseSignatures = placeholderSignature[baseLocale] else {
            Issue.record("Missing base placeholder signature for \(catalogName)")
            return
        }

        for (locale, localeSignatures) in placeholderSignature.sorted(by: { $0.key < $1.key }) {
            guard locale != baseLocale else { continue }
            guard enabledLocales.contains(locale) else { continue } // Only test enabled locales
            
            // Only check required keys
            for key in keys.sorted() {
                guard let baseMap = baseSignatures[key] else { continue }
                guard let localeMap = localeSignatures[key] else {
                    Issue.record("Key \(key) missing for locale \(locale) in \(catalogName) catalog")
                    continue
                }
                
                for path in baseMap.keys.sorted() {
                    let expected = normalizedPlaceholders(baseMap[path, default: []])
                    let actual = normalizedPlaceholders(localeMap[path, default: []])
                    #expect(actual == expected, 
                           "Placeholder mismatch for key \(key) at \(path) in locale \(locale) (\(catalogName))")
                }
            }
        }
    }
}
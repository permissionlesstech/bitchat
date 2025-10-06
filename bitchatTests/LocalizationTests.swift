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
  
  private let testsDirectoryURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  private let repoRootURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  
  // MARK: - Configuration Validation
  
  /// Tests that configured keys actually exist in their respective catalogs.
  func testConfiguredKeysExistInCatalogs() throws {
    let appCatalog = try loadCatalog(relativePath: "bitchat/Localizable.xcstrings")
    let shareCatalog = try loadCatalog(relativePath: "bitchatShareExtension/Localization/Localizable.xcstrings")
    let config = try loadConfig()
    
    // Verify all required app keys exist in app catalog
    let allAppKeys = getAllAppKeys(from: config)
    for key in allAppKeys {
      XCTAssertTrue(appCatalog.strings.keys.contains(key), 
                   "Configured app key '\(key)' not found in app catalog")
    }
    
    // Verify all required share extension keys exist in share extension catalog
    let allShareKeys = getAllShareExtensionKeys(from: config)
    for key in allShareKeys {
      XCTAssertTrue(shareCatalog.strings.keys.contains(key), 
                   "Configured share extension key '\(key)' not found in share extension catalog")
    }
  }
  
  /// Tests that expected values reference valid keys and locales.
  func testExpectedValuesConfiguration() throws {
    let appCatalog = try loadCatalog(relativePath: "bitchat/Localizable.xcstrings")
    let shareCatalog = try loadCatalog(relativePath: "bitchatShareExtension/Localization/Localizable.xcstrings")
    let config = try loadConfig()
    
    for (locale, localeConfig) in config.testLocales {
      guard localeConfig.enabled else { continue }
      
      for (key, expectedValue) in localeConfig.assertValues {
        // Key should exist in either app or share extension
        let keyExistsInApp = appCatalog.strings.keys.contains(key)
        let keyExistsInShare = shareCatalog.strings.keys.contains(key)
        
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
    let appContext = try loadContextWithKeys(relativePath: "bitchat/Localizable.xcstrings")
    assertLocaleParity(context: appContext, catalogName: "App")
    
    // Test share extension catalog
    let shareContext = try loadContextWithKeys(relativePath: "bitchatShareExtension/Localization/Localizable.xcstrings")
    assertLocaleParity(context: shareContext, catalogName: "ShareExtension")
  }
  
  /// Validates that enabled locales have translated state for all required keys.
  func testEnabledLocalesHaveTranslations() throws {
    let appCatalog = try loadCatalog(relativePath: "bitchat/Localizable.xcstrings")
    let shareCatalog = try loadCatalog(relativePath: "bitchatShareExtension/Localization/Localizable.xcstrings")
    let config = try loadConfig()
    
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
        guard let entry = shareCatalog.strings[key],
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
    let appContext = try loadContextWithKeys(relativePath: "bitchat/Localizable.xcstrings")
    let shareContext = try loadContextWithKeys(relativePath: "bitchatShareExtension/Localization/Localizable.xcstrings")
    let config = try loadConfig()
    
    let enabledLocales = getEnabledTestLocales(from: config)
    let baseLocale = appContext.baseLocale
    let baseAppKeys = appContext.keysByLocale?[baseLocale] ?? Set()
    let baseShareKeys = shareContext.keysByLocale?[baseLocale] ?? Set()
    
    for locale in enabledLocales {
      // Skip base locale comparison with itself
      if locale == baseLocale { continue }
      
      // Verify locale is present in both catalogs
      XCTAssertTrue(appContext.locales.contains(locale), 
                   "Locale '\(locale)' missing from app catalog")
      XCTAssertTrue(shareContext.locales.contains(locale), 
                   "Locale '\(locale)' missing from share extension catalog")
      
      // Verify locale has same number of keys as base locale
      let appLocaleKeys = appContext.keysByLocale?[locale] ?? Set()
      XCTAssertEqual(appLocaleKeys.count, baseAppKeys.count, 
                    "Locale '\(locale)' app catalog missing keys compared to \(baseLocale)")
      
      let shareLocaleKeys = shareContext.keysByLocale?[locale] ?? Set()
      XCTAssertEqual(shareLocaleKeys.count, baseShareKeys.count, 
                    "Locale '\(locale)' share extension catalog missing keys compared to \(baseLocale)")
    }
  }
  
  // MARK: - Content Validation
  
  /// Guards required strings from going empty per enabled locale.
  func testRequiredKeysNonEmpty() throws {
    let config = try loadConfig()
    let enabledLocales = getEnabledTestLocales(from: config)
    
    // Test app required keys
    let appContext = try loadContext(relativePath: "bitchat/Localizable.xcstrings")
    let allAppKeys = getAllAppKeys(from: config)
    assertRequiredKeysPresent(context: appContext, keys: allAppKeys, 
                            enabledLocales: enabledLocales, catalogName: "App")
    
    // Test share extension required keys
    let shareContext = try loadContext(relativePath: "bitchatShareExtension/Localization/Localizable.xcstrings")
    let allShareKeys = getAllShareExtensionKeys(from: config)
    assertRequiredKeysPresent(context: shareContext, keys: allShareKeys, 
                            enabledLocales: enabledLocales, catalogName: "ShareExtension")
  }
  
  /// Validates that configured locales contain expected string values.
  func testLocalizationExpectedValues() throws {
    let appContext = try loadContext(relativePath: "bitchat/Localizable.xcstrings")
    let shareContext = try loadContext(relativePath: "bitchatShareExtension/Localization/Localizable.xcstrings")
    let config = try loadConfig()
    
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
          assertLocaleStringValue(context: shareContext, locale: locale, 
                                key: key, expectedValue: expectedValue, 
                                catalogName: "ShareExtension")
        }
      }
    }
  }
  
  // MARK: - Format Validation
  
  /// Verifies format placeholders stay consistent across locales for required keys.
  func testPlaceholderConsistency() throws {
    let config = try loadConfig()
    let enabledLocales = getEnabledTestLocales(from: config)
    
    // Test app catalog placeholder consistency
    let appContext = try loadContextWithPlaceholders(relativePath: "bitchat/Localizable.xcstrings")
    let allAppKeys = getAllAppKeys(from: config)
    assertPlaceholderConsistencyForKeys(context: appContext, keys: allAppKeys, 
                                      enabledLocales: enabledLocales, catalogName: "App")
    
    // Test share extension catalog placeholder consistency
    let shareContext = try loadContextWithPlaceholders(relativePath: "bitchatShareExtension/Localization/Localizable.xcstrings")
    let allShareKeys = getAllShareExtensionKeys(from: config)
    assertPlaceholderConsistencyForKeys(context: shareContext, keys: allShareKeys, 
                                      enabledLocales: enabledLocales, catalogName: "ShareExtension")
  }
  
  // MARK: - Private Helpers
  
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
  
  // MARK: - Context Loading Helpers
  
  private func loadContext(relativePath: String) throws -> CatalogContext {
    let catalog = try loadCatalog(relativePath: relativePath)
    return CatalogContext(
      catalog: catalog, 
      locales: catalog.locales, 
      baseLocale: catalog.sourceLanguage
    )
  }
  
  private func loadContextWithKeys(relativePath: String) throws -> CatalogContext {
    let catalog = try loadCatalog(relativePath: relativePath)
    let locales = catalog.locales
    let baseLocale = catalog.sourceLanguage
    var keysByLocale: [String: Set<String>] = [:]

    for locale in locales {
      var localeKeys: Set<String> = []
      for (key, entry) in catalog.strings {
        guard let localization = entry.localizations[locale], 
              localization.stringUnit != nil else {
          continue
        }
        localeKeys.insert(key)
      }
      keysByLocale[locale] = localeKeys
    }

    return CatalogContext(
      catalog: catalog, 
      locales: locales, 
      baseLocale: baseLocale, 
      keysByLocale: keysByLocale
    )
  }
  
  private func loadContextWithPlaceholders(relativePath: String) throws -> CatalogContext {
    let catalog = try loadCatalog(relativePath: relativePath)
    let locales = catalog.locales
    let baseLocale = catalog.sourceLanguage
    var placeholderSignature: [String: [String: [String: [String]]]] = [:]

    for locale in locales {
      var localePlaceholders: [String: [String: [String]]] = [:]
      for (key, entry) in catalog.strings {
        guard let localization = entry.localizations[locale], 
              let unit = localization.stringUnit else {
          continue
        }
        let segments = gatherSegments(from: unit)
        var pathMap: [String: [String]] = [:]
        for segment in segments {
          pathMap[segment.path] = placeholders(in: segment.value)
        }
        localePlaceholders[key] = pathMap
      }
      placeholderSignature[locale] = localePlaceholders
    }

    return CatalogContext(
      catalog: catalog, 
      locales: locales, 
      baseLocale: baseLocale, 
      placeholderSignature: placeholderSignature
    )
  }
  
  private func loadCatalog(relativePath: String) throws -> StringCatalog {
    let url = repoRootURL.appendingPathComponent(relativePath)
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(StringCatalog.self, from: data)
  }
  
  private func loadConfig() throws -> LocalizationTestConfig {
    let url = testsDirectoryURL.appendingPathComponent("LocalizationTestsConfig.json")
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(LocalizationTestConfig.self, from: data)
  }
  
  private func normalizedPlaceholders(_ tokens: [String]) -> [String] {
    tokens.sorted()
  }
  
  private func placeholders(in string: String) -> [String] {
    guard let regex = createPlaceholderRegex() else { return [] }
    let range = NSRange(location: 0, length: (string as NSString).length)
    let matches = regex.matches(in: string, options: [], range: range)
    var tokens: [String] = []
    for match in matches {
      if let range = Range(match.range, in: string) {
        let token = String(string[range])
        if token == "%%" { continue }
        tokens.append(token)
      }
    }
    return tokens
  }
}

// MARK: - Supporting Types

/// Represents a string catalog file structure (.xcstrings format)
private struct StringCatalog: Decodable {
  let sourceLanguage: String
  let strings: [String: CatalogEntry]

  var locales: [String] {
    var localeSet: Set<String> = []
    for entry in strings.values {
      localeSet.formUnion(entry.localizations.keys)
    }
    return localeSet.sorted()
  }
}

/// Represents an entry in a string catalog
private struct CatalogEntry: Decodable {
  let localizations: [String: CatalogLocalization]
}

/// Represents a localization for a specific locale
private struct CatalogLocalization: Decodable {
  let stringUnit: CatalogStringUnit?
}

/// Represents a string unit with state and value
private struct CatalogStringUnit: Decodable {
  let state: String
  let value: String?
  let variations: CatalogVariations?
}

/// Represents variations (e.g., plural forms) in a string unit
private struct CatalogVariations: Decodable {
  let plural: [String: [String: CatalogVariationValue]]?
}

/// Represents a variation value within plural forms
private struct CatalogVariationValue: Decodable {
  let stringUnit: CatalogStringUnit?
}

/// Configuration structure for localization tests
private struct LocalizationTestConfig: Decodable {
  let requiredKeys: RequiredKeys
  let testLocales: [String: LocaleConfig]
}

/// Required keys organized by category for app and share extension
private struct RequiredKeys: Decodable {
  let app: [String: [String]]  // Dictionary of category -> keys
  let shareExtension: [String: [String]]  // Dictionary of category -> keys
}

/// Configuration for a specific locale in tests
private struct LocaleConfig: Decodable {
  let enabled: Bool
  let assertValues: [String: String]
}

/// Context object containing catalog information and derived data
private struct CatalogContext {
  let catalog: StringCatalog
  let locales: [String]
  let baseLocale: String
  let keysByLocale: [String: Set<String>]?
  let placeholderSignature: [String: [String: [String: [String]]]]?
  
  init(catalog: StringCatalog, locales: [String], baseLocale: String, 
       keysByLocale: [String: Set<String>]? = nil,
       placeholderSignature: [String: [String: [String: [String]]]]? = nil) {
    self.catalog = catalog
    self.locales = locales
    self.baseLocale = baseLocale
    self.keysByLocale = keysByLocale
    self.placeholderSignature = placeholderSignature
  }
}

/// Represents a segment of a localized string for analysis
private struct Segment {
  let components: [String]
  let value: String

  var path: String {
    components.isEmpty ? "base" : components.joined(separator: ".")
  }
}

// MARK: - Helper Functions

/// Extracts all app keys from the hierarchical configuration structure
private func getAllAppKeys(from config: LocalizationTestConfig) -> [String] {
  var allKeys: [String] = []
  for (_, keys) in config.requiredKeys.app {
    allKeys.append(contentsOf: keys)
  }
  return allKeys
}

/// Extracts all share extension keys from the hierarchical configuration structure
private func getAllShareExtensionKeys(from config: LocalizationTestConfig) -> [String] {
  var allKeys: [String] = []
  for (_, keys) in config.requiredKeys.shareExtension {
    allKeys.append(contentsOf: keys)
  }
  return allKeys
}

/// Gets list of enabled test locales from configuration
private func getEnabledTestLocales(from config: LocalizationTestConfig) -> [String] {
  return config.testLocales.compactMap { localeConfig in
    localeConfig.value.enabled ? localeConfig.key : nil
  }
}

/// Recursively gathers all segments from a string unit, including plural variations
private func gatherSegments(from unit: CatalogStringUnit, prefix: [String] = []) -> [Segment] {
  var segments: [Segment] = []
  if let value = unit.value {
    segments.append(Segment(components: prefix, value: value))
  } else if prefix.isEmpty {
    segments.append(Segment(components: [], value: ""))
  }
  if let plural = unit.variations?.plural {
    for (variable, categories) in plural.sorted(by: { $0.key < $1.key }) {
      for (category, variation) in categories.sorted(by: { $0.key < $1.key }) {
        if let nested = variation.stringUnit {
          var nextPrefix = prefix
          nextPrefix.append("plural")
          nextPrefix.append(variable)
          nextPrefix.append(category)
          segments.append(contentsOf: gatherSegments(from: nested, prefix: nextPrefix))
        }
      }
    }
  }
  return segments
}

/// Safe regex creation that returns nil on failure instead of crashing
private func createPlaceholderRegex() -> NSRegularExpression? {
  let pattern = "%(?:\\d+\\$)?#@[A-Za-z0-9_]+@|%(?:\\d+\\$)?[#0\\- +'\"]*(?:\\d+|\\*)?(?:\\.\\d+)?(?:hh|h|ll|l|z|t|L)?[a-zA-Z@]"
  return try? NSRegularExpression(pattern: pattern, options: [])
}

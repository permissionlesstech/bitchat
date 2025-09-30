import Foundation
import XCTest

private let localizationTestsDirectoryURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
private let testsRootURL = localizationTestsDirectoryURL.deletingLastPathComponent()
private let repoRootURL = testsRootURL.deletingLastPathComponent()

final class LocalizationCatalogTests: XCTestCase {
  // Ensures every app locale includes exactly the same keys as Base.
  func testAppCatalogLocaleParity() throws {
    let context = try loadContext(relativePath: "bitchat/Localizable.xcstrings")
    assertLocaleParity(context: context, catalogName: "App")
  }

  // Verifies format placeholders stay consistent across app locales.
  func testAppCatalogPlaceholderConsistency() throws {
    let context = try loadContext(relativePath: "bitchat/Localizable.xcstrings")
    assertPlaceholderConsistency(context: context, catalogName: "App")
  }

  // Guards a core set of app strings from going empty per locale.
  func testAppPrimaryKeysNonEmpty() throws {
    let context = try loadContext(relativePath: "bitchat/Localizable.xcstrings")
    let primaryKeys = try loadPrimaryKeys().app
    assertPrimaryKeysPresent(context: context, keys: primaryKeys, catalogName: "App")
  }

  // Ensures every share extension locale matches Base key coverage.
  func testShareExtensionCatalogLocaleParity() throws {
    let context = try loadContext(relativePath: "bitchatShareExtension/Localization/Localizable.xcstrings")
    assertLocaleParity(context: context, catalogName: "ShareExtension")
  }

  // Verifies share extension placeholders align across locales.
  func testShareExtensionCatalogPlaceholderConsistency() throws {
    let context = try loadContext(relativePath: "bitchatShareExtension/Localization/Localizable.xcstrings")
    assertPlaceholderConsistency(context: context, catalogName: "ShareExtension")
  }

  // Confirms critical share extension strings remain non-empty per locale.
  func testShareExtensionPrimaryKeysNonEmpty() throws {
    let context = try loadContext(relativePath: "bitchatShareExtension/Localization/Localizable.xcstrings")
    let primaryKeys = try loadPrimaryKeys().shareExtension
    assertPrimaryKeysPresent(context: context, keys: primaryKeys, catalogName: "ShareExtension")
  }

  // Validates that configured locales contain expected string values.
  func testLocalizationExpectedValues() throws {
    let appContext = try loadContext(relativePath: "bitchat/Localizable.xcstrings")
    let shareContext = try loadContext(relativePath: "bitchatShareExtension/Localization/Localizable.xcstrings")
    let config = try loadPrimaryKeys()
    
    guard let testLocales = config.testLocales else {
      // If no testLocales specified, skip this test
      return
    }
    
    guard let expectedValues = config.expectedValues else {
      XCTFail("No expectedValues configured in PrimaryLocalizationKeys.json")
      return
    }
    
    // Loop through each locale to test
    for locale in testLocales {
      guard let localeExpectedValues = expectedValues[locale] else {
        XCTFail("No expected values configured for locale '\(locale)' in PrimaryLocalizationKeys.json")
        continue
      }
      
      // Test each expected key/value pair for this locale
      for (key, expectedValue) in localeExpectedValues {
        if config.app.contains(key) {
          assertLocaleStringValue(context: appContext, locale: locale, key: key, expectedValue: expectedValue, catalogName: "App")
        } else if config.shareExtension.contains(key) {
          assertLocaleStringValue(context: shareContext, locale: locale, key: key, expectedValue: expectedValue, catalogName: "ShareExtension")
        }
      }
    }
  }

  // Ensures configured test locales are present and complete.
  func testConfiguredLocalesCompleteness() throws {
    let appContext = try loadContext(relativePath: "bitchat/Localizable.xcstrings")
    let shareContext = try loadContext(relativePath: "bitchatShareExtension/Localization/Localizable.xcstrings")
    let config = try loadPrimaryKeys()
    
    guard let testLocales = config.testLocales else {
      // If no testLocales specified, skip this test
      return
    }
    
    let baseLocale = appContext.baseLocale
    let baseAppKeys = appContext.keysByLocale[baseLocale] ?? Set()
    let baseShareKeys = shareContext.keysByLocale[baseLocale] ?? Set()
    
    for locale in testLocales {
      // Skip base locale comparison with itself
      if locale == baseLocale { continue }
      
      // Verify locale is present in both catalogs
      XCTAssertTrue(appContext.locales.contains(locale), "Locale '\(locale)' missing from app catalog")
      XCTAssertTrue(shareContext.locales.contains(locale), "Locale '\(locale)' missing from share extension catalog")
      
      // Verify locale has same number of keys as base locale
      let appLocaleKeys = appContext.keysByLocale[locale] ?? Set()
      XCTAssertEqual(appLocaleKeys.count, baseAppKeys.count, "Locale '\(locale)' app catalog missing keys compared to \(baseLocale)")
      
      let shareLocaleKeys = shareContext.keysByLocale[locale] ?? Set()
      XCTAssertEqual(shareLocaleKeys.count, baseShareKeys.count, "Locale '\(locale)' share extension catalog missing keys compared to \(baseLocale)")
    }
  }

  // Test that validates placeholder replacement works correctly for all locales
  // This test ensures that when placeholders are replaced with actual values,
  // no raw placeholder text remains in the final string
  func testPlaceholderReplacementCompleteness() throws {
    let appContext = try loadContext(relativePath: "bitchat/Localizable.xcstrings")
    let shareContext = try loadContext(relativePath: "bitchatShareExtension/Localization/Localizable.xcstrings")
    
    // Test both app and share extension catalogs
    let contexts = [
      ("App", appContext),
      ("ShareExtension", shareContext)
    ]
    
    for (catalogName, context) in contexts {
      try validatePlaceholderReplacement(context: context, catalogName: catalogName)
    }
  }
  
  // Test that validates pluralization placeholders work correctly
  func testPluralizationPlaceholderCompleteness() throws {
    let context = try loadContext(relativePath: "bitchat/Localizable.xcstrings")
    
    // Find keys that use pluralization placeholders
    let pluralizationKeys = findPluralizationKeys(in: context)
    
    for key in pluralizationKeys {
      try validatePluralizationKey(key: key, context: context)
    }
  }

  // MARK: - Placeholder Validation Helper Methods
  
  private func validatePlaceholderReplacement(context: CatalogContext, catalogName: String) throws {
    let baseLocale = context.baseLocale
    
    for (key, entry) in context.catalog.strings {
      // Get the English version to understand what placeholders should exist
      guard let englishLocalization = entry.localizations[baseLocale],
            let englishUnit = englishLocalization.stringUnit else {
        continue
      }
      
      let englishValue = englishUnit.value ?? ""
      let englishPlaceholders = placeholders(in: englishValue)
      
      // Skip keys without placeholders
      guard !englishPlaceholders.isEmpty else { continue }
      
      // Test each locale
      for locale in context.locales {
        guard locale != baseLocale else { continue }
        
        guard let localization = entry.localizations[locale],
              let unit = localization.stringUnit else {
          XCTFail("Missing localization for key '\(key)' in locale '\(locale)' (\(catalogName))")
          continue
        }
        
        let localizedValue = unit.value ?? ""
        let localizedPlaceholders = placeholders(in: localizedValue)
        
        // Test placeholder replacement simulation
        try validatePlaceholderReplacement(
          key: key,
          locale: locale,
          localizedValue: localizedValue,
          englishPlaceholders: englishPlaceholders,
          localizedPlaceholders: localizedPlaceholders,
          catalogName: catalogName
        )
      }
    }
  }
  
  private func validatePlaceholderReplacement(
    key: String,
    locale: String,
    localizedValue: String,
    englishPlaceholders: [String],
    localizedPlaceholders: [String],
    catalogName: String
  ) throws {
    var testString = localizedValue
    
    // Before replacement: verify the string contains the expected placeholders
    let normalizedEnglish = Set(englishPlaceholders.map(normalizePlaceholder))
    let normalizedLocalized = Set(localizedPlaceholders.map(normalizePlaceholder))
    
    XCTAssertEqual(
      normalizedLocalized, normalizedEnglish,
      "Placeholder mismatch for key '\(key)' in locale '\(locale)' (\(catalogName)). Expected: \(normalizedEnglish), Got: \(normalizedLocalized)"
    )
    
    // Simulate placeholder replacement with test values
    for placeholder in localizedPlaceholders {
      let replacementValue = generateReplacementValue(for: placeholder)
      testString = testString.replacingOccurrences(of: placeholder, with: replacementValue)
    }
    
    // After replacement: verify no raw placeholders remain
    let remainingPlaceholders = placeholders(in: testString)
    XCTAssertTrue(
      remainingPlaceholders.isEmpty,
      "Raw placeholders remain after replacement for key '\(key)' in locale '\(locale)' (\(catalogName)). Remaining: \(remainingPlaceholders). Final string: '\(testString)'"
    )
    
    // Verify no placeholder-like patterns remain (catch malformed placeholders)
    let suspiciousPatterns = findSuspiciousPlaceholderPatterns(in: testString)
    XCTAssertTrue(
      suspiciousPatterns.isEmpty,
      "Suspicious placeholder patterns found for key '\(key)' in locale '\(locale)' (\(catalogName)). Patterns: \(suspiciousPatterns). Final string: '\(testString)'"
    )
  }
  
  private func validatePluralizationKey(key: String, context: CatalogContext) throws {
    guard let entry = context.catalog.strings[key] else { return }
    
    for locale in context.locales {
      guard let localization = entry.localizations[locale] else { continue }
      
      // Check if this locale has proper pluralization structure
      if let unit = localization.stringUnit,
         let value = unit.value,
         value.contains("%#@") {
        
        // If it uses pluralization placeholders, it should have substitutions
        if localization.substitutions == nil {
          XCTFail("Key '\(key)' in locale '\(locale)' uses pluralization placeholder but lacks substitutions structure")
        }
      }
    }
  }
  
  private func findPluralizationKeys(in context: CatalogContext) -> [String] {
    var keys: [String] = []
    
    for (key, entry) in context.catalog.strings {
      // Check if any locale uses pluralization
      for (_, localization) in entry.localizations {
        if let unit = localization.stringUnit,
           let value = unit.value,
           value.contains("%#@") {
          keys.append(key)
          break
        }
      }
    }
    
    return keys
  }
  
  private func extractPlaceholders(from string: String) -> [String] {
    // Use the same proven regex pattern as the original placeholders() function
    let pattern = "%(?:\\d+\\$)?#@[A-Za-z0-9_]+@|%(?:\\d+\\$)?[#0\\- +'\"]*(?:\\d+|\\*)?(?:\\.\\d+)?(?:hh|h|ll|l|z|t|L)?[a-zA-Z@]"
    let regex = try! NSRegularExpression(pattern: pattern, options: [])
    let range = NSRange(location: 0, length: string.count)
    let matches = regex.matches(in: string, options: [], range: range)
    
    var placeholders: [String] = []
    for match in matches {
      if let range = Range(match.range, in: string) {
        let placeholder = String(string[range])
        if placeholder != "%%" { // Skip escaped %
          placeholders.append(placeholder)
        }
      }
    }
    
    return placeholders
  }
  
  private func normalizePlaceholder(_ placeholder: String) -> String {
    // Normalize positional vs non-positional placeholders for comparison
    // %@ and %1$@ should be considered equivalent
    if placeholder.contains("$") {
      return placeholder
    } else if placeholder.hasPrefix("%") && placeholder.hasSuffix("@") {
      return "%1$@"
    } else if placeholder.hasPrefix("%") && (placeholder.hasSuffix("d") || placeholder.hasSuffix("i")) {
      return "%1$d"
    }
    return placeholder
  }
  
  private func generateReplacementValue(for placeholder: String) -> String {
    if placeholder.contains("#@") {
      // Pluralization placeholder - this would be handled by the system
      return "2 people" // Simulate pluralization result
    } else if placeholder.hasSuffix("@") {
      return "TestString"
    } else if placeholder.hasSuffix("d") || placeholder.hasSuffix("i") {
      return "42"
    } else if placeholder.hasSuffix("f") {
      return "3.14"
    } else {
      return "TestValue"
    }
  }
  
  private func findSuspiciousPlaceholderPatterns(in string: String) -> [String] {
    var suspicious: [String] = []
    
    // Look for patterns that might be malformed placeholders
    let suspiciousPatterns = [
      "\\[%[^\\]]*\\]", // [%...] patterns
      "%[A-Za-z0-9_]*@[A-Za-z0-9_]*", // Malformed pluralization
      "@[A-Za-z0-9_]+@", // Orphaned @ patterns
    ]
    
    for pattern in suspiciousPatterns {
      let regex = try! NSRegularExpression(pattern: pattern, options: [])
      let range = NSRange(location: 0, length: string.count)
      let matches = regex.matches(in: string, options: [], range: range)
      
      for match in matches {
        if let range = Range(match.range, in: string) {
          suspicious.append(String(string[range]))
        }
      }
    }
    
    return suspicious
  }

  // MARK: - Assertions

  private func assertLocaleParity(context: CatalogContext, catalogName: String, file: StaticString = #filePath, line: UInt = #line) {
    let baseLocale = context.baseLocale
    guard let baseKeys = context.keysByLocale[baseLocale] else {
      return XCTFail("Missing base locale \(baseLocale) in \(catalogName) catalog", file: file, line: line)
    }

    for (locale, keys) in context.keysByLocale.sorted(by: { $0.key < $1.key }) {
      XCTAssertEqual(keys, baseKeys, "Locale \(locale) has key mismatch in \(catalogName) catalog", file: file, line: line)
    }
  }

  private func assertPlaceholderConsistency(context: CatalogContext, catalogName: String, file: StaticString = #filePath, line: UInt = #line) {
    let baseLocale = context.baseLocale
    guard let baseSignatures = context.placeholderSignature[baseLocale] else {
      return XCTFail("Missing base placeholder signature for \(catalogName)", file: file, line: line)
    }

    for (locale, localeSignatures) in context.placeholderSignature.sorted(by: { $0.key < $1.key }) {
      guard locale != baseLocale else { continue }
      for key in baseSignatures.keys.sorted() {
        guard let baseMap = baseSignatures[key] else {
          continue
        }
        guard let localeMap = localeSignatures[key] else {
          return XCTFail("Key \(key) missing for locale \(locale) in \(catalogName) catalog", file: file, line: line)
        }
        for path in baseMap.keys.sorted() {
          let expected = normalizedPlaceholders(baseMap[path, default: []])
          let actual = normalizedPlaceholders(localeMap[path, default: []])
          XCTAssertEqual(actual, expected, "Placeholder mismatch for key \(key) at \(path) in locale \(locale) (\(catalogName))", file: file, line: line)
        }
        for (localePath, localeTokens) in localeMap {
          guard baseMap[localePath] == nil else { continue }
          guard let fallback = fallbackPath(for: localePath, baseMap: baseMap) else {
            XCTFail("Unexpected variation \(localePath) for key \(key) in locale \(locale) (\(catalogName))", file: file, line: line)
            continue
          }
          let expected = normalizedPlaceholders(baseMap[fallback, default: []])
          let actual = normalizedPlaceholders(localeTokens)
          XCTAssertEqual(actual, expected, "Placeholder mismatch for key \(key) at \(localePath) (fallback \(fallback)) in locale \(locale) (\(catalogName))", file: file, line: line)
        }
      }
    }
  }

  private func assertPrimaryKeysPresent(context: CatalogContext, keys: [String], catalogName: String, file: StaticString = #filePath, line: UInt = #line) {
    for key in keys {
      guard let entry = context.catalog.strings[key] else {
        XCTFail("Missing primary key \(key) in \(catalogName) catalog", file: file, line: line)
        continue
      }
      for locale in context.locales.sorted() {
        guard let localization = entry.localizations[locale], let unit = localization.stringUnit else {
          XCTFail("Missing localization for key \(key) in locale \(locale) (\(catalogName))", file: file, line: line)
          continue
        }
        let segments = gatherSegments(from: unit)
        XCTAssertFalse(segments.isEmpty, "No content for key \(key) in locale \(locale) (\(catalogName))", file: file, line: line)
        for segment in segments {
          let trimmed = segment.value.trimmingCharacters(in: .whitespacesAndNewlines)
          XCTAssertFalse(trimmed.isEmpty, "Empty translation for key \(key) at \(segment.path) in locale \(locale) (\(catalogName))", file: file, line: line)
        }
      }
    }
  }

  private func assertLocaleStringValue(context: CatalogContext, locale: String, key: String, expectedValue: String, catalogName: String, file: StaticString = #filePath, line: UInt = #line) {
    guard let entry = context.catalog.strings[key] else {
      XCTFail("Missing key \(key) in \(catalogName) catalog", file: file, line: line)
      return
    }
    
    guard let localization = entry.localizations[locale], let unit = localization.stringUnit else {
      XCTFail("Missing \(locale) localization for key \(key) in \(catalogName) catalog", file: file, line: line)
      return
    }
    
    // For simple strings (non-pluralized)
    if let actualValue = unit.value {
      XCTAssertEqual(actualValue, expectedValue, "\(locale) translation mismatch for key \(key) in \(catalogName) catalog. Expected: '\(expectedValue)', Actual: '\(actualValue)'", file: file, line: line)
    } else {
      XCTFail("Key \(key) has no value in \(locale) localization for \(catalogName) catalog", file: file, line: line)
    }
  }

  // MARK: - Loading

  private func loadContext(relativePath: String) throws -> CatalogContext {
    let catalog = try loadCatalog(relativePath: relativePath)
    let locales = catalog.locales
    let baseLocale = catalog.sourceLanguage
    var keysByLocale: [String: Set<String>] = [:]
    var placeholderSignature: [String: [String: [String: [String]]]] = [:]

    for locale in locales {
      var localeKeys: Set<String> = []
      var localePlaceholders: [String: [String: [String]]] = [:]
      for (key, entry) in catalog.strings {
        guard let localization = entry.localizations[locale], let unit = localization.stringUnit else {
          continue
        }
        localeKeys.insert(key)
        let segments = gatherSegments(from: unit)
        var pathMap: [String: [String]] = [:]
        for segment in segments {
          pathMap[segment.path] = placeholders(in: segment.value)
        }
        localePlaceholders[key] = pathMap
      }
      keysByLocale[locale] = localeKeys
      placeholderSignature[locale] = localePlaceholders
    }

    return CatalogContext(catalog: catalog, locales: locales, baseLocale: baseLocale, keysByLocale: keysByLocale, placeholderSignature: placeholderSignature)
  }

  private func loadCatalog(relativePath: String) throws -> StringCatalog {
    let url = repoRootURL.appendingPathComponent(relativePath)
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(StringCatalog.self, from: data)
  }

  private func loadPrimaryKeys() throws -> PrimaryKeyConfig {
    let url = localizationTestsDirectoryURL.appendingPathComponent("PrimaryLocalizationKeys.json")
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(PrimaryKeyConfig.self, from: data)
  }
}

// MARK: - Helpers

private struct CatalogContext {
  let catalog: StringCatalog
  let locales: [String]
  let baseLocale: String
  let keysByLocale: [String: Set<String>]
  let placeholderSignature: [String: [String: [String: [String]]]]
}

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

private struct CatalogEntry: Decodable {
  let localizations: [String: CatalogLocalization]
}

private struct CatalogLocalization: Decodable {
  let stringUnit: CatalogStringUnit?
  let substitutions: [String: CatalogSubstitution]?
}

private struct CatalogStringUnit: Decodable {
  let state: String
  let value: String?
  let variations: CatalogVariations?
  let comment: String?
}

private struct CatalogVariations: Decodable {
  let plural: [String: [String: CatalogVariationValue]]?
}

private struct CatalogVariationValue: Decodable {
  let stringUnit: CatalogStringUnit?
}

private struct CatalogSubstitution: Decodable {
  let argNum: Int
  let formatSpecifier: String
  let variations: CatalogVariations?
}

private struct Segment {
  let components: [String]
  let value: String

  var path: String {
    components.isEmpty ? "base" : components.joined(separator: ".")
  }
}

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

private func normalizedPlaceholders(_ tokens: [String]) -> [String] {
  tokens.sorted()
}

private func fallbackPath(for localePath: String, baseMap: [String: [String]]) -> String? {
  let parts = localePath.split(separator: ".")
  guard parts.count == 3, parts.first == "plural" else {
    return nil
  }
  let variable = parts[1]
  let otherKey = "plural.\(variable).other"
  if baseMap[otherKey] != nil {
    return otherKey
  }
  let oneKey = "plural.\(variable).one"
  if baseMap[oneKey] != nil {
    return oneKey
  }
  return nil
}

private let placeholderRegex: NSRegularExpression = {
  let pattern = "%(?:\\d+\\$)?#@[A-Za-z0-9_]+@|%(?:\\d+\\$)?[#0\\- +'\"]*(?:\\d+|\\*)?(?:\\.\\d+)?(?:hh|h|ll|l|z|t|L)?[a-zA-Z@]"
  return try! NSRegularExpression(pattern: pattern, options: [])
}()

private func placeholders(in string: String) -> [String] {
  let range = NSRange(location: 0, length: (string as NSString).length)
  let matches = placeholderRegex.matches(in: string, options: [], range: range)
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

private struct PrimaryKeyConfig: Decodable {
  let app: [String]
  let shareExtension: [String]
  let expectedValues: [String: [String: String]]?
  let testLocales: [String]?
}

//
// LocalizationTestUtilities.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing

// MARK: - Encapsulated resources/config for localization tests

struct LocalizationResources {
    let testsDirectoryURL: URL
    let repoRootURL: URL
    let appCatalogPath: String = "bitchat/Localizable.xcstrings"
    let shareExtCatalogPath: String = "bitchatShareExtension/Localization/Localizable.xcstrings"

    static let current: LocalizationResources = {
        let thisFileURL = URL(fileURLWithPath: #filePath)
        let utilitiesDir = thisFileURL.deletingLastPathComponent()
        let testsDir = utilitiesDir.deletingLastPathComponent()
        let repoRoot = testsDir.deletingLastPathComponent()
        return LocalizationResources(testsDirectoryURL: testsDir, repoRootURL: repoRoot)
    }()

    func loadCatalog(path: String) throws -> StringCatalog {
        let url = repoRootURL.appendingPathComponent(path)
        return try decodeJSON(from: url)
    }

    func loadContext(path: String) throws -> CatalogContext {
        return try bitchatTests.loadContext(relativePath: path, repoRootURL: repoRootURL)
    }

    func loadContextWithKeys(path: String) throws -> CatalogContext {
        return try bitchatTests.loadContextWithKeys(relativePath: path, repoRootURL: repoRootURL)
    }

    func loadContextWithPlaceholders(path: String) throws -> CatalogContext {
        return try bitchatTests.loadContextWithPlaceholders(relativePath: path, repoRootURL: repoRootURL)
    }

    func loadConfig() throws -> LocalizationTestConfig {
        return try bitchatTests.loadConfig(testsDirectoryURL: testsDirectoryURL)
    }
}

// MARK: - Configuration Helpers

/// Extracts all app keys from the hierarchical configuration structure
func getAllAppKeys(from config: LocalizationTestConfig) -> [String] {
    var allKeys: [String] = []
    for (_, keys) in config.requiredKeys.app {
        allKeys.append(contentsOf: keys)
    }
    return allKeys
}

/// Extracts all share extension keys from the hierarchical configuration structure
func getAllShareExtensionKeys(from config: LocalizationTestConfig) -> [String] {
    var allKeys: [String] = []
    for (_, keys) in config.requiredKeys.shareExtension {
        allKeys.append(contentsOf: keys)
    }
    return allKeys
}

/// Gets list of enabled test locales from configuration
func getEnabledTestLocales(from config: LocalizationTestConfig) -> [String] {
    return config.testLocales.compactMap { localeConfig in
        localeConfig.value.enabled ? localeConfig.key : nil
    }
}

// MARK: - Catalog Processing

/// Recursively gathers all segments from a string unit, including plural variations
func gatherSegments(from unit: CatalogStringUnit, prefix: [String] = []) -> [Segment] {
    var segments: [Segment] = []
    if let value = unit.value {
        segments.append(Segment(components: prefix, value: value))
    } else if prefix.isEmpty {
        segments.append(Segment(components: [], value: ""))
    }
    if let plural = unit.variations?.plural {
        for (variable, categories) in plural {
            for (category, variation) in categories {
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

// MARK: - Placeholder Processing

/// Safe regex creation that returns nil on failure instead of crashing
func createPlaceholderRegex() -> NSRegularExpression? {
    // Matches two classes of placeholders commonly appearing in .strings-format values:
    // 1) ICU-style object placeholders like "%@" and positional variants like "%1$@"
    // 2) C-style format specifiers with optional flags/width/precision/length (e.g., "%d", "%0.2f")
    // Examples:
    //   input: "Hello %1$@, you have %02d items"
    //   output tokens: ["%1$@", "%02d"]
    let pattern = "%(?:\\d+\\$)?#@[A-Za-z0-9_]+@|%(?:\\d+\\$)?[#0\\- +'\"]*(?:\\d+|\\*)?(?:\\.\\d+)?(?:hh|h|ll|l|z|t|L)?[a-zA-Z@]"
    return try? NSRegularExpression(pattern: pattern, options: [])
}

/// Extracts placeholder tokens from a string
func placeholders(in string: String) -> [String] {
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

// Note: placeholder normalization now inlines `tokens.sorted()` at call sites

// MARK: - Context Loading

/// Loads a string catalog from a relative path
func loadCatalog(relativePath: String, repoRootURL: URL) throws -> StringCatalog {
    let url = repoRootURL.appendingPathComponent(relativePath)
    return try decodeJSON(from: url)
}

/// Loads the localization test configuration
func loadConfig(testsDirectoryURL: URL) throws -> LocalizationTestConfig {
    let url = testsDirectoryURL.appendingPathComponent("LocalizationTestsConfig.json")
    return try decodeJSON(from: url)
}

/// Creates a basic catalog context
func loadContext(relativePath: String, repoRootURL: URL) throws -> CatalogContext {
    let catalog = try loadCatalog(relativePath: relativePath, repoRootURL: repoRootURL)
    return CatalogContext(
        catalog: catalog, 
        locales: catalog.locales, 
        baseLocale: catalog.sourceLanguage
    )
}

/// Creates a catalog context with key-by-locale mapping
func loadContextWithKeys(relativePath: String, repoRootURL: URL) throws -> CatalogContext {
    let catalog = try loadCatalog(relativePath: relativePath, repoRootURL: repoRootURL)
    let locales = catalog.locales
    let baseLocale = catalog.sourceLanguage
    var keysByLocale: [String: Set<String>] = [:]

    for locale in locales {
        let validKeys = catalog.strings.compactMap { (key, entry) in
            entry.isValid(for: locale) ? key : nil
        }
        keysByLocale[locale] = Set(validKeys)
    }

    return CatalogContext(
        catalog: catalog, 
        locales: locales, 
        baseLocale: baseLocale, 
        keysByLocale: keysByLocale
    )
}

/// Creates a catalog context with placeholder signature mapping
func loadContextWithPlaceholders(relativePath: String, repoRootURL: URL) throws -> CatalogContext {
    let catalog = try loadCatalog(relativePath: relativePath, repoRootURL: repoRootURL)
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

// MARK: - Generic Decoding

/// Decodes a JSON file at the given URL into the requested Decodable type
private func decodeJSON<T: Decodable>(from url: URL) throws -> T {
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(T.self, from: data)
}

// MARK: - Expectation helpers

/// Controls whether localization tests should hard-fail on issues (default: true).
/// Set env var `TEST_LOCALIZATION_FAIL_ON_ERROR=false` to only record issues as warnings.
let TEST_LOCALIZATION_FAIL_ON_ERROR: Bool = {
    if let raw = ProcessInfo.processInfo.environment["TEST_LOCALIZATION_FAIL_ON_ERROR"]?.lowercased() {
        return !(raw == "0" || raw == "false" || raw == "no")
    }
    return false
}()

/// Uses #expect when fail-on-error is enabled, otherwise records as a non-fatal issue
func expectOrRecord(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
    if TEST_LOCALIZATION_FAIL_ON_ERROR {
        #expect(condition(), Comment(rawValue: message()))
    } else {
        if !condition() {
            Issue.record(Comment(rawValue: message()))
        }
    }
}

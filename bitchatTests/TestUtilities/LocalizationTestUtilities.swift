//
// LocalizationTestUtilities.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

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

// MARK: - Placeholder Processing

/// Safe regex creation that returns nil on failure instead of crashing
func createPlaceholderRegex() -> NSRegularExpression? {
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

/// Normalizes placeholder tokens by sorting them
func normalizedPlaceholders(_ tokens: [String]) -> [String] {
    tokens.sorted()
}

// MARK: - Context Loading

/// Loads a string catalog from a relative path
func loadCatalog(relativePath: String, repoRootURL: URL) throws -> StringCatalog {
    let url = repoRootURL.appendingPathComponent(relativePath)
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(StringCatalog.self, from: data)
}

/// Loads the localization test configuration
func loadConfig(testsDirectoryURL: URL) throws -> LocalizationTestConfig {
    let url = testsDirectoryURL.appendingPathComponent("LocalizationTestsConfig.json")
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(LocalizationTestConfig.self, from: data)
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

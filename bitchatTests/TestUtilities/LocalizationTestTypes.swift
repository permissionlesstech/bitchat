//
// LocalizationTestTypes.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

// MARK: - String Catalog Types

/// Represents a string catalog file structure (.xcstrings format)
struct StringCatalog: Decodable {
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
struct CatalogEntry: Decodable {
    let localizations: [String: CatalogLocalization]
}

/// Represents a localization for a specific locale
struct CatalogLocalization: Decodable {
    let stringUnit: CatalogStringUnit?
}

/// Represents a string unit with state and value
struct CatalogStringUnit: Decodable {
    let state: String
    let value: String?
    let variations: CatalogVariations?
}

/// Represents variations (e.g., plural forms) in a string unit
struct CatalogVariations: Decodable {
    let plural: [String: [String: CatalogVariationValue]]?
}

/// Represents a variation value within plural forms
struct CatalogVariationValue: Decodable {
    let stringUnit: CatalogStringUnit?
}

// MARK: - Convenience

extension CatalogEntry {
    func isValid(for locale: String) -> Bool {
        guard let localization = localizations[locale] else { return nil != nil }
        return localization.stringUnit != nil
    }
}

// MARK: - Configuration Types

/// Configuration structure for localization tests
struct LocalizationTestConfig: Decodable {
    let requiredKeys: RequiredKeys
    let testLocales: [String: LocaleConfig]
}

/// Required keys organized by category for app and share extension
struct RequiredKeys: Decodable {
    let app: [String: [String]]  // Dictionary of category -> keys
    let shareExtension: [String: [String]]  // Dictionary of category -> keys
}

/// Configuration for a specific locale in tests
struct LocaleConfig: Decodable {
    let enabled: Bool
    let assertValues: [String: String]
}

// MARK: - Context Types

/// Context object containing catalog information and derived data
struct CatalogContext {
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
struct Segment {
    let components: [String]
    let value: String

    var path: String {
        components.isEmpty ? "base" : components.joined(separator: ".")
    }
}

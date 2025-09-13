import Foundation

enum Localization {
    static func bundle(for locale: String) -> Bundle {
        if let path = Bundle.main.path(forResource: locale, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        if let basePath = Bundle.main.path(forResource: "Base", ofType: "lproj"),
           let baseBundle = Bundle(path: basePath) {
            return baseBundle
        }
        return Bundle.main
    }

    static func localized(_ key: String, locale: String, table: String? = nil) -> String {
        let langBundle = bundle(for: locale)
        let value = NSLocalizedString(key, tableName: table, bundle: langBundle, value: key, comment: "")
        if value != key { return value }

        if let basePath = Bundle.main.path(forResource: "Base", ofType: "lproj"),
           let baseBundle = Bundle(path: basePath) {
            let fallback = NSLocalizedString(key, tableName: table, bundle: baseBundle, value: key, comment: "")
            if fallback != key { return fallback }
        }
        return key
    }
}


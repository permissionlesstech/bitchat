import Foundation

enum L10n {
    static func string(_ key: String, comment: String) -> String {
        NSLocalizedString(key, comment: comment)
    }

    static func format(_ key: String, comment: String, _ args: CVarArg...) -> String {
        let format = NSLocalizedString(key, comment: comment)
        return String(format: format, locale: Locale.current, arguments: args)
    }
}

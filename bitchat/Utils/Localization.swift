import Foundation

enum L10n {
    static func string(_ key: String, comment: String, _ args: CVarArg...) -> String {
        let basic = NSLocalizedString(key, comment: comment)
        if args.isEmpty {
            return basic
        }
        return String(format: basic, locale: .current, arguments: args)
    }
}

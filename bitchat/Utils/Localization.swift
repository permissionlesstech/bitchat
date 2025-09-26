import Foundation

enum L10n {
    static func string(_ key: String, comment: String, _ args: CVarArg...) -> String {
        let basic = NSLocalizedString(key, bundle: .localization, comment: comment)
        if args.isEmpty {
            return basic
        }
        return String(format: basic, locale: .current, arguments: args)
    }
}

private extension Bundle {
    static var localization: Bundle {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle.main
        #endif
    }
}

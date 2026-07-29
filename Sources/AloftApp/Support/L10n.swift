import Foundation

enum L10n {
    static var bundle: Bundle {
        .module
    }

    static func string(_ key: String) -> String {
        NSLocalizedString(
            key,
            bundle: bundle,
            value: key,
            comment: ""
        )
    }

    static func format(
        _ key: String,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: string(key),
            locale: .current,
            arguments: arguments
        )
    }
}

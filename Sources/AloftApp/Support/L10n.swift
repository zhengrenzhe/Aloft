import Foundation

enum L10n {
    static var bundle: Bundle {
        resolveBundle(
            mainResourceURL: Bundle.main.resourceURL,
            fallback: { .module }
        )
    }

    static func resolveBundle(
        mainResourceURL: URL?,
        fallback: () -> Bundle
    ) -> Bundle {
        if let bundleURL = mainResourceURL?
            .appendingPathComponent(
                "Aloft_AloftApp.bundle"
            ),
           let bundle = Bundle(url: bundleURL) {
            return bundle
        }
        return fallback()
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

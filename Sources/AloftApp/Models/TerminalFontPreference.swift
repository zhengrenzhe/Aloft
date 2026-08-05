import AppKit

@MainActor
enum TerminalFontPreference {
    static let familyStorageKey = "terminalFontFamily"
    static let sizeStorageKey = "terminalFontSize"
    static let systemFamilyIdentifier = "__system_monospaced__"
    static let defaultFamily = systemFamilyIdentifier
    static let defaultSize = Double(NSFont.systemFontSize)
    static let supportedSizeRange = 9.0...32.0

    static var availableFamilies: [String] {
        NSFontManager.shared.availableFontFamilies
            .filter { family in
                guard let font = fixedPitchFont(
                    family: family,
                    size: defaultSize
                ) else {
                    return false
                }
                return font.familyName == family
            }
            .sorted {
                $0.localizedStandardCompare($1)
                    == .orderedAscending
            }
    }

    static func normalizedSize(_ size: Double) -> Double {
        min(
            max(size, supportedSizeRange.lowerBound),
            supportedSizeRange.upperBound
        )
    }

    static func resolve(
        family: String,
        size: Double
    ) -> NSFont {
        let normalizedSize = normalizedSize(size)
        if family != systemFamilyIdentifier,
           let font = fixedPitchFont(
               family: family,
               size: normalizedSize
           ) {
            return font
        }
        return NSFont.monospacedSystemFont(
            ofSize: normalizedSize,
            weight: .regular
        )
    }

    private static func fixedPitchFont(
        family: String,
        size: Double
    ) -> NSFont? {
        guard let font = NSFont(
            name: family,
            size: normalizedSize(size)
        ),
        font.isFixedPitch else {
            return nil
        }
        return font
    }
}

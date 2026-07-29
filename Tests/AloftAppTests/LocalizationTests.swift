import Foundation
import XCTest
@testable import AloftApp

final class LocalizationTests: XCTestCase {
    private let expectedLocalizations: Set<String> = [
        "ar",
        "de",
        "en",
        "es",
        "fr",
        "ja",
        "ko",
        "pt-BR",
        "ru",
        "zh-Hans",
        "zh-Hant",
    ]

    func testResourceBundleContainsEverySupportedLocalization() {
        let packaged = Set(
            L10n.bundle.localizations.map {
                $0.lowercased()
            }
        )
        XCTAssertTrue(
            packaged.isSuperset(
                of: Set(
                    expectedLocalizations.map {
                        $0.lowercased()
                    }
                )
            )
        )
    }

    func testEveryLocalizationHasTheCompleteEnglishKeySet() throws {
        let english = try localization("en")
        XCTAssertFalse(english.isEmpty)

        for identifier in expectedLocalizations {
            let localized = try localization(identifier)
            XCTAssertEqual(
                Set(localized.keys),
                Set(english.keys),
                "Incomplete localization: \(identifier)"
            )
            XCTAssertTrue(
                localized.values.allSatisfy { !$0.isEmpty },
                "Empty translation: \(identifier)"
            )
        }
    }

    func testSimplifiedChineseNameTranslationIsPackaged() throws {
        XCTAssertEqual(
            try localization("zh-Hans")["Name"],
            "名称"
        )
    }

    func testEnglishContainsTerminalV2Keys() throws {
        let v2Keys: Set<String> = [
            "Output View",
            "Terminal",
            "Text",
            "Metal rendering is unavailable. Using compatible rendering.",
            "Terminal rendering is unavailable. Showing text output.",
        ]

        XCTAssertTrue(
            Set(try localization("en").keys)
                .isSuperset(of: v2Keys)
        )
    }

    private func localization(
        _ identifier: String
    ) throws -> [String: String] {
        let url = try XCTUnwrap(
            L10n.bundle.url(
                forResource: "Localizable",
                withExtension: "strings",
                subdirectory: nil,
                localization: identifier
            )
        )
        let propertyList = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url),
            format: nil
        )
        return try XCTUnwrap(propertyList as? [String: String])
    }
}

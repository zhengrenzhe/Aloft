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

    func testPackagedResourceBundleWinsWithoutSwiftPMFallback()
        throws {
        let temporaryRoot = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(
                at: temporaryRoot
            )
        }
        let resourceURL = temporaryRoot
            .appendingPathComponent("Contents")
            .appendingPathComponent("Resources")
        try FileManager.default.createDirectory(
            at: resourceURL,
            withIntermediateDirectories: true
        )
        let packagedBundleURL = resourceURL
            .appendingPathComponent(
                "Aloft_AloftApp.bundle"
            )
        try FileManager.default.copyItem(
            at: L10n.bundle.bundleURL,
            to: packagedBundleURL
        )
        var fallbackCalled = false

        let resolved = L10n.resolveBundle(
            mainResourceURL: resourceURL,
            fallback: {
                fallbackCalled = true
                return .main
            }
        )

        XCTAssertFalse(fallbackCalled)
        XCTAssertEqual(
            resolved.bundleURL.standardizedFileURL,
            packagedBundleURL.standardizedFileURL
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
            "Terminal",
            "Metal rendering is unavailable. Using compatible rendering.",
            "Terminal rendering is unavailable.",
        ]

        XCTAssertTrue(
            Set(try localization("en").keys)
                .isSuperset(of: v2Keys)
        )
    }

    func testEnglishContainsTerminalViewportKeys() throws {
        let keys: Set<String> = [
            "Jump to latest output",
            "New output",
        ]

        XCTAssertTrue(
            Set(try localization("en").keys)
                .isSuperset(of: keys)
        )
    }

    func testEnglishContainsTerminationAlertKeys() throws {
        let keys: Set<String> = [
            "Clear All",
            "Command Exited: %@",
            "Exit status unavailable.",
            "Exited normally with status %@.",
            "Exited with status %@.",
            "Last Termination",
            "Needs Attention",
            "Restart Failed",
            "Running: %lld · Needs attention: %lld",
            "Stop Failed",
            "Stopped intentionally.",
            "Terminated by signal %@ (%@).",
            "Terminated by signal %@.",
        ]

        XCTAssertTrue(
            Set(try localization("en").keys)
                .isSuperset(of: keys)
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

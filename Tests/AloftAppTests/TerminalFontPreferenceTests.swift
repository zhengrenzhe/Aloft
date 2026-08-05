import AppKit
import XCTest
@testable import AloftApp

@MainActor
final class TerminalFontPreferenceTests: XCTestCase {
    func testNormalizedSizeClampsToSupportedRange() {
        XCTAssertEqual(
            TerminalFontPreference.normalizedSize(4),
            9
        )
        XCTAssertEqual(
            TerminalFontPreference.normalizedSize(18),
            18
        )
        XCTAssertEqual(
            TerminalFontPreference.normalizedSize(80),
            32
        )
    }

    func testUnknownFamilyFallsBackToFixedPitchSystemFont() {
        let font = TerminalFontPreference.resolve(
            family: "missing-\(UUID().uuidString)",
            size: 17
        )

        XCTAssertEqual(font.pointSize, 17)
        XCTAssertTrue(font.isFixedPitch)
    }

    func testAvailableFamiliesOnlyContainsUsableFixedPitchFonts() {
        let families = TerminalFontPreference.availableFamilies

        XCTAssertFalse(families.isEmpty)
        XCTAssertEqual(
            families,
            families.sorted {
                $0.localizedStandardCompare($1)
                    == .orderedAscending
            }
        )
        for family in families {
            let font = TerminalFontPreference.resolve(
                family: family,
                size: 13
            )
            XCTAssertEqual(font.familyName, family)
            XCTAssertTrue(font.isFixedPitch, family)
        }
    }
}

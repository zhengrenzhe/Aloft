import AppKit
import XCTest
@testable import AloftApp

final class MenuBarIconPreferenceTests: XCTestCase {
    func testUnsupportedStoredValueFallsBackToProminentDefault() {
        XCTAssertEqual(
            MenuBarIconPreference.resolve("removed-symbol"),
            .bolt
        )
        XCTAssertEqual(
            MenuBarIconPreference.resolve(
                MenuBarIconChoice.terminal.rawValue
            ),
            .terminal
        )
    }

    func testEveryCuratedMenuBarSymbolExistsOnSupportedmacOS() {
        for choice in MenuBarIconChoice.allCases {
            XCTAssertNotNil(
                NSImage(
                    systemSymbolName: choice.systemName,
                    accessibilityDescription: nil
                ),
                "Missing SF Symbol \(choice.systemName)"
            )
        }
    }
}

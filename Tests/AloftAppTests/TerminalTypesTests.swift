import AppKit
import SwiftTerm
import XCTest
@testable import AloftApp

final class TerminalTypesTests: XCTestCase {
    func testTerminalSizeRejectsInvalidOrUnrepresentableWinsize() {
        XCTAssertNil(
            TerminalSize(
                columns: 0,
                rows: 24,
                pixelWidth: 800,
                pixelHeight: 600
            )
        )
        XCTAssertNil(
            TerminalSize(
                columns: 80,
                rows: 0,
                pixelWidth: 800,
                pixelHeight: 600
            )
        )
        XCTAssertNil(
            TerminalSize(
                columns: 65_536,
                rows: 24,
                pixelWidth: 800,
                pixelHeight: 600
            )
        )
        XCTAssertNotNil(
            TerminalSize(
                columns: 80,
                rows: 24,
                pixelWidth: 800,
                pixelHeight: 600
            )
        )
    }

    func testDisplayModeDefaultsToTerminal() {
        XCTAssertEqual(OutputDisplayMode.default, .terminal)
    }

    @MainActor
    func testSwiftTermProductIsLinked() {
        let view = TerminalView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: 800,
                height: 400
            )
        )

        XCTAssertEqual(
            view.frame.size,
            NSSize(width: 800, height: 400)
        )
    }
}

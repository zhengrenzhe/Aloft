import AppKit
import XCTest
@testable import AloftApp

@MainActor
final class TerminalOutputViewTests: XCTestCase {
    func testHostInstallsOneStableSurfaceViewAndResizesIt() {
        let native = NSView(frame: .zero)
        let surface = TerminalSurfaceStub(nativeView: native)
        let host = TerminalHostView(
            surface: surface,
            font: NSFont.monospacedSystemFont(
                ofSize: 13,
                weight: .regular
            )
        )

        host.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(host.subviews, [native])
        XCTAssertEqual(native.frame, host.bounds)
    }

    func testInstallingSameSurfaceDoesNotRecreateNativeView() {
        let native = NSView(frame: .zero)
        let surface = TerminalSurfaceStub(nativeView: native)
        let host = TerminalHostView(
            surface: surface,
            font: NSFont.monospacedSystemFont(
                ofSize: 13,
                weight: .regular
            )
        )

        host.install(
            surface: surface,
            font: NSFont.monospacedSystemFont(
                ofSize: 13,
                weight: .regular
            )
        )

        XCTAssertEqual(host.subviews, [native])
        XCTAssertIdentical(host.subviews.first, native)
    }

    func testInstallingDifferentSurfaceReplacesNativeView() {
        let firstView = NSView(frame: .zero)
        let secondView = NSView(frame: .zero)
        let host = TerminalHostView(
            surface: TerminalSurfaceStub(nativeView: firstView),
            font: NSFont.monospacedSystemFont(
                ofSize: 13,
                weight: .regular
            )
        )
        let replacement = TerminalSurfaceStub(nativeView: secondView)

        host.install(
            surface: replacement,
            font: NSFont.monospacedSystemFont(
                ofSize: 13,
                weight: .regular
            )
        )

        XCTAssertNil(firstView.superview)
        XCTAssertEqual(host.subviews, [secondView])
    }

    func testInstallingSameSurfaceAppliesUpdatedFont() {
        let surface = TerminalSurfaceStub(nativeView: NSView())
        let initialFont = NSFont.monospacedSystemFont(
            ofSize: 13,
            weight: .regular
        )
        let updatedFont = NSFont.monospacedSystemFont(
            ofSize: 19,
            weight: .regular
        )
        let host = TerminalHostView(
            surface: surface,
            font: initialFont
        )

        host.install(
            surface: surface,
            font: updatedFont
        )

        XCTAssertEqual(
            surface.updatedFonts.map(\.pointSize),
            [13, 19]
        )
        XCTAssertEqual(host.subviews, [surface.nativeView])
    }
}

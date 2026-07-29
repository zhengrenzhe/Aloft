import AppKit
import XCTest
@testable import AloftApp

@MainActor
final class TerminalOutputViewTests: XCTestCase {
    func testHostInstallsOneStableSurfaceViewAndResizesIt() {
        let native = NSView(frame: .zero)
        let surface = TerminalSurfaceStub(nativeView: native)
        let host = TerminalHostView(surface: surface)

        host.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(host.subviews, [native])
        XCTAssertEqual(native.frame, host.bounds)
    }

    func testInstallingSameSurfaceDoesNotRecreateNativeView() {
        let native = NSView(frame: .zero)
        let surface = TerminalSurfaceStub(nativeView: native)
        let host = TerminalHostView(surface: surface)

        host.install(surface: surface)

        XCTAssertEqual(host.subviews, [native])
        XCTAssertIdentical(host.subviews.first, native)
    }

    func testInstallingDifferentSurfaceReplacesNativeView() {
        let firstView = NSView(frame: .zero)
        let secondView = NSView(frame: .zero)
        let host = TerminalHostView(
            surface: TerminalSurfaceStub(nativeView: firstView)
        )
        let replacement = TerminalSurfaceStub(nativeView: secondView)

        host.install(surface: replacement)

        XCTAssertNil(firstView.superview)
        XCTAssertEqual(host.subviews, [secondView])
    }
}

import AppKit
import XCTest
@testable import AloftApp

final class AppIconResourceTests: XCTestCase {
    func testPackagedAppIconContainsAHighResolutionRepresentation()
        throws {
        let url = try XCTUnwrap(
            L10n.bundle.url(
                forResource: "AppIcon",
                withExtension: "icns"
            )
        )
        let image = try XCTUnwrap(NSImage(contentsOf: url))

        XCTAssertTrue(
            image.representations.contains {
                $0.pixelsWide >= 256
                    && $0.pixelsHigh >= 256
            }
        )
    }
}

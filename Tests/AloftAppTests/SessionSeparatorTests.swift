import Foundation
import XCTest
@testable import AloftApp

final class SessionSeparatorTests: XCTestCase {
    func testUsesStableUTCFormat() {
        XCTAssertEqual(
            SessionSeparator.line(
                at: Date(timeIntervalSince1970: 0)
            ),
            L10n.format(
                "──── Session started %@ ────",
                "1970-01-01 00:00:00"
            )
        )
    }
}

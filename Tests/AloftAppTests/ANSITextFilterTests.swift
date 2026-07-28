import XCTest
@testable import AloftApp

final class ANSITextFilterTests: XCTestCase {
    func testCSIAndBELTerminatedOSCAreRemovedAcrossEveryBoundary() {
        assertAllByteSplits(
            "\u{001B}[31mred\u{001B}[0m \u{001B}]0;title\u{0007}done",
            produce: "red done"
        )
    }

    func testSTTerminatedOSCAreRemovedAcrossEveryBoundary() {
        assertAllByteSplits(
            "before\u{001B}]8;;https://example.test\u{001B}\\link\u{001B}]8;;\u{001B}\\after",
            produce: "beforelinkafter"
        )
    }

    func testUnsupportedSingleCharacterEscapeConsumesItsFollowingScalar() {
        var filter = ANSITextFilter()

        XCTAssertEqual(filter.consume("a\u{001B}7b"), "ab")
    }

    private func assertAllByteSplits(_ input: String, produce expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let bytes = Array(input.utf8)
        for split in 0...bytes.count {
            var filter = ANSITextFilter()
            let first = filter.consume(String(decoding: bytes[..<split], as: UTF8.self))
            let second = filter.consume(String(decoding: bytes[split...], as: UTF8.self))
            XCTAssertEqual(first + second, expected, "split \(split)", file: file, line: line)
        }
    }
}

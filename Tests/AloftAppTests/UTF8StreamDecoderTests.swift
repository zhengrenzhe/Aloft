import Foundation
import XCTest
@testable import AloftApp

final class UTF8StreamDecoderTests: XCTestCase {
    func testUTF8ScalarSplitAtEveryByteBoundaryIsPreserved() {
        for scalar in ["é", "你", "😀"] {
            let bytes = Array(scalar.utf8)

            for split in 0...bytes.count {
                var decoder = UTF8StreamDecoder()
                let first = decoder.consume(Data(bytes[..<split]))
                let second = decoder.consume(Data(bytes[split...]))

                XCTAssertEqual(first + second + decoder.finish(), scalar, "\(scalar), split \(split)")
            }
        }
    }

    func testMalformedBytesAreReplacedWithoutLosingFollowingText() {
        var decoder = UTF8StreamDecoder()

        XCTAssertEqual(decoder.consume(Data([0xF0, 0x28, 0x8C, 0x28, 0x61])), "�(�(a")
        XCTAssertEqual(decoder.finish(), "")
    }

    func testFinishReplacesAnIncompleteTrailingScalar() {
        var decoder = UTF8StreamDecoder()

        XCTAssertEqual(decoder.consume(Data([0xE4, 0xBD])), "")
        XCTAssertEqual(decoder.finish(), "�")
        XCTAssertEqual(decoder.finish(), "")
    }

    func testIllegalThreeAndFourBytePrefixesAreDecodedImmediately() {
        for (bytes, expected): ([UInt8], String) in [
            ([0xE0, 0x80], "��"),
            ([0xED, 0xA0], "��"),
            ([0xF4, 0x90], "��"),
        ] {
            var decoder = UTF8StreamDecoder()

            XCTAssertEqual(decoder.consume(Data(bytes)), expected)
            XCTAssertEqual(decoder.finish(), "")
        }
    }

    func testInvalidFourByteSecondByteIsNotBufferedForTheNextRead() {
        var decoder = UTF8StreamDecoder()

        XCTAssertEqual(decoder.consume(Data([0xF0])), "")
        XCTAssertEqual(decoder.consume(Data([0x80])), "��")
        XCTAssertEqual(decoder.consume(Data("next".utf8)), "next")
        XCTAssertEqual(decoder.finish(), "")
    }

    func testInvalidContinuationIsDecodedWithoutWaitingForFinish() {
        var decoder = UTF8StreamDecoder()

        XCTAssertEqual(decoder.consume(Data([0xF0])), "")
        XCTAssertEqual(decoder.consume(Data([0x41])), "�A")
        XCTAssertEqual(decoder.finish(), "")
    }
}

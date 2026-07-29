import XCTest
@testable import AloftApp

final class Unicode17Tests: XCTestCase {
    func testEmbeddedUnicode17TablesPassVersionAndIntegrityValidation() {
        XCTAssertEqual(Unicode17Data.version, "17.0.0")
        XCTAssertTrue(Unicode17Data.isValid)
        XCTAssertEqual(
            Unicode17Data.graphemeBreakPropertySHA256,
            "d6b51d1d2ae5c33b451b7ed994b48f1f4dc62b2272a5831e7fd418514a6bae89"
        )
        XCTAssertEqual(
            Unicode17Data.derivedCorePropertiesSHA256,
            "24c7fed1195c482faaefd5c1e7eb821c5ee1fb6de07ecdbaa64b56a99da22c08"
        )
        XCTAssertEqual(
            Unicode17Data.emojiDataSHA256,
            "2cb2bb9455cda83e8481541ecf5b6dfda66a3bb89efa3fa7c5297eccf607b72b"
        )
        XCTAssertEqual(
            Unicode17Data.unicodeDataSHA256,
            "2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c"
        )
        XCTAssertEqual(
            Unicode17Data.normalizationTestSHA256,
            "5019ffd530751a741900c849c0e010332f142a3612234639bd200b82138a87db"
        )
    }

    func testUnicode17SpecificGraphemePropertiesAreEmbedded() {
        XCTAssertEqual(
            Unicode17Data.graphemeBreakClass(of: 0x1ACF),
            .extend,
            "U+1ACF was added to Grapheme_Cluster_Break=Extend in Unicode 17"
        )
        XCTAssertEqual(
            Unicode17Data.graphemeBreakClass(of: 0x11B61),
            .spacingMark,
            "U+11B61 was added to Grapheme_Cluster_Break=SpacingMark in Unicode 17"
        )
        XCTAssertEqual(
            Unicode17Data.indicConjunctBreakClass(of: 0x1019),
            .consonant,
            "Myanmar InCB data changed in Unicode 17"
        )
        XCTAssertEqual(
            Unicode17Data.indicConjunctBreakClass(of: 0x1039),
            .linker,
            "Myanmar InCB data changed in Unicode 17"
        )
    }

    func testPinnedUnicode17NFDHandlesRecursiveReorderingAndHangul() {
        XCTAssertEqual(
            Unicode17Normalizer.normalize([0x1E08]),
            [0x0043, 0x0327, 0x0301]
        )
        XCTAssertEqual(
            Unicode17Normalizer.normalize([0x0061, 0x0315, 0x0300]),
            [0x0061, 0x0300, 0x0315]
        )
        XCTAssertEqual(
            Unicode17Normalizer.normalize([0xAC01]),
            [0x1100, 0x1161, 0x11A8]
        )
    }

    func testAllOfficialUnicode17GraphemeBreakCases() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GraphemeBreakTest",
                withExtension: "txt"
            )
        )
        let contents = try String(contentsOf: url, encoding: .utf8)
        var executedCases = 0

        for (zeroBasedLine, rawLine) in contents.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).enumerated() {
            let body = rawLine.prefix(while: { $0 != "#" })
            let tokens = body.split(whereSeparator: \.isWhitespace)
            guard !tokens.isEmpty else { continue }

            var scalars: [UInt32] = []
            var expectedBoundaries: [Int] = []
            for token in tokens {
                switch token {
                case "÷":
                    if expectedBoundaries.last != scalars.count {
                        expectedBoundaries.append(scalars.count)
                    }
                case "×":
                    break
                default:
                    guard let scalar = UInt32(token, radix: 16) else {
                        XCTFail(
                            "invalid token \(token) on official GraphemeBreakTest line \(zeroBasedLine + 1)"
                        )
                        continue
                    }
                    scalars.append(scalar)
                }
            }

            executedCases += 1
            XCTAssertEqual(
                Unicode17GraphemeSegmenter.boundaries(in: scalars),
                expectedBoundaries,
                "official GraphemeBreakTest line \(zeroBasedLine + 1)"
            )
        }

        XCTAssertEqual(executedCases, 766)
    }

    func testAllOfficialUnicode17CanonicalNormalizationCases() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "NormalizationTest",
                withExtension: "txt"
            )
        )
        let contents = try String(contentsOf: url, encoding: .utf8)
        var executedCases = 0

        for (zeroBasedLine, rawLine) in contents.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).enumerated() {
            let body = rawLine.prefix(while: { $0 != "#" })
            let fields = body.split(separator: ";", omittingEmptySubsequences: false)
            guard fields.count >= 5 else { continue }

            let c1 = try parseScalars(fields[0], line: zeroBasedLine + 1)
            let c2 = try parseScalars(fields[1], line: zeroBasedLine + 1)
            let c3 = try parseScalars(fields[2], line: zeroBasedLine + 1)
            let c4 = try parseScalars(fields[3], line: zeroBasedLine + 1)
            let c5 = try parseScalars(fields[4], line: zeroBasedLine + 1)
            XCTAssertEqual(
                Unicode17Normalizer.normalize(c1),
                c3,
                "NFD(c1) on official NormalizationTest line \(zeroBasedLine + 1)"
            )
            XCTAssertEqual(
                Unicode17Normalizer.normalize(c2),
                c3,
                "NFD(c2) on official NormalizationTest line \(zeroBasedLine + 1)"
            )
            XCTAssertEqual(
                Unicode17Normalizer.normalize(c3),
                c3,
                "NFD(c3) on official NormalizationTest line \(zeroBasedLine + 1)"
            )
            XCTAssertEqual(
                Unicode17Normalizer.normalize(c4),
                c5,
                "NFD(c4) on official NormalizationTest line \(zeroBasedLine + 1)"
            )
            XCTAssertEqual(
                Unicode17Normalizer.normalize(c5),
                c5,
                "NFD(c5) on official NormalizationTest line \(zeroBasedLine + 1)"
            )
            executedCases += 1
        }

        XCTAssertEqual(executedCases, 20_034)
    }

    private func parseScalars(_ field: Substring, line: Int) throws -> [UInt32] {
        try field.split(whereSeparator: \.isWhitespace).map { token in
            try XCTUnwrap(
                UInt32(token, radix: 16),
                "invalid scalar \(token) on official NormalizationTest line \(line)"
            )
        }
    }
}

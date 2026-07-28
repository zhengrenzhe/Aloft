import Foundation
import XCTest
@testable import AloftApp

final class OutputPipelineTests: XCTestCase {
    func testCarriageReturnReplacesDisplayLineButBothRevisionsCanMatch() {
        let entryID = UUID()
        var pipeline = OutputPipeline(entryID: entryID, keywords: ["10%", "20%"], lineLimit: 20_000)

        let update = pipeline.consume(Data("progress 10%\rprogress 20%\n".utf8), at: .distantPast)

        XCTAssertEqual(update.snapshot.committedLines, ["progress 20%"])
        XCTAssertEqual(update.matches.map(\.keyword), ["10%", "20%"])
        XCTAssertEqual(update.snapshot.latestMatch?.line, "progress 20%")
    }

    func testCRLFCommitsTheLineBeforeTheCarriageReturn() {
        var pipeline = OutputPipeline(entryID: UUID(), keywords: [], lineLimit: 20_000)

        let update = pipeline.consume(Data("first\r\nsecond\r\n".utf8), at: .distantPast)

        XCTAssertEqual(update.snapshot.committedLines, ["first", "second"])
        XCTAssertEqual(update.snapshot.currentLine, "")
    }

    func testCRLFSplitAcrossReadsCommitsTheLineBeforeTheCarriageReturn() {
        var pipeline = OutputPipeline(entryID: UUID(), keywords: [], lineLimit: 20_000)

        XCTAssertEqual(pipeline.consume(Data("first\r".utf8), at: .distantPast).snapshot.committedLines, [])
        let update = pipeline.consume(Data("\nsecond\r\n".utf8), at: .distantPast)

        XCTAssertEqual(update.snapshot.committedLines, ["first", "second"])
    }

    func testIsolatedCarriageReturnStillStartsANewProgressRevision() {
        var pipeline = OutputPipeline(entryID: UUID(), keywords: ["10%", "20%"], lineLimit: 20_000)

        let update = pipeline.consume(Data("progress 10%\rprogress 20%\n".utf8), at: .distantPast)

        XCTAssertEqual(update.snapshot.committedLines, ["progress 20%"])
        XCTAssertEqual(update.matches.map(\.keyword), ["10%", "20%"])
    }

    func testKeywordCanCrossReadBoundary() {
        var pipeline = OutputPipeline(entryID: UUID(), keywords: ["ready"], lineLimit: 20_000)

        XCTAssertTrue(pipeline.consume(Data("rea".utf8), at: .distantPast).matches.isEmpty)
        XCTAssertEqual(pipeline.consume(Data("dy\n".utf8), at: .distantPast).matches.map(\.keyword), ["ready"])
    }

    func testKeywordMatchIsDeliveredWithoutWaitingForANewlineOrNextRead() {
        var pipeline = OutputPipeline(entryID: UUID(), keywords: ["ready"], lineLimit: 20_000)

        XCTAssertEqual(pipeline.consume(Data("ready".utf8), at: .distantPast).matches.map(\.keyword), ["ready"])
    }

    func testCombiningTailPresenceCanDisappearAndReappearAcrossReads() {
        var pipeline = OutputPipeline(entryID: UUID(), keywords: ["e"], lineLimit: 20_000)

        XCTAssertEqual(pipeline.consume(Data("e".utf8), at: .distantPast).matches.map(\.keyword), ["e"])
        XCTAssertTrue(pipeline.consume(Data("\u{0301}".utf8), at: .distantPast).matches.isEmpty)
        XCTAssertEqual(pipeline.consume(Data("e".utf8), at: .distantPast).matches.map(\.keyword), ["e"])
    }

    func testZWJTailPresenceCanDisappearAndReappearAcrossReads() {
        var pipeline = OutputPipeline(entryID: UUID(), keywords: ["👩"], lineLimit: 20_000)

        XCTAssertEqual(pipeline.consume(Data("👩".utf8), at: .distantPast).matches.map(\.keyword), ["👩"])
        XCTAssertTrue(pipeline.consume(Data("\u{200D}".utf8), at: .distantPast).matches.isEmpty)
        XCTAssertTrue(pipeline.consume(Data("💻".utf8), at: .distantPast).matches.isEmpty)
        XCTAssertEqual(pipeline.consume(Data("👩".utf8), at: .distantPast).matches.map(\.keyword), ["👩"])
    }

    func testRegionalIndicatorTailPresenceCanDisappearAndReappearAcrossReads() {
        let regionalU = "\u{1F1FA}"
        let regionalS = "\u{1F1F8}"
        var pipeline = OutputPipeline(entryID: UUID(), keywords: [regionalU], lineLimit: 20_000)

        XCTAssertEqual(pipeline.consume(Data(regionalU.utf8), at: .distantPast).matches.map(\.keyword), [regionalU])
        XCTAssertTrue(pipeline.consume(Data(regionalS.utf8), at: .distantPast).matches.isEmpty)
        XCTAssertEqual(pipeline.consume(Data(regionalU.utf8), at: .distantPast).matches.map(\.keyword), [regionalU])
    }

    func testKeywordIsDeduplicatedWithinAnUnchangedLineRevision() {
        var pipeline = OutputPipeline(entryID: UUID(), keywords: ["ready"], lineLimit: 20_000)

        let update = pipeline.consume(Data("ready\n".utf8), at: .distantPast)

        XCTAssertEqual(update.matches.map(\.keyword), ["ready"])
    }

    func testKeywordIsNotRepeatedWhenTheMatchingLineIsAppended() {
        var pipeline = OutputPipeline(entryID: UUID(), keywords: ["ready"], lineLimit: 20_000)

        XCTAssertEqual(pipeline.consume(Data("ready".utf8), at: .distantPast).matches.map(\.keyword), ["ready"])
        XCTAssertTrue(pipeline.consume(Data("!".utf8), at: .distantPast).matches.isEmpty)
    }

    func testANSISequencesAreRemovedBeforeKeywordMatching() {
        var pipeline = OutputPipeline(entryID: UUID(), keywords: ["ready"], lineLimit: 20_000)

        let update = pipeline.consume(Data("\u{001B}[32mready\u{001B}[0m\n".utf8), at: .distantPast)

        XCTAssertEqual(update.matches.map(\.keyword), ["ready"])
        XCTAssertEqual(update.snapshot.committedLines, ["ready"])
    }

    func testClearResetsOutputAndMatchDeduplication() {
        var pipeline = OutputPipeline(entryID: UUID(), keywords: ["ready"], lineLimit: 20_000)
        _ = pipeline.consume(Data("ready".utf8), at: .distantPast)

        pipeline.clear()
        let cleared = pipeline.consume(Data(), at: .distantPast)
        let next = pipeline.consume(Data("ready".utf8), at: .distantPast)

        XCTAssertEqual(cleared.snapshot.committedLines, [])
        XCTAssertEqual(cleared.snapshot.currentLine, "")
        XCTAssertNil(cleared.snapshot.latestMatch)
        XCTAssertEqual(next.matches.map(\.keyword), ["ready"])
    }

    func testSessionSeparatorUsesPOSIXDateFormat() {
        var pipeline = OutputPipeline(entryID: UUID(), keywords: [], lineLimit: 20_000)

        pipeline.insertSessionSeparator(at: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(
            pipeline.consume(Data(), at: .distantPast).snapshot.committedLines,
            ["──── Session started 1970-01-01 00:00:00 ────"]
        )
    }

    func testSessionSeparatorFinalizesOldLineBeforeNewLine() {
        var pipeline = OutputPipeline(entryID: UUID(), keywords: ["oldnew"], lineLimit: 20_000)

        XCTAssertTrue(pipeline.consume(Data("old".utf8), at: .distantPast).matches.isEmpty)
        pipeline.insertSessionSeparator(at: Date(timeIntervalSince1970: 0))
        let update = pipeline.consume(Data("new\n".utf8), at: .distantPast)

        XCTAssertEqual(
            update.snapshot.committedLines,
            [
                "old",
                "──── Session started 1970-01-01 00:00:00 ────",
                "new",
            ]
        )
        XCTAssertTrue(update.matches.isEmpty)
    }

    func testSessionSeparatorCommitsLineBeforeAPendingCarriageReturn() {
        var pipeline = OutputPipeline(entryID: UUID(), keywords: [], lineLimit: 20_000)

        _ = pipeline.consume(Data("old\r".utf8), at: .distantPast)
        pipeline.insertSessionSeparator(at: Date(timeIntervalSince1970: 0))
        let update = pipeline.consume(Data("new\n".utf8), at: .distantPast)

        XCTAssertEqual(
            update.snapshot.committedLines,
            [
                "old",
                "──── Session started 1970-01-01 00:00:00 ────",
                "new",
            ]
        )
    }

    func testSessionSeparatorFinishesIncompleteUTF8InTheOldSession() {
        var pipeline = OutputPipeline(entryID: UUID(), keywords: [], lineLimit: 20_000)

        XCTAssertEqual(pipeline.consume(Data([0xE4, 0xBD]), at: .distantPast).snapshot.currentLine, "")
        pipeline.insertSessionSeparator(at: Date(timeIntervalSince1970: 0))
        let update = pipeline.consume(Data([0xA0, 0x0A]), at: .distantPast)

        XCTAssertEqual(
            update.snapshot.committedLines,
            [
                "�",
                "──── Session started 1970-01-01 00:00:00 ────",
                "�",
            ]
        )
    }

    func testSessionSeparatorDeliversMatchCreatedByUTF8Finish() {
        var pipeline = OutputPipeline(entryID: UUID(), keywords: ["�"], lineLimit: 20_000)

        XCTAssertTrue(pipeline.consume(Data([0xE4, 0xBD]), at: .distantPast).matches.isEmpty)
        let update = pipeline.insertSessionSeparator(at: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(update.matches.map(\.keyword), ["�"])
        XCTAssertEqual(update.snapshot.latestMatch?.keyword, "�")
        XCTAssertEqual(update.snapshot.latestMatch?.line, "�")
        XCTAssertTrue(pipeline.consume(Data(), at: .distantPast).matches.isEmpty)
    }

    func testSessionSeparatorDiscardsIncompleteANSIState() {
        var pipeline = OutputPipeline(entryID: UUID(), keywords: [], lineLimit: 20_000)

        _ = pipeline.consume(Data("before\u{001B}[31".utf8), at: .distantPast)
        pipeline.insertSessionSeparator(at: Date(timeIntervalSince1970: 0))
        let update = pipeline.consume(Data("plain\n".utf8), at: .distantPast)

        XCTAssertEqual(
            update.snapshot.committedLines,
            [
                "before",
                "──── Session started 1970-01-01 00:00:00 ────",
                "plain",
            ]
        )
    }

    func testDuplicateAndEmptyKeywordsDoNotCreateDuplicateMatches() {
        var pipeline = OutputPipeline(entryID: UUID(), keywords: ["", "ready", "ready"], lineLimit: 20_000)

        let update = pipeline.consume(Data("ready\n".utf8), at: .distantPast)

        XCTAssertEqual(update.matches.map(\.keyword), ["ready"])
    }

    func testCanonicalEquivalentKeywordMatchesCombiningScalarAcrossReads() {
        var pipeline = OutputPipeline(entryID: UUID(), keywords: ["café"], lineLimit: 20_000)

        XCTAssertTrue(pipeline.consume(Data("cafe".utf8), at: .distantPast).matches.isEmpty)
        let update = pipeline.consume(Data("\u{0301}\n".utf8), at: .distantPast)

        XCTAssertEqual(update.matches.map(\.keyword), ["café"])
        XCTAssertEqual(update.snapshot.committedLines, ["cafe\u{0301}"])
    }

    func testCanonicalEquivalentDecomposedKeywordMatchesComposedOutput() {
        var pipeline = OutputPipeline(entryID: UUID(), keywords: ["cafe\u{0301}"], lineLimit: 20_000)

        let update = pipeline.consume(Data("café\n".utf8), at: .distantPast)

        XCTAssertEqual(update.matches.map(\.keyword), ["cafe\u{0301}"])
    }

    func testOverlappingPrefixAndSelfOverlappingKeywordsMatchOncePerRevision() {
        var pipeline = OutputPipeline(entryID: UUID(), keywords: ["aba", "abab", "aba"], lineLimit: 20_000)

        let update = pipeline.consume(Data("ababab\n".utf8), at: .distantPast)

        XCTAssertEqual(update.matches.map(\.keyword), ["aba", "abab"])
    }

    func testCanonicallyReorderedCombiningMarksMatchInOneReadAndAcrossReads() {
        let keyword = "a\u{0300}\u{0315}"
        let output = "a\u{0315}\u{0300}"
        XCTAssertTrue(output.contains(keyword))

        XCTAssertEqual(matches(for: output, keywords: [keyword], splitByScalar: false), [keyword])
        XCTAssertEqual(matches(for: output, keywords: [keyword], splitByScalar: true), [keyword])
    }

    func testCanonicallyEquivalentPrecomposedAndDecomposedCharactersMatch() {
        let keyword = "\u{1E08}"
        let output = "\u{0106}\u{0327}"
        XCTAssertTrue(output.contains(keyword))

        XCTAssertEqual(matches(for: output, keywords: [keyword], splitByScalar: false), [keyword])
        XCTAssertEqual(matches(for: output, keywords: [keyword], splitByScalar: true), [keyword])
    }

    func testKeywordMatchingDoesNotCrossCharacterBoundaries() {
        for (output, keyword) in [
            ("é", "e"),
            ("é", "\u{0301}"),
            ("café", "cafe"),
            ("\u{1E08}", "C"),
        ] {
            XCTAssertFalse(output.contains(keyword), "\(output), \(keyword)")
            XCTAssertTrue(matches(for: output, keywords: [keyword], splitByScalar: false).isEmpty)
            XCTAssertTrue(matches(for: output, keywords: [keyword], splitByScalar: true).isEmpty)
        }
    }

    func testGeneratedCharacterAwareDifferentialMatchesStringContains() {
        let marks = ["\u{0300}", "\u{0315}", "\u{035C}"]
        let canonicalPermutations = permutations(of: marks).map { "a" + $0.joined() }
        let lines = canonicalPermutations + [
            "café",
            "cafe\u{0301}",
            "\u{1E08}",
            "\u{0106}\u{0327}",
            "ready",
            "😀中文",
            "ababab",
        ]
        let keywords = canonicalPermutations + [
            "café",
            "cafe\u{0301}",
            "cafe",
            "e",
            "\u{0301}",
            "\u{1E08}",
            "\u{0106}\u{0327}",
            "C",
            "ready",
            "ea",
            "😀",
            "中",
            "aba",
            "abab",
        ]

        XCTAssertEqual(lines.count * keywords.count, 260)
        for line in lines {
            let expected = keywords.filter { line.contains($0) }
            XCTAssertEqual(
                Set(matches(for: line, keywords: keywords, splitByScalar: false)),
                Set(expected),
                "line: \(line)"
            )
        }
    }

    func testCrossReadTransitionDifferentialMatchesFinalCharacterPresence() {
        let cases: [(line: String, keyword: String)] = [
            ("e\u{0301}e", "e"),
            ("👩\u{200D}💻👩", "👩"),
            ("\u{1F1FA}\u{1F1F8}\u{1F1FA}", "\u{1F1FA}"),
            ("a\u{0315}\u{0300}", "a\u{0300}\u{0315}"),
        ]

        for testCase in cases {
            var pipeline = OutputPipeline(entryID: UUID(), keywords: [testCase.keyword], lineLimit: 20_000)
            var events: [KeywordMatchEvent] = []
            for scalar in testCase.line.unicodeScalars {
                events.append(contentsOf: pipeline.consume(Data(String(scalar).utf8), at: .distantPast).matches)
            }
            events.append(contentsOf: pipeline.consume(Data("\n".utf8), at: .distantPast).matches)

            XCTAssertEqual(!events.isEmpty, testCase.line.contains(testCase.keyword), "line: \(testCase.line)")
        }
    }

    func testUAX29BoundaryClassesMatchSwiftCharacterSegmentationAcrossScalarReads() {
        let joinedClusters: [(line: String, excludedKeyword: String)] = [
            ("a\u{0301}", "a"), // Extend
            ("👩\u{200D}💻", "👩"), // ZWJ + Extended_Pictographic
            ("\u{1F1FA}\u{1F1F8}", "\u{1F1FA}"), // Regional_Indicator
            ("\u{1100}\u{1161}\u{11A8}", "\u{1100}"), // Hangul L/V/T
            ("\u{0915}\u{093E}", "\u{0915}"), // SpacingMark
            ("\u{0600}a", "a"), // Prepend
        ]

        for testCase in joinedClusters {
            XCTAssertFalse(testCase.line.contains(testCase.excludedKeyword), "line: \(testCase.line)")
            XCTAssertTrue(matches(for: testCase.line, keywords: [testCase.excludedKeyword], splitByScalar: false).isEmpty)
            XCTAssertEqual(matches(for: testCase.line, keywords: [testCase.line], splitByScalar: true), [testCase.line])
        }

        let controls = "a\u{0001}b"
        XCTAssertTrue(controls.contains("a"))
        XCTAssertTrue(controls.contains("\u{0001}"))
        XCTAssertTrue(controls.contains("b"))
        XCTAssertEqual(
            Set(matches(for: controls, keywords: ["a", "\u{0001}", "b"], splitByScalar: true)),
            ["a", "\u{0001}", "b"]
        )
    }

    func testNineteenThousandTwoHundredEightCrossReadTransitionsMatchStringContains() {
        let cases: [(chunks: [String], keyword: String)] = [
            (["e", "\u{0301}", "e"], "e"),
            (["👩", "\u{200D}", "💻", "👩"], "👩"),
            (["\u{1F1FA}", "\u{1F1F8}", "\u{1F1FA}"], "\u{1F1FA}"),
            (["a", "\u{0315}", "\u{0300}"], "a\u{0300}\u{0315}"),
        ]
        var scenarioCount = 0

        for _ in 0..<4_802 {
            for testCase in cases {
                scenarioCount += 1
                var pipeline = OutputPipeline(entryID: UUID(), keywords: [testCase.keyword], lineLimit: 20_000)
                var line = ""
                var wasPresent = false

                for chunk in testCase.chunks {
                    line.append(chunk)
                    let events = pipeline.consume(Data(chunk.utf8), at: .distantPast).matches
                    let isPresent = line.contains(testCase.keyword)
                    XCTAssertEqual(events.map(\.keyword), isPresent && !wasPresent ? [testCase.keyword] : [])
                    wasPresent = isPresent
                }
            }
        }

        XCTAssertEqual(scenarioCount, 19_208)
    }

    func testBufferKeepsLatestTwentyThousandCommittedLines() {
        var pipeline = OutputPipeline(entryID: UUID(), keywords: [], lineLimit: 20_000)
        let text = (0..<20_005).map(String.init).joined(separator: "\n") + "\n"

        let snapshot = pipeline.consume(Data(text.utf8), at: .distantPast).snapshot

        XCTAssertEqual(snapshot.committedLines.count, 20_000)
        XCTAssertEqual(snapshot.committedLines.first, "5")
        XCTAssertEqual(snapshot.committedLines.last, "20004")
    }

    private func matches(for line: String, keywords: [String], splitByScalar: Bool) -> [String] {
        var pipeline = OutputPipeline(entryID: UUID(), keywords: keywords, lineLimit: 20_000)
        if splitByScalar {
            return (line + "\n").unicodeScalars.flatMap { scalar in
                pipeline.consume(Data(String(scalar).utf8), at: .distantPast).matches.map(\.keyword)
            }
        }
        return pipeline.consume(Data((line + "\n").utf8), at: .distantPast).matches.map(\.keyword)
    }

    private func permutations(of values: [String]) -> [[String]] {
        guard let first = values.first else { return [[]] }
        return permutations(of: Array(values.dropFirst())).flatMap { permutation in
            (0...permutation.count).map { index in
                var result = permutation
                result.insert(first, at: index)
                return result
            }
        }
    }
}

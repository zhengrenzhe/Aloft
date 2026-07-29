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
            [epochSessionSeparator()]
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
                epochSessionSeparator(),
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
                epochSessionSeparator(),
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
                epochSessionSeparator(),
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
                epochSessionSeparator(),
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
        XCTAssertEqual(matches(for: output, keywords: [keyword], splitByScalar: false), [keyword])
        XCTAssertEqual(matches(for: output, keywords: [keyword], splitByScalar: true), [keyword])
    }

    func testCanonicallyEquivalentPrecomposedAndDecomposedCharactersMatch() {
        let keyword = "\u{1E08}"
        let output = "\u{0106}\u{0327}"
        XCTAssertEqual(matches(for: output, keywords: [keyword], splitByScalar: false), [keyword])
        XCTAssertEqual(matches(for: output, keywords: [keyword], splitByScalar: true), [keyword])
    }

    func testKeywordMatchingDoesNotCrossUAX17TokenBoundaries() {
        for (output, keyword) in [
            ("é", "e"),
            ("é", "\u{0301}"),
            ("café", "cafe"),
            ("\u{1E08}", "C"),
        ] {
            XCTAssertTrue(matches(for: output, keywords: [keyword], splitByScalar: false).isEmpty)
            XCTAssertTrue(matches(for: output, keywords: [keyword], splitByScalar: true).isEmpty)
        }
    }

    func testGeneratedUAX17TokenCasesMatchExplicitExpectedKeywords() {
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
            let expected: Set<String>
            if hasSameScalars(line, as: "café") || hasSameScalars(line, as: "cafe\u{0301}") {
                expected = ["café", "cafe\u{0301}"]
            } else if hasSameScalars(line, as: "\u{1E08}") || hasSameScalars(line, as: "\u{0106}\u{0327}") {
                expected = ["\u{1E08}", "\u{0106}\u{0327}"]
            } else if line == "ready" {
                expected = ["ready", "e", "ea"]
            } else if line == "😀中文" {
                expected = ["😀", "中"]
            } else if line == "ababab" {
                expected = ["aba", "abab"]
            } else {
                expected = Set(canonicalPermutations)
            }
            XCTAssertEqual(
                Set(matches(for: line, keywords: keywords, splitByScalar: false)),
                expected,
                "line: \(line)"
            )
        }
    }

    func testCrossReadUAX17TokenTransitionsMatchExplicitPresence() {
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

            XCTAssertFalse(events.isEmpty, "line: \(testCase.line)")
        }
    }

    func testUAX17BoundaryClassesMatchTokenExpectationsAcrossScalarReads() {
        let joinedClusters: [(line: String, excludedKeyword: String)] = [
            ("a\u{0301}", "a"), // Extend
            ("👩\u{200D}💻", "👩"), // ZWJ + Extended_Pictographic
            ("\u{1F1FA}\u{1F1F8}", "\u{1F1FA}"), // Regional_Indicator
            ("\u{1100}\u{1161}\u{11A8}", "\u{1100}"), // Hangul L/V/T
            ("\u{0915}\u{093E}", "\u{0915}"), // SpacingMark
            ("\u{0600}a", "a"), // Prepend
        ]

        for testCase in joinedClusters {
            XCTAssertTrue(matches(for: testCase.line, keywords: [testCase.excludedKeyword], splitByScalar: false).isEmpty)
            XCTAssertEqual(matches(for: testCase.line, keywords: [testCase.line], splitByScalar: true), [testCase.line])
        }

        let controls = "a\u{0001}b"
        XCTAssertEqual(
            Set(matches(for: controls, keywords: ["a", "\u{0001}", "b"], splitByScalar: true)),
            ["a", "\u{0001}", "b"]
        )
    }

    func testUnicode17AddedExtendScalarUsesPinnedBoundaryData() {
        let cluster = "a\u{1ACF}"

        XCTAssertTrue(
            matches(
                for: cluster,
                keywords: ["a"],
                splitByScalar: false
            ).isEmpty
        )
        for splitByScalar in [false, true] {
            XCTAssertEqual(
                matches(
                    for: cluster,
                    keywords: [cluster],
                    splitByScalar: splitByScalar
                ),
                [cluster]
            )
        }
    }

    func testFourCrossReadUAX17TokenPresenceTransitions() {
        let cases: [(chunks: [String], keyword: String, expectedPresence: [Bool])] = [
            (["e", "\u{0301}", "e"], "e", [true, false, true]),
            (["👩", "\u{200D}", "💻", "👩"], "👩", [true, false, false, true]),
            (["\u{1F1FA}", "\u{1F1F8}", "\u{1F1FA}"], "\u{1F1FA}", [true, false, true]),
            (["a", "\u{0315}", "\u{0300}"], "a\u{0300}\u{0315}", [false, false, true]),
        ]
        for testCase in cases {
            var pipeline = OutputPipeline(entryID: UUID(), keywords: [testCase.keyword], lineLimit: 20_000)
            var wasPresent = false

            for (index, chunk) in testCase.chunks.enumerated() {
                let events = pipeline.consume(Data(chunk.utf8), at: .distantPast).matches
                let isPresent = testCase.expectedPresence[index]
                XCTAssertEqual(events.map(\.keyword), isPresent && !wasPresent ? [testCase.keyword] : [])
                wasPresent = isPresent
            }
        }
    }

    func testUAX17IndicConjunctKeywordMatchesAsOneTokenInOneAndScalarReads() {
        let conjunct = "\u{0915}\u{094D}\u{0924}"

        for splitByScalar in [false, true] {
            let events = matchEvents(for: conjunct, keywords: [conjunct], splitByScalar: splitByScalar)
            XCTAssertEqual(events.map(\.keyword), [conjunct])
            XCTAssertEqual(events.map(\.line), [conjunct])
        }
    }

    func testUAX17IndicConjunctDoesNotMatchItsConsonantPrefixInOneRead() {
        let conjunct = "\u{0915}\u{094D}\u{0924}"
        let prefix = "\u{0915}"
        XCTAssertTrue(matchEvents(for: conjunct, keywords: [prefix], splitByScalar: false).isEmpty)
    }

    func testUAX17MyanmarGB9cClusterMatchesInOneAndScalarReads() {
        let conjunct = "\u{1019}\u{1039}\u{1018}"

        for splitByScalar in [false, true] {
            let events = matchEvents(for: conjunct, keywords: [conjunct], splitByScalar: splitByScalar)
            XCTAssertEqual(events.map(\.keyword), [conjunct])
            XCTAssertEqual(events.map(\.line), [conjunct])
        }
    }

    func testUAX17MyanmarGB9cClusterDoesNotMatchHostSwiftSubranges() {
        let cluster = "\u{1019}\u{1039}\u{1018}"
        let firstHostSwiftSubrange = "\u{1019}\u{1039}"
        let secondHostSwiftSubrange = "\u{1018}"

        XCTAssertTrue(
            matchEvents(
                for: cluster,
                keywords: [firstHostSwiftSubrange, secondHostSwiftSubrange],
                splitByScalar: false
            ).isEmpty
        )
    }

    func testUAX17GB11PositiveEmojiZWJKeywordMatchesInOneAndScalarReads() {
        let emoji = "👩\u{200D}💻"

        for splitByScalar in [false, true] {
            let events = matchEvents(for: emoji, keywords: [emoji], splitByScalar: splitByScalar)
            XCTAssertEqual(events.map(\.keyword), [emoji])
            XCTAssertEqual(events.map(\.line), [emoji])
        }
    }

    func testUAX17GB11PostZWJExtendBreaksBeforeEmojiInOneAndScalarReads() {
        let line = "👩\u{200D}\u{0301}💻"
        let laptop = "💻"

        for splitByScalar in [false, true] {
            let events = matchEvents(for: line, keywords: [laptop], splitByScalar: splitByScalar)
            XCTAssertEqual(events.map(\.keyword), [laptop])
            XCTAssertEqual(events.map(\.line), [line])
        }
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
        matchEvents(for: line, keywords: keywords, splitByScalar: splitByScalar).map(\.keyword)
    }

    private func hasSameScalars(_ lhs: String, as rhs: String) -> Bool {
        lhs.unicodeScalars.elementsEqual(rhs.unicodeScalars)
    }

    private func matchEvents(for line: String, keywords: [String], splitByScalar: Bool) -> [KeywordMatchEvent] {
        var pipeline = OutputPipeline(entryID: UUID(), keywords: keywords, lineLimit: 20_000)
        if splitByScalar {
            return (line + "\n").unicodeScalars.flatMap { scalar in
                pipeline.consume(Data(String(scalar).utf8), at: .distantPast).matches
            }
        }
        return pipeline.consume(Data((line + "\n").utf8), at: .distantPast).matches
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

private func epochSessionSeparator() -> String {
    L10n.format(
        "──── Session started %@ ────",
        "1970-01-01 00:00:00"
    )
}

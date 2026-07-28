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

    func testKeywordCanCrossReadBoundary() {
        var pipeline = OutputPipeline(entryID: UUID(), keywords: ["ready"], lineLimit: 20_000)

        XCTAssertTrue(pipeline.consume(Data("rea".utf8), at: .distantPast).matches.isEmpty)
        XCTAssertEqual(pipeline.consume(Data("dy\n".utf8), at: .distantPast).matches.map(\.keyword), ["ready"])
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

    func testBufferKeepsLatestTwentyThousandCommittedLines() {
        var pipeline = OutputPipeline(entryID: UUID(), keywords: [], lineLimit: 20_000)
        let text = (0..<20_005).map(String.init).joined(separator: "\n") + "\n"

        let snapshot = pipeline.consume(Data(text.utf8), at: .distantPast).snapshot

        XCTAssertEqual(snapshot.committedLines.count, 20_000)
        XCTAssertEqual(snapshot.committedLines.first, "5")
        XCTAssertEqual(snapshot.committedLines.last, "20004")
    }
}

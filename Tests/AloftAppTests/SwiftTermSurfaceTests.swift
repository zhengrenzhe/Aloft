import AppKit
import Foundation
import SwiftTerm
import XCTest
@testable import AloftApp

@MainActor
final class SwiftTermSurfaceTests: XCTestCase {
    func testUpdateFontChangesTerminalRenderingFont() {
        let callbacks = TerminalCallbacksRecorder()
        let surface = SwiftTermSurface(
            callbacks: callbacks.callbacks
        )
        let font = NSFont.monospacedSystemFont(
            ofSize: 19,
            weight: .regular
        )

        surface.updateFont(font)

        XCTAssertEqual(
            surface.terminalViewForTesting.font.pointSize,
            19
        )
        XCTAssertEqual(
            surface.terminalViewForTesting.font.fontName,
            font.fontName
        )
    }

    func testTerminalViewFeedRunsOnMainThread() async {
        let callbacks = TerminalCallbacksRecorder()
        let feedThreads = BooleanRecorder()
        let surface = SwiftTermSurface(
            callbacks: callbacks.callbacks,
            beforeViewFeed: {
                feedThreads.append(Thread.isMainThread)
            }
        )
        let generation = UUID()
        surface.prepare(generation: generation)
        surface.promote(
            generation: generation,
            at: Date(timeIntervalSince1970: 0)
        )
        surface.feed(
            Data("\u{1b}[36mcolored\u{1b}[0m".utf8),
            generation: generation
        )

        await surface.waitUntilIdle()

        XCTAssertFalse(feedThreads.values.isEmpty)
        XCTAssertTrue(feedThreads.values.allSatisfy(\.self))
    }

    func testTerminalProtocolReplyUsesActiveGeneration() async {
        let callbacks = TerminalCallbacksRecorder()
        let surface = SwiftTermSurface(
            callbacks: callbacks.callbacks
        )
        let generation = UUID()
        surface.prepare(generation: generation)
        surface.promote(
            generation: generation,
            at: Date(timeIntervalSince1970: 0)
        )
        surface.feed(
            Data("\u{1b}[6n".utf8),
            generation: generation
        )

        await surface.waitUntilIdle()

        let reply = callbacks.replies.first
        XCTAssertEqual(reply?.generation, generation)
        XCTAssertTrue(
            reply?.data.starts(with: Data("\u{1b}[".utf8))
                == true
        )
    }

    func testParserPreservesANSIAndSplitUTF8CellState() async {
        let callbacks = TerminalCallbacksRecorder()
        let surface = SwiftTermSurface(
            callbacks: callbacks.callbacks
        )
        let generation = UUID()
        surface.prepare(generation: generation)
        surface.promote(
            generation: generation,
            at: Date(timeIntervalSince1970: 0)
        )
        let bytes = Array("🙂".utf8)
        surface.feed(
            Data("\u{1b}[31mA".utf8) + Data(bytes.prefix(2)),
            generation: generation
        )
        surface.feed(
            Data(bytes.dropFirst(2)),
            generation: generation
        )

        await surface.waitUntilIdle()

        let terminal = surface.terminalViewForTesting.getTerminal()
        let row = terminal.buffer.y
        let line = terminal.getLine(row: row)
        let lineText = line?.translateToString(
            trimRight: true,
            skipNullCellsFollowingWide: true,
            characterProvider: terminal.getCharacter(for:)
        ) ?? ""
        XCTAssertTrue(
            lineText.contains("A🙂"),
            "Parsed row was \(lineText.debugDescription)"
        )
        XCTAssertEqual(
            terminal.getCharData(col: 0, row: row)?.attribute.fg,
            .ansi256(code: 1)
        )
    }

    func testScrollbackClearSeparatorAndDiscardLifecycle() async {
        let callbacks = TerminalCallbacksRecorder()
        let surface = SwiftTermSurface(
            callbacks: callbacks.callbacks
        )
        let firstGeneration = UUID()
        surface.prepare(generation: firstGeneration)
        surface.feed(
            Data("kept".utf8),
            generation: firstGeneration
        )
        surface.promote(
            generation: firstGeneration,
            at: Date(timeIntervalSince1970: 0)
        )
        let discardedGeneration = UUID()
        surface.prepare(generation: discardedGeneration)
        surface.feed(
            Data("discarded".utf8),
            generation: discardedGeneration
        )
        surface.discard(generation: discardedGeneration)
        let lines = (0..<20_050)
            .map { "line-\($0)\r\n" }
            .joined()
        surface.feed(
            Data(lines.utf8),
            generation: firstGeneration
        )

        await surface.waitUntilIdle()

        let terminal = surface.terminalViewForTesting.getTerminal()
        XCTAssertGreaterThan(terminal.buffer.totalLinesTrimmed, 0)
        XCTAssertFalse(
            visibleTerminalText(terminal).contains("discarded")
        )

        surface.clear()
        await surface.waitUntilIdle()

        XCTAssertEqual(
            visibleTerminalText(terminal)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            ""
        )
    }

    func testRestartAddsOneSharedSeparatorAndPreservesHistory()
        async {
        let callbacks = TerminalCallbacksRecorder()
        let surface = SwiftTermSurface(
            callbacks: callbacks.callbacks
        )
        let firstGeneration = UUID()
        let firstDate = Date(timeIntervalSince1970: 0)
        surface.prepare(generation: firstGeneration)
        surface.promote(
            generation: firstGeneration,
            at: firstDate
        )
        surface.feed(
            Data("first history".utf8),
            generation: firstGeneration
        )
        let secondGeneration = UUID()
        let secondDate = Date(timeIntervalSince1970: 1)
        surface.prepare(generation: secondGeneration)
        surface.feed(
            Data("second history".utf8),
            generation: secondGeneration
        )
        surface.promote(
            generation: secondGeneration,
            at: secondDate
        )

        await surface.waitUntilIdle()

        let text = visibleTerminalText(
            surface.terminalViewForTesting.getTerminal()
        )
        XCTAssertTrue(
            text.contains("first history"),
            "Terminal text was \(text.debugDescription)"
        )
        XCTAssertTrue(
            text.contains("second history"),
            "Terminal text was \(text.debugDescription)"
        )
        XCTAssertEqual(
            occurrences(
                of: SessionSeparator.line(at: firstDate),
                in: text
            ),
            1,
            "Terminal text was \(text.debugDescription)"
        )
        XCTAssertEqual(
            occurrences(
                of: SessionSeparator.line(at: secondDate),
                in: text
            ),
            1,
            "Terminal text was \(text.debugDescription)"
        )
    }

    func testRestartReturnsScrolledViewportToNewestOutput() async {
        let callbacks = TerminalCallbacksRecorder()
        let surface = SwiftTermSurface(
            callbacks: callbacks.callbacks
        )
        let firstGeneration = UUID()
        surface.prepare(generation: firstGeneration)
        surface.promote(
            generation: firstGeneration,
            at: Date(timeIntervalSince1970: 0)
        )
        let history = (0..<200)
            .map { "history-\($0)\r\n" }
            .joined()
        surface.feed(
            Data(history.utf8),
            generation: firstGeneration
        )
        await surface.waitUntilIdle()

        let view = surface.terminalViewForTesting
        view.scroll(toPosition: 0)
        XCTAssertEqual(view.scrollPosition, 0)

        let secondGeneration = UUID()
        surface.prepare(generation: secondGeneration)
        surface.feed(
            Data("newest-after-restart\r\n".utf8),
            generation: secondGeneration
        )
        surface.promote(
            generation: secondGeneration,
            at: Date(timeIntervalSince1970: 1)
        )
        await surface.waitUntilIdle()

        let terminal = view.getTerminal()
        let bufferedText = String(
            decoding: terminal.getBufferAsData(),
            as: UTF8.self
        )
        XCTAssertTrue(
            bufferedText.contains("newest-after-restart"),
            "The PTY bytes did not reach SwiftTerm's buffer."
        )
        XCTAssertEqual(view.scrollPosition, 1)
        XCTAssertTrue(
            visibleTerminalText(terminal)
                .contains("newest-after-restart")
        )
    }

    func testDiscardingActiveGenerationRejectsLateFeed() async {
        let callbacks = TerminalCallbacksRecorder()
        let surface = SwiftTermSurface(
            callbacks: callbacks.callbacks
        )
        let generation = UUID()
        surface.prepare(generation: generation)
        surface.promote(
            generation: generation,
            at: Date(timeIntervalSince1970: 0)
        )
        await surface.waitUntilIdle()

        surface.discard(generation: generation)
        surface.feed(
            Data("late-after-discard".utf8),
            generation: generation
        )
        await surface.waitUntilIdle()

        XCTAssertFalse(
            visibleTerminalText(
                surface.terminalViewForTesting.getTerminal()
            ).contains("late-after-discard")
        )
    }

    func testRendererStateMapsMetalAndFallbackOutcomes() {
        let callbacks = TerminalCallbacksRecorder()
        let metal = SwiftTermSurface(
            callbacks: callbacks.callbacks,
            metalActivation: { _ in true }
        )
        metal.activateRendererForTesting()
        XCTAssertEqual(metal.rendererState, .metal)

        let inactive = SwiftTermSurface(
            callbacks: callbacks.callbacks,
            metalActivation: { _ in false }
        )
        inactive.activateRendererForTesting()
        guard case .coreGraphicsFallback(let inactiveReason) =
                inactive.rendererState else {
            return XCTFail("Expected CoreGraphics fallback")
        }
        XCTAssertFalse(inactiveReason.isEmpty)

        let failed = SwiftTermSurface(
            callbacks: callbacks.callbacks,
            metalActivation: { _ in
                throw TestMetalActivationError.failed
            }
        )
        failed.activateRendererForTesting()
        guard case .coreGraphicsFallback(let failedReason) =
                failed.rendererState else {
            return XCTFail("Expected CoreGraphics fallback")
        }
        XCTAssertTrue(failedReason.contains("test activation failed"))
    }

    func testDisposeRejectsQueuedFeedReplyAndResizeWork() async {
        let callbacks = TerminalCallbacksRecorder()
        let gate = SurfaceOperationGate()
        let surface = SwiftTermSurface(
            callbacks: callbacks.callbacks,
            beforeOperation: gate.waitIfClosed
        )
        let generation = UUID()
        surface.prepare(generation: generation)
        surface.promote(
            generation: generation,
            at: Date(timeIntervalSince1970: 0)
        )
        await surface.waitUntilIdle()
        let textBeforeDisposal = visibleTerminalText(
            surface.terminalViewForTesting.getTerminal()
        )

        gate.close()
        surface.feed(
            Data("queued-after-dispose".utf8),
            generation: generation
        )
        surface.send(
            source: surface.terminalViewForTesting,
            data: Array("reply".utf8)[...]
        )
        surface.resize(
            TerminalSize(
                columns: 90,
                rows: 30,
                pixelWidth: 900,
                pixelHeight: 600
            )!,
            generation: generation
        )
        surface.dispose()
        gate.open()
        await surface.waitUntilIdle()

        XCTAssertEqual(
            visibleTerminalText(
                surface.terminalViewForTesting.getTerminal()
            ),
            textBeforeDisposal
        )
        XCTAssertTrue(callbacks.replies.isEmpty)
        XCTAssertTrue(callbacks.resizes.isEmpty)
    }
}

private final class BooleanRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []

    var values: [Bool] {
        lock.withLock { storage }
    }

    func append(_ value: Bool) {
        lock.withLock {
            storage.append(value)
        }
    }
}

private enum TestMetalActivationError: LocalizedError {
    case failed

    var errorDescription: String? {
        "test activation failed"
    }
}

private final class TerminalCallbacksRecorder: @unchecked Sendable {
    struct Reply: Equatable {
        let data: Data
        let generation: UUID
    }

    struct Resize: Equatable {
        let size: TerminalSize
        let generation: UUID
    }

    private let lock = NSLock()
    private var recordedReplies: [Reply] = []
    private var recordedResizes: [Resize] = []

    var callbacks: TerminalSurfaceCallbacks {
        TerminalSurfaceCallbacks(
            writeProtocolReply: { [weak self] data, generation in
                self?.recordReply(data, generation: generation)
            },
            resizePTY: { [weak self] size, generation in
                self?.recordResize(size, generation: generation)
            }
        )
    }

    var replies: [Reply] {
        withLock { recordedReplies }
    }

    var resizes: [Resize] {
        withLock { recordedResizes }
    }

    private func recordReply(_ data: Data, generation: UUID) {
        withLock {
            recordedReplies.append(
                Reply(data: data, generation: generation)
            )
        }
    }

    private func recordResize(
        _ size: TerminalSize,
        generation: UUID
    ) {
        withLock {
            recordedResizes.append(
                Resize(size: size, generation: generation)
            )
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class SurfaceOperationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = true

    func close() {
        condition.lock()
        isOpen = false
        condition.unlock()
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }

    func waitIfClosed() {
        condition.lock()
        while !isOpen {
            condition.wait()
        }
        condition.unlock()
    }
}

private func visibleTerminalText(_ terminal: Terminal) -> String {
    (0..<terminal.rows)
        .compactMap { terminal.getLine(row: $0) }
        .map {
            $0.translateToString(
                trimRight: true,
                skipNullCellsFollowingWide: true,
                characterProvider: terminal.getCharacter(for:)
            )
        }
        .joined(separator: "\n")
}

private func occurrences(of needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
}

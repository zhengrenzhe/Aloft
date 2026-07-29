import AppKit
import SwiftTerm
import XCTest
@testable import AloftApp

@MainActor
final class ReadOnlySwiftTermViewTests: XCTestCase {
    func testBlocksUserInputAndPasteWithoutReplacingTerminalDelegate()
        throws {
        let delegate = TerminalDelegateRecorder()
        let view = ReadOnlySwiftTermView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: 800,
                height: 400
            )
        )
        view.terminalDelegate = delegate

        view.insertText(
            "blocked",
            replacementRange: NSRange(location: 0, length: 0)
        )
        view.setMarkedText(
            "composition",
            selectedRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: 0, length: 0)
        )
        view.paste(self)

        XCTAssertTrue(delegate.sentData.isEmpty)
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertFalse(view.allowMouseReporting)
        XCTAssertEqual(view.linkReporting, .none)
        let pasteItem = NSMenuItem(
            title: "Paste",
            action: #selector(view.paste(_:)),
            keyEquivalent: ""
        )
        XCTAssertFalse(
            view.validateUserInterfaceItem(pasteItem)
        )
    }

    func testFiltersKeyboardEventsOnlyWhileItIsFirstResponder()
        throws {
        let view = ReadOnlySwiftTermView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: 800,
                height: 400
            )
        )
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        XCTAssertTrue(window.makeFirstResponder(view))
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "x",
                charactersIgnoringModifiers: "x",
                isARepeat: false,
                keyCode: 7
            )
        )

        XCTAssertNil(view.filterUserInputEvent(event))
        window.makeFirstResponder(nil)
        XCTAssertTrue(view.filterUserInputEvent(event) === event)
    }

    func testWindowAttachmentCallbackRunsAfterMovingToWindow() {
        let view = ReadOnlySwiftTermView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: 800,
                height: 400
            )
        )
        var callbackWindows: [NSWindow?] = []
        view.onWindowAttachment = {
            callbackWindows.append(view.window)
        }
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 800,
                height: 400
            ),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        window.contentView = view

        XCTAssertTrue(
            callbackWindows.compactMap { $0 }.last === window
        )
    }
}

private final class TerminalDelegateRecorder: TerminalViewDelegate {
    private(set) var sentData: [Data] = []

    func sizeChanged(
        source: TerminalView,
        newCols: Int,
        newRows: Int
    ) {
        _ = (source, newCols, newRows)
    }

    func setTerminalTitle(
        source: TerminalView,
        title: String
    ) {
        _ = (source, title)
    }

    func hostCurrentDirectoryUpdate(
        source: TerminalView,
        directory: String?
    ) {
        _ = (source, directory)
    }

    func send(
        source: TerminalView,
        data: ArraySlice<UInt8>
    ) {
        _ = source
        sentData.append(Data(data))
    }

    func scrolled(source: TerminalView, position: Double) {
        _ = (source, position)
    }

    func rangeChanged(
        source: TerminalView,
        startY: Int,
        endY: Int
    ) {
        _ = (source, startY, endY)
    }
}

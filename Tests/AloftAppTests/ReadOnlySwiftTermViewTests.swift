import AppKit
import MetalKit
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

    func testCommandCCopiesSelectedTerminalText() throws {
        let pasteboard = NSPasteboard.general
        let originalItems = pasteboard.pasteboardItems?.map {
            PasteboardItemSnapshot(item: $0)
        } ?? []
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(
                originalItems.map(\.pasteboardItem)
            )
        }

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
        view.feed(text: "copy from Aloft")
        view.selectAll(nil)
        let copyItem = NSMenuItem(
            title: "Copy",
            action: #selector(view.copy(_:)),
            keyEquivalent: ""
        )
        XCTAssertTrue(
            view.validateUserInterfaceItem(copyItem)
        )
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "c",
                charactersIgnoringModifiers: "c",
                isARepeat: false,
                keyCode: 8
            )
        )

        XCTAssertNil(view.filterUserInputEvent(event))
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "copy from Aloft"
        )
    }

    func testMouseDragSelectsAndCommandCCopiesAfterScrollbackTrim()
        throws {
        let pasteboard = NSPasteboard.general
        let originalItems = pasteboard.pasteboardItems?.map {
            PasteboardItemSnapshot(item: $0)
        } ?? []
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(
                originalItems.map(\.pasteboardItem)
            )
        }

        let view = ReadOnlySwiftTermView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: 800,
                height: 400
            )
        )
        view.changeScrollback(40)
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.makeFirstResponder(nil)
        let metalOverlay = MTKView(
            frame: view.bounds,
            device: nil
        )
        metalOverlay.autoresizingMask = [.width, .height]
        view.addSubview(metalOverlay)
        let lines = (0..<200)
            .map {
                String(
                    format:
                        "line-%03d abcdefghijklmnopqrstuvwxyz\r\n",
                    $0
                )
            }
            .joined()
        view.feed(text: lines)
        XCTAssertGreaterThan(
            view.getTerminal().buffer.totalLinesTrimmed,
            0
        )

        let y = view.bounds.midY
        let mouseDown = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: NSPoint(x: 8, y: y),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )
        let firstMouseDragged = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDragged,
                location: NSPoint(x: 80, y: y),
                modifierFlags: [],
                timestamp: 0.1,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 2,
                clickCount: 1,
                pressure: 1
            )
        )
        let secondMouseDragged = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDragged,
                location: NSPoint(x: 160, y: y),
                modifierFlags: [],
                timestamp: 0.2,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 3,
                clickCount: 1,
                pressure: 1
            )
        )
        let mouseUp = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: NSPoint(x: 160, y: y),
                modifierFlags: [],
                timestamp: 0.3,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 4,
                clickCount: 1,
                pressure: 0
            )
        )

        let mouseTarget = try XCTUnwrap(
            window.contentView?.hitTest(mouseDown.locationInWindow)
        )
        XCTAssertTrue(mouseTarget === view)
        mouseTarget.mouseDown(with: mouseDown)
        mouseTarget.mouseDragged(with: firstMouseDragged)
        mouseTarget.mouseDragged(with: secondMouseDragged)
        mouseTarget.mouseUp(with: mouseUp)

        XCTAssertTrue(window.firstResponder === view)
        let selectedText = try XCTUnwrap(view.getSelection())
        XCTAssertFalse(selectedText.isEmpty)

        let copyEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 0.4,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "c",
                charactersIgnoringModifiers: "c",
                isARepeat: false,
                keyCode: 8
            )
        )
        XCTAssertNil(view.filterUserInputEvent(copyEvent))
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            selectedText
        )
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

private struct PasteboardItemSnapshot {
    private let values: [(NSPasteboard.PasteboardType, Data)]

    init(item: NSPasteboardItem) {
        values = item.types.compactMap { type in
            item.data(forType: type).map { (type, $0) }
        }
    }

    var pasteboardItem: NSPasteboardItem {
        let item = NSPasteboardItem()
        values.forEach { type, data in
            item.setData(data, forType: type)
        }
        return item
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

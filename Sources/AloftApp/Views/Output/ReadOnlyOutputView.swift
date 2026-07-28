import AppKit
import SwiftUI

enum OutputTextMutation: Equatable {
    case none
    case append(String)
    case replace(String)

    init(oldText: String, newText: String) {
        if oldText == newText {
            self = .none
        } else if newText.hasPrefix(oldText) {
            self = .append(String(newText.dropFirst(oldText.count)))
        } else {
            self = .replace(newText)
        }
    }
}

enum OutputScrollGeometry {
    static func isAtBottom(
        visibleMaxY: CGFloat,
        documentMaxY: CGFloat,
        tolerance: CGFloat = 1
    ) -> Bool {
        documentMaxY - visibleMaxY <= tolerance
    }
}

struct ReadOnlyOutputView: NSViewRepresentable {
    let text: String
    let autoScroll: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(
            ofSize: NSFont.systemFontSize,
            weight: .regular
        )
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text
        scrollView.documentView = textView
        context.coordinator.priorText = text
        return scrollView
    }

    func updateNSView(
        _ scrollView: NSScrollView,
        context: Context
    ) {
        guard let textView = scrollView.documentView as? NSTextView,
              let textStorage = textView.textStorage else {
            return
        }
        let visibleMaxY = scrollView.contentView.bounds.maxY
        let documentMaxY = textView.bounds.maxY
        let wasAtBottom = OutputScrollGeometry.isAtBottom(
            visibleMaxY: visibleMaxY,
            documentMaxY: documentMaxY
        )

        switch OutputTextMutation(
            oldText: context.coordinator.priorText,
            newText: text
        ) {
        case .none:
            break
        case .append(let suffix):
            textStorage.append(
                NSAttributedString(
                    string: suffix,
                    attributes: textAttributes(for: textView)
                )
            )
        case .replace(let replacement):
            textStorage.setAttributedString(
                NSAttributedString(
                    string: replacement,
                    attributes: textAttributes(for: textView)
                )
            )
        }
        context.coordinator.priorText = text

        if autoScroll, wasAtBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    final class Coordinator {
        var priorText = ""
    }

    private func textAttributes(
        for textView: NSTextView
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: textView.font
                ?? NSFont.monospacedSystemFont(
                    ofSize: NSFont.systemFontSize,
                    weight: .regular
                ),
            .foregroundColor: NSColor.textColor,
        ]
    }
}

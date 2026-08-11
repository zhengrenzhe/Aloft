import AppKit
import MetalKit
import SwiftTerm

final class ReadOnlySwiftTermView: TerminalView {
    private static let jumpToLatestIdentifier =
        NSUserInterfaceItemIdentifier(
            "Aloft.Terminal.JumpToLatest"
        )

    var onWindowAttachment: (() -> Void)?
    nonisolated(unsafe) private var inputEventMonitor: Any?
    private var jumpToLatestButton: NSButton?
    private var hasUnseenOutput = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureReadOnlyBehavior()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureReadOnlyBehavior()
    }

    override func insertText(
        _ string: Any,
        replacementRange: NSRange
    ) {
        _ = (string, replacementRange)
        unmarkText()
    }

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        _ = (string, selectedRange, replacementRange)
        unmarkText()
    }

    @objc
    override func paste(_ sender: Any) {
        _ = sender
    }

    override func validateUserInterfaceItem(
        _ item: NSValidatedUserInterfaceItem
    ) -> Bool {
        if item.action == #selector(paste(_:)) {
            return false
        }
        return super.validateUserInterfaceItem(item)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowAttachment?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let target = super.hitTest(point)
        if target is MTKView {
            return self
        }
        return target
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    func noteOutputReceived() {
        guard scrollPosition < 1 else {
            clearUnseenOutput()
            return
        }
        hasUnseenOutput = true
        jumpToLatestButton?.isHidden = false
    }

    func terminalDidScroll(to position: Double) {
        guard position >= 1 else {
            return
        }
        clearUnseenOutput()
    }

    func filterUserInputEvent(_ event: NSEvent) -> NSEvent? {
        guard event.window === window,
              window?.firstResponder === self else {
            return event
        }
        switch event.type {
        case .keyDown:
            if isCopyShortcut(event) {
                copySelectionIfAvailable()
            }
            return nil
        case .keyUp, .flagsChanged:
            return nil
        default:
            return event
        }
    }

    private func isCopyShortcut(_ event: NSEvent) -> Bool {
        let relevantModifiers = event.modifierFlags
            .intersection([.command, .control, .option, .shift])
        return relevantModifiers == .command
            && event.charactersIgnoringModifiers?.lowercased() == "c"
    }

    private func copySelectionIfAvailable() {
        let copyItem = NSMenuItem(
            title: "",
            action: #selector(copy(_:)),
            keyEquivalent: ""
        )
        guard validateUserInterfaceItem(copyItem) else {
            return
        }
        copy(self)
    }

    private func configureReadOnlyBehavior() {
        allowMouseReporting = false
        linkReporting = .none
        installJumpToLatestButton()
        inputEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
            self?.filterUserInputEvent(event) ?? event
        }
    }

    private func installJumpToLatestButton() {
        guard jumpToLatestButton == nil else {
            return
        }
        let button = NSButton(
            title: L10n.string("New output"),
            target: self,
            action: #selector(jumpToLatest(_:))
        )
        button.identifier = Self.jumpToLatestIdentifier
        button.toolTip = L10n.string("Jump to latest output")
        button.setAccessibilityLabel(
            L10n.string("Jump to latest output")
        )
        button.image = NSImage(
            systemSymbolName: "arrow.down.to.line.compact",
            accessibilityDescription: nil
        )
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        addSubview(button, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -28
            ),
            button.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -12
            ),
        ])
        jumpToLatestButton = button
    }

    @objc
    private func jumpToLatest(_ sender: NSButton) {
        _ = sender
        scroll(toPosition: 1)
        clearUnseenOutput()
    }

    private func clearUnseenOutput() {
        guard hasUnseenOutput
                || jumpToLatestButton?.isHidden == false else {
            return
        }
        hasUnseenOutput = false
        jumpToLatestButton?.isHidden = true
    }

    deinit {
        if let inputEventMonitor {
            NSEvent.removeMonitor(inputEventMonitor)
        }
    }
}

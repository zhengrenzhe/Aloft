import AppKit
import SwiftUI

@MainActor
struct ManagementWindowActivationAction {
    private let activateApplication: () -> Void
    private let orderFront: (NSWindow) -> Void

    init(
        activateApplication: @escaping () -> Void = {
            NSApplication.shared.activate()
        },
        orderFront: @escaping (NSWindow) -> Void = {
            window in
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    ) {
        self.activateApplication = activateApplication
        self.orderFront = orderFront
    }

    func perform(on window: NSWindow) {
        activateApplication()
        orderFront(window)
    }
}

@MainActor
final class ManagementWindowAttachmentView: NSView {
    private let onWindowAttachment: (NSWindow) -> Void

    init(
        onWindowAttachment:
            @escaping (NSWindow) -> Void
    ) {
        self.onWindowAttachment = onWindowAttachment
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(
                reportAttachedWindow
            ),
            object: nil
        )
        guard window != nil else {
            return
        }
        perform(
            #selector(reportAttachedWindow),
            with: nil,
            afterDelay: 0
        )
    }

    @objc
    private func reportAttachedWindow() {
        guard let window else {
            return
        }
        onWindowAttachment(window)
    }
}

struct ManagementWindowActivationBridge:
    NSViewRepresentable {
    func makeNSView(
        context: Context
    ) -> ManagementWindowAttachmentView {
        ManagementWindowAttachmentView { window in
            ManagementWindowActivationAction()
                .perform(on: window)
        }
    }

    func updateNSView(
        _ nsView: ManagementWindowAttachmentView,
        context: Context
    ) {}
}

import AppKit
import SwiftUI

@MainActor
final class TerminalHostView: NSView {
    private var installedSurface: (any TerminalSurface)?

    init(surface: any TerminalSurface) {
        super.init(frame: .zero)
        install(surface: surface)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func install(surface: any TerminalSurface) {
        if let installedSurface,
           ObjectIdentifier(installedSurface) ==
               ObjectIdentifier(surface) {
            return
        }

        subviews.forEach { $0.removeFromSuperview() }
        let surfaceView = surface.nativeView
        surfaceView.removeFromSuperview()
        surfaceView.frame = bounds
        surfaceView.autoresizingMask = [.width, .height]
        addSubview(surfaceView)
        installedSurface = surface
    }

    override func layout() {
        super.layout()
        installedSurface?.nativeView.frame = bounds
    }
}

struct TerminalOutputView: NSViewRepresentable {
    let surface: any TerminalSurface

    func makeNSView(context: Context) -> TerminalHostView {
        TerminalHostView(surface: surface)
    }

    func updateNSView(
        _ hostView: TerminalHostView,
        context: Context
    ) {
        hostView.install(surface: surface)
    }
}

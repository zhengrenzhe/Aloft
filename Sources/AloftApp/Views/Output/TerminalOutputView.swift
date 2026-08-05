import AppKit
import SwiftUI

@MainActor
final class TerminalHostView: NSView {
    private var installedSurface: (any TerminalSurface)?

    init(
        surface: any TerminalSurface,
        font: NSFont
    ) {
        super.init(frame: .zero)
        install(surface: surface, font: font)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func install(
        surface: any TerminalSurface,
        font: NSFont
    ) {
        surface.updateFont(font)
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

    @AppStorage(TerminalFontPreference.familyStorageKey)
    private var fontFamily =
        TerminalFontPreference.defaultFamily
    @AppStorage(TerminalFontPreference.sizeStorageKey)
    private var fontSize =
        TerminalFontPreference.defaultSize

    func makeNSView(context: Context) -> TerminalHostView {
        TerminalHostView(
            surface: surface,
            font: resolvedFont
        )
    }

    func updateNSView(
        _ hostView: TerminalHostView,
        context: Context
    ) {
        hostView.install(
            surface: surface,
            font: resolvedFont
        )
    }

    private var resolvedFont: NSFont {
        TerminalFontPreference.resolve(
            family: fontFamily,
            size: fontSize
        )
    }
}

import AppKit
import Foundation
@testable import AloftApp

final class TerminalSurfaceStub: TerminalSurface, @unchecked Sendable {
    @MainActor let nativeView: NSView
    @MainActor var rendererState: TerminalRendererState
    @MainActor var onRendererStateChange:
        ((TerminalRendererState) -> Void)?

    @MainActor
    init(
        nativeView: NSView,
        rendererState: TerminalRendererState = .metal
    ) {
        self.nativeView = nativeView
        self.rendererState = rendererState
    }

    func prepare(generation: UUID) {}
    func feed(_ data: Data, generation: UUID) {}
    func promote(generation: UUID, at timestamp: Date) {}
    func discard(generation: UUID) {}
    func resize(_ size: TerminalSize, generation: UUID) {}
    func clear() {}
    func dispose() {}
}

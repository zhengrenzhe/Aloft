import AppKit
import Foundation

protocol TerminalSurface: AnyObject, Sendable {
    @MainActor var nativeView: NSView { get }
    @MainActor var rendererState: TerminalRendererState { get }
    @MainActor var onRendererStateChange:
        ((TerminalRendererState) -> Void)? { get set }

    func prepare(generation: UUID)
    func feed(_ data: Data, generation: UUID)
    func promote(generation: UUID, at timestamp: Date)
    func discard(generation: UUID)
    func resize(_ size: TerminalSize, generation: UUID)
    func clear()
    func dispose()
}

@MainActor
struct TerminalSurfaceFactory {
    let makeSurface: (
        UUID,
        TerminalSurfaceCallbacks
    ) throws -> any TerminalSurface
}

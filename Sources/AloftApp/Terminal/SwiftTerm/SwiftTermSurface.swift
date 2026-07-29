import AppKit
import Dispatch
import Foundation
@preconcurrency import SwiftTerm

final class SwiftTermSurface:
    NSObject,
    TerminalSurface,
    TerminalViewDelegate,
    @unchecked Sendable {
    typealias MetalActivation = @MainActor (
        ReadOnlySwiftTermView
    ) throws -> Bool

    @MainActor
    var nativeView: NSView {
        terminalViewForTesting
    }

    @MainActor
    private(set) var rendererState: TerminalRendererState =
        .awaitingWindow

    @MainActor
    var onRendererStateChange:
        ((TerminalRendererState) -> Void)?

    @MainActor
    let terminalViewForTesting: ReadOnlySwiftTermView

    private let stateQueue = DispatchQueue(
        label: "com.aloft.terminal.swiftterm.state",
        qos: .utility
    )
    private let stateQueueKey = DispatchSpecificKey<UInt8>()
    private let callbackAdmission: TerminalCallbackAdmission
    private let beforeOperation: @Sendable () -> Void
    private let metalActivation: MetalActivation

    private var pendingGeneration: UUID?
    private var pendingChunks: [Data] = []
    private var activeGeneration: UUID?
    private var disposed = false

    @MainActor
    private var rendererActivationAttempted = false

    @MainActor
    init(
        callbacks: TerminalSurfaceCallbacks,
        metalActivation: @escaping MetalActivation = {
            terminalView in
            try terminalView.setUseMetal(true)
            return terminalView.isUsingMetalRenderer
        },
        beforeOperation: @escaping @Sendable () -> Void = {}
    ) {
        callbackAdmission = TerminalCallbackAdmission(
            callbacks: callbacks
        )
        self.metalActivation = metalActivation
        self.beforeOperation = beforeOperation
        terminalViewForTesting = ReadOnlySwiftTermView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: 800,
                height: 400
            )
        )
        super.init()
        stateQueue.setSpecific(key: stateQueueKey, value: 1)
        terminalViewForTesting.allowMouseReporting = false
        terminalViewForTesting.linkReporting = .none
        terminalViewForTesting.changeScrollback(20_000)
        terminalViewForTesting.terminalDelegate = self
        terminalViewForTesting.onWindowAttachment = {
            [weak self] in
            self?.activateRendererAfterWindowAttachment()
        }
    }

    func prepare(generation: UUID) {
        enqueueOperation { [self] in
            pendingGeneration = generation
            pendingChunks.removeAll(keepingCapacity: true)
        }
    }

    func feed(_ data: Data, generation: UUID) {
        enqueueOperation { [self] in
            if pendingGeneration == generation {
                pendingChunks.append(data)
                return
            }
            guard activeGeneration == generation else {
                return
            }
            feedView(data)
        }
    }

    func promote(generation: UUID, at timestamp: Date) {
        enqueueOperation { [self] in
            guard pendingGeneration == generation else {
                return
            }
            let chunks = pendingChunks
            pendingGeneration = nil
            pendingChunks.removeAll(keepingCapacity: true)
            activeGeneration = generation
            feedView(
                terminalSessionPrelude(at: timestamp)
            )
            chunks.forEach(feedView)
        }
    }

    func discard(generation: UUID) {
        enqueueOperation { [self] in
            guard pendingGeneration == generation else {
                return
            }
            pendingGeneration = nil
            pendingChunks.removeAll(keepingCapacity: true)
        }
    }

    func resize(_ size: TerminalSize, generation: UUID) {
        enqueueOperation { [self] in
            guard activeGeneration == generation
                    || pendingGeneration == generation else {
                return
            }
            callbackAdmission.resize(
                size,
                generation: generation
            )
        }
    }

    func clear() {
        enqueueOperation { [self] in
            pendingChunks.removeAll(keepingCapacity: true)
            feedView(Data("\u{1b}c".utf8))
        }
    }

    func dispose() {
        guard callbackAdmission.close() else {
            return
        }
        stateQueue.async { [self] in
            beforeOperation()
            guard !disposed else {
                return
            }
            disposed = true
            pendingGeneration = nil
            pendingChunks.removeAll()
            activeGeneration = nil
            Task { @MainActor [weak self] in
                self?.terminalViewForTesting.terminalDelegate = nil
                self?.terminalViewForTesting.onWindowAttachment = nil
            }
        }
    }

    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            stateQueue.async { [stateQueue] in
                stateQueue.async {
                    continuation.resume()
                }
            }
        }
    }

    @MainActor
    func activateRendererForTesting() {
        activateRendererAfterWindowAttachment()
    }

    private func enqueueOperation(
        _ operation: @escaping @Sendable () -> Void
    ) {
        stateQueue.async { [self] in
            beforeOperation()
            guard callbackAdmission.isOpen, !disposed else {
                return
            }
            operation()
        }
    }

    private func feedView(_ data: Data) {
        let bytes = Array(data)
        DispatchQueue.main.sync { [terminalViewForTesting] in
            terminalViewForTesting.feed(byteArray: bytes[...])
        }
    }

    private func terminalSessionPrelude(at timestamp: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let separator = L10n.format(
            "──── Session started %@ ────",
            formatter.string(from: timestamp)
        )
        return Data(
            (
                "\u{1b}[?1049l"
                    + "\u{1b}[!p"
                    + "\r\n"
                    + separator
                    + "\r\n"
            ).utf8
        )
    }

    @MainActor
    private func activateRendererAfterWindowAttachment() {
        guard callbackAdmission.isOpen else {
            return
        }
        if rendererActivationAttempted {
            if terminalViewForTesting.isUsingMetalRenderer {
                publishRendererState(.metal)
            } else {
                publishRendererState(
                    .coreGraphicsFallback(
                        SwiftTermSurfaceError
                            .metalRebindFailed
                            .localizedDescription
                    )
                )
            }
            return
        }

        rendererActivationAttempted = true
        do {
            if try metalActivation(terminalViewForTesting) {
                publishRendererState(.metal)
            } else {
                publishRendererState(
                    .coreGraphicsFallback(
                        SwiftTermSurfaceError
                            .metalDidNotActivate
                            .localizedDescription
                    )
                )
            }
        } catch {
            publishRendererState(
                .coreGraphicsFallback(error.localizedDescription)
            )
        }
    }

    @MainActor
    private func publishRendererState(
        _ state: TerminalRendererState
    ) {
        guard rendererState != state else {
            return
        }
        rendererState = state
        onRendererStateChange?(state)
    }

    func sizeChanged(
        source: TerminalView,
        newCols: Int,
        newRows: Int
    ) {
        Task { @MainActor [weak self, weak source] in
            guard let self, let source else {
                return
            }
            let backingSize = source.convertToBacking(
                source.bounds
            ).size
            guard let size = TerminalSize(
                columns: newCols,
                rows: newRows,
                pixelWidth: max(
                    0,
                    Int(backingSize.width.rounded())
                ),
                pixelHeight: max(
                    0,
                    Int(backingSize.height.rounded())
                )
            ) else {
                return
            }
            self.enqueueDelegateOperation { [self] generation in
                callbackAdmission.resize(
                    size,
                    generation: generation
                )
            }
        }
    }

    func send(
        source: TerminalView,
        data: ArraySlice<UInt8>
    ) {
        _ = source
        let reply = Data(data)
        enqueueDelegateOperation { [self] generation in
            callbackAdmission.write(
                reply,
                generation: generation
            )
        }
    }

    private func enqueueDelegateOperation(
        _ operation: @escaping @Sendable (UUID) -> Void
    ) {
        if DispatchQueue.getSpecific(key: stateQueueKey) != nil {
            guard callbackAdmission.isOpen,
                  !disposed,
                  let activeGeneration else {
                return
            }
            operation(activeGeneration)
            return
        }
        enqueueOperation { [self] in
            guard let activeGeneration else {
                return
            }
            operation(activeGeneration)
        }
    }

    func clipboardCopy(
        source: TerminalView,
        content: Data
    ) {
        _ = (source, content)
    }

    func clipboardRead(source: TerminalView) -> Data? {
        _ = source
        return nil
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

private final class TerminalCallbackAdmission:
    @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: TerminalSurfaceCallbacks?

    init(callbacks: TerminalSurfaceCallbacks) {
        self.callbacks = callbacks
    }

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return callbacks != nil
    }

    @discardableResult
    func close() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard callbacks != nil else {
            return false
        }
        callbacks = nil
        return true
    }

    func write(_ data: Data, generation: UUID) {
        let callback = withCallbacks {
            $0.writeProtocolReply
        }
        callback?(data, generation)
    }

    func resize(_ size: TerminalSize, generation: UUID) {
        let callback = withCallbacks {
            $0.resizePTY
        }
        callback?(size, generation)
    }

    private func withCallbacks<T>(
        _ body: (TerminalSurfaceCallbacks) -> T
    ) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return callbacks.map(body)
    }
}

private enum SwiftTermSurfaceError: LocalizedError {
    case metalDidNotActivate
    case metalRebindFailed

    var errorDescription: String? {
        switch self {
        case .metalDidNotActivate:
            return "SwiftTerm did not activate its Metal renderer."
        case .metalRebindFailed:
            return "SwiftTerm disabled Metal while rebinding the window."
        }
    }
}

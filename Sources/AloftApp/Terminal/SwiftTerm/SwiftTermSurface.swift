import AppKit
import Dispatch
import Foundation
import SwiftTerm

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
    private let viewFeedBatcher: MainActorDataBatcher
    private let viewportFollowRequest: TerminalViewportFollowRequest
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
        beforeOperation: @escaping @Sendable () -> Void = {},
        beforeViewFeed:
            @escaping @MainActor @Sendable () -> Void = {}
    ) {
        callbackAdmission = TerminalCallbackAdmission(
            callbacks: callbacks
        )
        self.metalActivation = metalActivation
        self.beforeOperation = beforeOperation
        let terminalView = ReadOnlySwiftTermView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: 800,
                height: 400
            )
        )
        let viewportFollowRequest = TerminalViewportFollowRequest()
        terminalViewForTesting = terminalView
        self.viewportFollowRequest = viewportFollowRequest
        viewFeedBatcher = MainActorDataBatcher(
            maximumBatchByteCount: 16 * 1_024
        ) { [weak terminalView] data in
            guard let terminalView else {
                return
            }
            beforeViewFeed()
            let bytes = Array(data)
            terminalView.feed(byteArray: bytes[...])
            if viewportFollowRequest.consume() {
                terminalView.scroll(toPosition: 1)
            }
            terminalView.noteOutputReceived()
        }
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
            submitViewFeed(data)
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
            viewportFollowRequest.request()
            submitViewFeed(
                terminalSessionPrelude(at: timestamp)
            )
            chunks.forEach(submitViewFeed)
        }
    }

    func discard(generation: UUID) {
        enqueueOperation { [self] in
            if pendingGeneration == generation {
                pendingGeneration = nil
                pendingChunks.removeAll(keepingCapacity: true)
            }
            if activeGeneration == generation {
                activeGeneration = nil
            }
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
            viewportFollowRequest.request()
            submitViewFeed(Data("\u{1b}c".utf8))
        }
    }

    func dispose() {
        guard callbackAdmission.close() else {
            return
        }
        viewFeedBatcher.close()
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
        await waitUntilStateQueueIsIdle()
        await viewFeedBatcher.waitUntilIdle()
        await waitUntilStateQueueIsIdle()
    }

    private func waitUntilStateQueueIsIdle() async {
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

    @MainActor
    func updateFont(_ font: NSFont) {
        let currentFont = terminalViewForTesting.font
        guard currentFont.fontName != font.fontName
                || currentFont.pointSize != font.pointSize else {
            return
        }
        terminalViewForTesting.font = font
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

    private func submitViewFeed(_ data: Data) {
        viewFeedBatcher.submit(data)
    }

    private func terminalSessionPrelude(at timestamp: Date) -> Data {
        return Data(
            (
                "\u{1b}7"
                    + "\u{1b}[?1049l"
                    + "\u{1b}[!p"
                    + "\r\n"
                    + SessionSeparator.line(at: timestamp)
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
        Task { @MainActor [weak source] in
            (source as? ReadOnlySwiftTermView)?
                .terminalDidScroll(to: position)
        }
    }

    func rangeChanged(
        source: TerminalView,
        startY: Int,
        endY: Int
    ) {
        _ = (source, startY, endY)
    }
}

private final class TerminalViewportFollowRequest:
    @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    func request() {
        lock.withLock {
            requested = true
        }
    }

    func consume() -> Bool {
        lock.withLock {
            let result = requested
            requested = false
            return result
        }
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

import AppKit
import Foundation
@testable import AloftApp

enum TerminalSurfaceEvent: Equatable {
    case prepare(UUID)
    case promote(UUID)
    case feed(String, UUID)
    case discard(UUID)
    case resize(TerminalSize, UUID)
    case clear
    case dispose
}

final class TerminalSurfaceRecorder: TerminalSurface, @unchecked Sendable {
    @MainActor
    let nativeView = NSView()

    @MainActor
    var rendererState: TerminalRendererState = .awaitingWindow

    @MainActor
    var onRendererStateChange:
        ((TerminalRendererState) -> Void)?

    private let lock = NSLock()
    private var recordedEvents: [TerminalSurfaceEvent] = []
    private var pendingBytes: [UUID: Data] = [:]
    private var activeGeneration: UUID?
    private var visibleBytes = Data()
    private var installedCallbacks: TerminalSurfaceCallbacks?
    private var callbacksByGeneration:
        [UUID: TerminalSurfaceCallbacks] = [:]
    private var recordedDisposeCount = 0

    @MainActor
    init() {}

    @MainActor
    func publishRendererState(_ state: TerminalRendererState) {
        rendererState = state
        onRendererStateChange?(state)
    }

    var events: [TerminalSurfaceEvent] {
        withLock { recordedEvents }
    }

    var visibleText: String {
        withLock {
            String(decoding: visibleBytes, as: UTF8.self)
        }
    }

    var disposeCount: Int {
        withLock { recordedDisposeCount }
    }

    func install(callbacks: TerminalSurfaceCallbacks) {
        withLock {
            installedCallbacks = callbacks
        }
    }

    func callbacks(
        for generation: UUID
    ) -> TerminalSurfaceCallbacks? {
        withLock {
            callbacksByGeneration[generation]
        }
    }

    func prepare(generation: UUID) {
        withLock {
            recordedEvents.append(.prepare(generation))
            pendingBytes[generation] = Data()
            if let installedCallbacks {
                callbacksByGeneration[generation] = installedCallbacks
            }
        }
    }

    func feed(_ data: Data, generation: UUID) {
        withLock {
            if pendingBytes[generation] != nil {
                pendingBytes[generation]?.append(data)
                return
            }
            guard activeGeneration == generation else {
                return
            }
            visibleBytes.append(data)
            recordedEvents.append(
                .feed(
                    String(decoding: data, as: UTF8.self),
                    generation
                )
            )
        }
    }

    func promote(generation: UUID, at timestamp: Date) {
        _ = timestamp
        withLock {
            guard let bytes = pendingBytes.removeValue(
                forKey: generation
            ) else {
                return
            }
            activeGeneration = generation
            recordedEvents.append(.promote(generation))
            guard !bytes.isEmpty else {
                return
            }
            visibleBytes.append(bytes)
            recordedEvents.append(
                .feed(
                    String(decoding: bytes, as: UTF8.self),
                    generation
                )
            )
        }
    }

    func discard(generation: UUID) {
        withLock {
            pendingBytes.removeValue(forKey: generation)
            if activeGeneration == generation {
                activeGeneration = nil
            }
            recordedEvents.append(.discard(generation))
        }
    }

    func resize(_ size: TerminalSize, generation: UUID) {
        withLock {
            guard activeGeneration == generation
                    || pendingBytes[generation] != nil else {
                return
            }
            recordedEvents.append(.resize(size, generation))
        }
    }

    func clear() {
        withLock {
            visibleBytes.removeAll(keepingCapacity: true)
            pendingBytes = pendingBytes.mapValues { _ in Data() }
            recordedEvents.append(.clear)
        }
    }

    func dispose() {
        withLock {
            recordedDisposeCount += 1
            pendingBytes.removeAll()
            activeGeneration = nil
            recordedEvents.append(.dispose)
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

extension TerminalSurfaceFactory {
    static func recording(
        _ surface: TerminalSurfaceRecorder
    ) -> Self {
        Self { _, callbacks in
            surface.install(callbacks: callbacks)
            return surface
        }
    }
}

enum ScriptedTerminalStartPlan: Sendable {
    case success(outputBeforeReturn: Data)
    case failure(
        TestTerminalProcessError,
        outputBeforeReturn: Data
    )
}

enum TestTerminalProcessError: Error, Sendable {
    case launchFailed
}

actor ScriptedTerminalProcessClient {
    private var startPlans: [ScriptedTerminalStartPlan]
    private var records: [UUID: ProcessSnapshot] = [:]
    private var callbackWaiters: [
        (
            expectedCount: Int,
            continuation: CheckedContinuation<Void, Never>
        )
    ] = []
    private var writeError: ProcessSupervisorError?
    private var resizeError: ProcessSupervisorError?
    private var stopResultOverride: StopResult?
    private var callbackAttemptCount = 0

    private(set) var startedGenerations: [UUID] = []
    private(set) var writes: [
        (entryID: UUID, generation: UUID, data: Data)
    ] = []
    private(set) var resizes: [
        (entryID: UUID, generation: UUID, size: TerminalSize)
    ] = []

    init(startPlans: [ScriptedTerminalStartPlan]) {
        self.startPlans = startPlans
    }

    func client() -> RuntimeProcessClient {
        RuntimeProcessClient(
            start: { entry, generation, outputHandler in
                try await self.start(
                    entry: entry,
                    generation: generation,
                    outputHandler: outputHandler.handler
                )
            },
            write: { entryID, generation, data in
                try await self.recordWrite(
                    entryID: entryID,
                    generation: generation,
                    data: data
                )
            },
            resize: { entryID, generation, size in
                try await self.recordResize(
                    entryID: entryID,
                    generation: generation,
                    size: size
                )
            },
            stop: { entryID, _ in
                await self.stop(entryID: entryID)
            },
            refresh: { entryID in
                try await self.refresh(entryID: entryID)
            },
            snapshots: {
                await self.records
            }
        )
    }

    func waitForCallbackTasks(expectedCount: Int = 2) async {
        guard callbackAttemptCount < expectedCount else {
            return
        }
        await withCheckedContinuation { continuation in
            callbackWaiters.append((expectedCount, continuation))
        }
    }

    func setCallbackErrors(
        write: ProcessSupervisorError?,
        resize: ProcessSupervisorError?
    ) {
        writeError = write
        resizeError = resize
    }

    func setStopResult(_ result: StopResult?) {
        stopResultOverride = result
    }

    func setRefreshSnapshot(_ snapshot: ProcessSnapshot) {
        records[snapshot.entryID] = snapshot
    }

    private func start(
        entry: CommandEntry,
        generation: UUID,
        outputHandler: @escaping @Sendable (Data) -> Void
    ) throws -> ProcessSnapshot {
        startedGenerations.append(generation)
        guard !startPlans.isEmpty else {
            throw ProcessSupervisorError.unknownEntry
        }
        let plan = startPlans.removeFirst()
        let output: Data
        switch plan {
        case .success(let outputBeforeReturn):
            output = outputBeforeReturn
        case .failure(_, let outputBeforeReturn):
            output = outputBeforeReturn
        }
        outputHandler(output)

        switch plan {
        case .success:
            let processID = pid_t(1_000 + startedGenerations.count)
            let snapshot = ProcessSnapshot(
                entryID: entry.id,
                pid: processID,
                processGroupID: processID,
                liveness: .running,
                launchedAt: Date(),
                exitResult: nil
            )
            records[entry.id] = snapshot
            return snapshot
        case .failure(let error, _):
            throw error
        }
    }

    private func stop(entryID: UUID) -> StopResult {
        if let stopResultOverride {
            return stopResultOverride
        }
        guard let existing = records[entryID],
              existing.liveness == .running else {
            return .alreadyStopped
        }
        records[entryID] = ProcessSnapshot(
            entryID: entryID,
            pid: nil,
            processGroupID: nil,
            liveness: .stopped,
            launchedAt: existing.launchedAt,
            exitResult: .exited(code: 0)
        )
        return .stopped
    }

    private func refresh(entryID: UUID) throws -> ProcessSnapshot {
        guard let snapshot = records[entryID] else {
            throw ProcessSupervisorError.unknownEntry
        }
        return snapshot
    }

    private func recordWrite(
        entryID: UUID,
        generation: UUID,
        data: Data
    ) throws {
        callbackAttemptCount += 1
        defer { resumeSatisfiedCallbackWaiters() }
        if let writeError {
            throw writeError
        }
        writes.append((entryID, generation, data))
    }

    private func recordResize(
        entryID: UUID,
        generation: UUID,
        size: TerminalSize
    ) throws {
        callbackAttemptCount += 1
        defer { resumeSatisfiedCallbackWaiters() }
        if let resizeError {
            throw resizeError
        }
        resizes.append((entryID, generation, size))
    }

    private func resumeSatisfiedCallbackWaiters() {
        let count = callbackAttemptCount
        var remaining: [
            (
                expectedCount: Int,
                continuation: CheckedContinuation<Void, Never>
            )
        ] = []
        for waiter in callbackWaiters {
            if count >= waiter.expectedCount {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        callbackWaiters = remaining
    }
}

struct TerminalRuntimeFixture {
    let runtime: RuntimeStore
    let entry: CommandEntry
    let process: ScriptedTerminalProcessClient
    let surface: TerminalSurfaceRecorder
}

@MainActor
func makeTerminalRuntimeFixture(
    startPlans: [ScriptedTerminalStartPlan]
) async -> TerminalRuntimeFixture {
    let process = ScriptedTerminalProcessClient(
        startPlans: startPlans
    )
    let surface = TerminalSurfaceRecorder()
    let runtime = RuntimeStore(
        supervisor: ProcessSupervisor(),
        processClient: await process.client(),
        terminalSurfaceFactory: .recording(surface)
    )
    return TerminalRuntimeFixture(
        runtime: runtime,
        entry: CommandEntry(
            id: UUID(),
            name: "Terminal Fixture",
            cwd: "/tmp",
            command: "unused",
            keywords: [],
            order: 0
        ),
        process: process,
        surface: surface
    )
}

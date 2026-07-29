import Foundation
import Observation

struct EntryActionResult: Equatable, Sendable {
    let entryID: UUID
    let errorDescription: String?

    var isSuccess: Bool {
        errorDescription == nil
    }
}

struct RuntimeOutputHandler: Sendable {
    let handler: @Sendable (Data) -> Void
}

struct RuntimeProcessClient: Sendable {
    typealias OutputHandler = @Sendable (Data) -> Void
    typealias StartOperation = @Sendable (
        CommandEntry,
        UUID,
        RuntimeOutputHandler
    ) async throws -> ProcessSnapshot
    typealias WriteOperation = @Sendable (
        UUID,
        UUID,
        Data
    ) async throws -> Void
    typealias ResizeOperation = @Sendable (
        UUID,
        UUID,
        TerminalSize
    ) async throws -> Void
    typealias StopOperation = @Sendable (
        UUID,
        Duration
    ) async throws -> StopResult
    typealias RefreshOperation = @Sendable (
        UUID
    ) async throws -> ProcessSnapshot
    typealias SnapshotsOperation = @Sendable (
    ) async throws -> [UUID: ProcessSnapshot]

    private let startOperation: StartOperation
    private let writeOperation: WriteOperation
    private let resizeOperation: ResizeOperation
    private let stopOperation: StopOperation
    private let refreshOperation: RefreshOperation
    private let snapshotsOperation: SnapshotsOperation

    init(
        start: @escaping StartOperation,
        write: @escaping WriteOperation,
        resize: @escaping ResizeOperation,
        stop: @escaping StopOperation,
        refresh: @escaping RefreshOperation,
        snapshots: @escaping SnapshotsOperation
    ) {
        startOperation = start
        writeOperation = write
        resizeOperation = resize
        stopOperation = stop
        refreshOperation = refresh
        snapshotsOperation = snapshots
    }

    init(supervisor: ProcessSupervisor) {
        self.init(
            start: { entry, generation, onOutput in
                try await supervisor.start(
                    entry: entry,
                    generation: generation,
                    onOutput: onOutput.handler
                )
            },
            write: { entryID, generation, data in
                try await supervisor.write(
                    entryID: entryID,
                    generation: generation,
                    data: data
                )
            },
            resize: { entryID, generation, size in
                try await supervisor.resize(
                    entryID: entryID,
                    generation: generation,
                    size: size
                )
            },
            stop: { entryID, timeout in
                try await supervisor.stop(
                    entryID: entryID,
                    timeout: timeout
                )
            },
            refresh: { entryID in
                try await supervisor.refresh(entryID: entryID)
            },
            snapshots: {
                try await supervisor.snapshots()
            }
        )
    }

    func start(
        entry: CommandEntry,
        generation: UUID,
        onOutput: @escaping OutputHandler
    ) async throws -> ProcessSnapshot {
        try await startOperation(
            entry,
            generation,
            RuntimeOutputHandler(handler: onOutput)
        )
    }

    func write(
        entryID: UUID,
        generation: UUID,
        data: Data
    ) async throws {
        try await writeOperation(entryID, generation, data)
    }

    func resize(
        entryID: UUID,
        generation: UUID,
        size: TerminalSize
    ) async throws {
        try await resizeOperation(entryID, generation, size)
    }

    func stop(
        entryID: UUID,
        timeout: Duration
    ) async throws -> StopResult {
        try await stopOperation(entryID, timeout)
    }

    func refresh(entryID: UUID) async throws -> ProcessSnapshot {
        try await refreshOperation(entryID)
    }

    func snapshots() async throws -> [UUID: ProcessSnapshot] {
        try await snapshotsOperation()
    }
}

enum RuntimeStoreError: Error, Equatable, LocalizedError {
    case terminationInProgress
    case operationSuperseded
    case operationCancelled
    case entryRemovalProtected(UUID)

    var errorDescription: String? {
        switch self {
        case .terminationInProgress:
            return L10n.string(
                "Aloft is stopping managed processes for termination."
            )
        case .operationSuperseded:
            return L10n.string(
                "The operation was superseded by a newer process generation."
            )
        case .operationCancelled:
            return L10n.string("The operation was cancelled.")
        case .entryRemovalProtected(let entryID):
            return L10n.format(
                "Stop the live entry before deleting it: %@",
                entryID.uuidString
            )
        }
    }
}

struct RuntimeOperationReservation: Equatable, Sendable {
    fileprivate let id: UUID
}

struct TerminationBarrierToken: Equatable, Sendable {
    fileprivate let id: UUID
}

@MainActor
@Observable
final class RuntimeStore {
    private struct OutputSession {
        let entryID: UUID
        var pipeline: OutputPipeline
        var retainedLines: [String]
        var retainedMatch: KeywordMatchEvent?
        var latestUpdate: OutputUpdate
        var latestGlobalMatch: KeywordMatchEvent?
    }

    private struct ProbeRequest: Sendable {
        let entryID: UUID
        let generation: UUID
        let projectionRevision: UInt64
    }

    private struct ProbeResult: Sendable {
        let entryID: UUID
        let generation: UUID
        let projectionRevision: UInt64
        let snapshot: ProcessSnapshot?
        let errorDescription: String?
    }

    private struct ManagedProjectionCapture {
        let generation: UUID?
        let projectionRevision: UInt64
    }

    private enum GroupAction: Sendable {
        case start
        case stop(Duration)
        case restart(Duration)
    }

    private(set) var runtimes: [UUID: EntryRuntime] = [:]
    private(set) var latestGlobalMatch: KeywordMatchEvent?
    private(set) var protectionCounts: [UUID: Int] = [:]

    @ObservationIgnored
    let supervisor: ProcessSupervisor

    @ObservationIgnored
    private let processClient: RuntimeProcessClient

    @ObservationIgnored
    private let terminalSurfaceFactory: TerminalSurfaceFactory?

    @ObservationIgnored
    private var outputSessions: [UUID: OutputSession] = [:]

    @ObservationIgnored
    private var runtimeGenerations: [UUID: UUID] = [:]

    @ObservationIgnored
    private var projectionRevisions: [UUID: UInt64] = [:]

    @ObservationIgnored
    private var managedEnumerationRevision: UInt64 = 0

    @ObservationIgnored
    private var operationIDs: [UUID: UUID] = [:]

    @ObservationIgnored
    private var entryLanes: [UUID: EntryOperationLane] = [:]

    @ObservationIgnored
    private var reservations: [UUID: Set<UUID>] = [:]

    @ObservationIgnored
    private var knownEntries: [UUID: CommandEntry] = [:]

    @ObservationIgnored
    private var monitoringTask: Task<Void, Never>?

    @ObservationIgnored
    private var monitoringID: UUID?

    private var terminationBarrier: TerminationBarrierToken?

    @ObservationIgnored
    private var admittedLaunchCount = 0

    @ObservationIgnored
    private var launchDrainWaiters: [
        CheckedContinuation<Void, Never>
    ] = []

    var isTerminating: Bool {
        terminationBarrier != nil
    }

    var inFlightLaunchCount: Int {
        admittedLaunchCount
    }

    var protectedEntryIDs: Set<UUID> {
        Set(protectionCounts.keys)
    }

    var deletionProtectedEntryIDs: Set<UUID> {
        liveEntryIDs.union(protectedEntryIDs)
    }

    init(
        supervisor: ProcessSupervisor,
        terminalSurfaceFactory: TerminalSurfaceFactory? = nil
    ) {
        self.supervisor = supervisor
        processClient = RuntimeProcessClient(supervisor: supervisor)
        self.terminalSurfaceFactory = terminalSurfaceFactory
    }

    init(
        supervisor: ProcessSupervisor,
        processClient: RuntimeProcessClient,
        terminalSurfaceFactory: TerminalSurfaceFactory? = nil
    ) {
        self.supervisor = supervisor
        self.processClient = processClient
        self.terminalSurfaceFactory = terminalSurfaceFactory
    }

    func runtime(for entryID: UUID) -> EntryRuntime {
        if let runtime = runtimes[entryID] {
            return runtime
        }
        let runtime = EntryRuntime(entryID: entryID)
        runtimes[entryID] = runtime
        return runtime
    }

    func protectionCount(for entryID: UUID) -> Int {
        protectionCounts[entryID] ?? 0
    }

    func reserveOperations(
        entryIDs: [UUID]
    ) -> RuntimeOperationReservation {
        let reservation = RuntimeOperationReservation(id: UUID())
        let uniqueEntryIDs = Set(entryIDs)
        reservations[reservation.id] = uniqueEntryIDs
        for entryID in uniqueEntryIDs {
            protectionCounts[entryID, default: 0] += 1
        }
        return reservation
    }

    func start(_ entry: CommandEntry) async -> EntryActionResult {
        let reservation = reserveOperations(entryIDs: [entry.id])
        return await start(entry, reservation: reservation)
    }

    func start(
        _ entry: CommandEntry,
        reservation: RuntimeOperationReservation
    ) async -> EntryActionResult {
        require(
            reservation,
            protects: [entry.id]
        )
        defer { releaseReservation(reservation) }
        return await startOperation(entry)
    }

    private func startOperation(
        _ entry: CommandEntry
    ) async -> EntryActionResult {
        guard admitLaunch() else {
            return recordFailure(
                RuntimeStoreError.terminationInProgress,
                for: runtime(for: entry.id)
            )
        }
        defer { completeAdmittedLaunch() }

        let lane = lane(for: entry.id)
        await lane.acquire()
        if Task.isCancelled {
            await lane.release()
            return recordFailure(
                RuntimeStoreError.operationCancelled,
                for: runtime(for: entry.id)
            )
        }
        let operationID = beginOperation(entryID: entry.id)
        let result = await startLocked(
            entry,
            operationID: operationID
        )
        finishOperation(entryID: entry.id, operationID: operationID)
        await lane.release()
        return result
    }

    func stop(
        _ entry: CommandEntry,
        timeout: Duration = .seconds(5)
    ) async -> EntryActionResult {
        let reservation = reserveOperations(entryIDs: [entry.id])
        return await stop(
            entry,
            timeout: timeout,
            reservation: reservation
        )
    }

    func stop(
        _ entry: CommandEntry,
        timeout: Duration = .seconds(5),
        reservation: RuntimeOperationReservation
    ) async -> EntryActionResult {
        require(
            reservation,
            protects: [entry.id]
        )
        defer { releaseReservation(reservation) }
        knownEntries[entry.id] = entry
        return await stopSerialized(
            entryID: entry.id,
            timeout: timeout
        )
    }

    func restart(
        _ entry: CommandEntry,
        timeout: Duration = .seconds(5)
    ) async -> EntryActionResult {
        let reservation = reserveOperations(entryIDs: [entry.id])
        return await restart(
            entry,
            timeout: timeout,
            reservation: reservation
        )
    }

    func restart(
        _ entry: CommandEntry,
        timeout: Duration = .seconds(5),
        reservation: RuntimeOperationReservation
    ) async -> EntryActionResult {
        require(
            reservation,
            protects: [entry.id]
        )
        defer { releaseReservation(reservation) }
        return await restartOperation(entry, timeout: timeout)
    }

    private func restartOperation(
        _ entry: CommandEntry,
        timeout: Duration
    ) async -> EntryActionResult {
        guard admitLaunch() else {
            return recordFailure(
                RuntimeStoreError.terminationInProgress,
                for: runtime(for: entry.id)
            )
        }
        defer { completeAdmittedLaunch() }

        let lane = lane(for: entry.id)
        await lane.acquire()
        if Task.isCancelled {
            await lane.release()
            return recordFailure(
                RuntimeStoreError.operationCancelled,
                for: runtime(for: entry.id)
            )
        }
        let operationID = beginOperation(entryID: entry.id)
        knownEntries[entry.id] = entry

        let stopped = await stopLocked(
            entryID: entry.id,
            timeout: timeout,
            operationID: operationID
        )
        let result: EntryActionResult
        if stopped.isSuccess {
            result = await startLocked(
                entry,
                operationID: operationID
            )
        } else {
            result = stopped
        }

        finishOperation(entryID: entry.id, operationID: operationID)
        await lane.release()
        return result
    }

    func startAll(_ entries: [CommandEntry]) async -> [EntryActionResult] {
        let reservation = reserveOperations(
            entryIDs: entries.map(\.id)
        )
        return await startAll(
            entries,
            reservation: reservation
        )
    }

    func startAll(
        _ entries: [CommandEntry],
        reservation: RuntimeOperationReservation
    ) async -> [EntryActionResult] {
        require(
            reservation,
            protects: entries.map(\.id)
        )
        defer { releaseReservation(reservation) }
        return await performAll(entries, action: .start)
    }

    func stopAll(
        _ entries: [CommandEntry],
        timeout: Duration = .seconds(5)
    ) async -> [EntryActionResult] {
        let reservation = reserveOperations(
            entryIDs: entries.map(\.id)
        )
        return await stopAll(
            entries,
            timeout: timeout,
            reservation: reservation
        )
    }

    func stopAll(
        _ entries: [CommandEntry],
        timeout: Duration = .seconds(5),
        reservation: RuntimeOperationReservation
    ) async -> [EntryActionResult] {
        require(
            reservation,
            protects: entries.map(\.id)
        )
        defer { releaseReservation(reservation) }
        return await performAll(
            entries,
            action: .stop(timeout)
        )
    }

    func restartAll(
        _ entries: [CommandEntry],
        timeout: Duration = .seconds(5)
    ) async -> [EntryActionResult] {
        let reservation = reserveOperations(
            entryIDs: entries.map(\.id)
        )
        return await restartAll(
            entries,
            timeout: timeout,
            reservation: reservation
        )
    }

    func restartAll(
        _ entries: [CommandEntry],
        timeout: Duration = .seconds(5),
        reservation: RuntimeOperationReservation
    ) async -> [EntryActionResult] {
        require(
            reservation,
            protects: entries.map(\.id)
        )
        defer { releaseReservation(reservation) }
        return await performAll(
            entries,
            action: .restart(timeout)
        )
    }

    func beginMonitoring() {
        guard !liveEntryIDs.isEmpty,
              monitoringTask == nil else {
            return
        }

        let id = UUID()
        monitoringID = id
        monitoringTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: .seconds(1))
                } catch {
                    break
                }
                guard let self, !Task.isCancelled else {
                    break
                }
                await self.refreshAll()
                if self.liveEntryIDs.isEmpty {
                    break
                }
            }
            self?.finishMonitoring(id: id)
        }
    }

    func refreshAll() async {
        var requests: [ProbeRequest] = []
        for entryRuntime in runtimes.values {
            guard entryRuntime.process.liveness == .running,
                  entryRuntime.process.processGroupID != nil,
                  let generation = runtimeGenerations[
                    entryRuntime.entryID
                  ] else {
                continue
            }
            requests.append(ProbeRequest(
                entryID: entryRuntime.entryID,
                generation: generation,
                projectionRevision: advanceProjectionRevision(
                    entryID: entryRuntime.entryID
                )
            ))
        }

        let results = await withTaskGroup(
            of: ProbeResult.self,
            returning: [ProbeResult].self
        ) { group in
            for request in requests {
                group.addTask {
                    do {
                        return ProbeResult(
                            entryID: request.entryID,
                            generation: request.generation,
                            projectionRevision:
                                request.projectionRevision,
                            snapshot: try await self.processClient.refresh(
                                entryID: request.entryID
                            ),
                            errorDescription: nil
                        )
                    } catch {
                        return ProbeResult(
                            entryID: request.entryID,
                            generation: request.generation,
                            projectionRevision:
                                request.projectionRevision,
                            snapshot: nil,
                            errorDescription: describeProcessError(error)
                        )
                    }
                }
            }

            var values: [ProbeResult] = []
            for await result in group {
                values.append(result)
            }
            return values
        }

        for result in results {
            guard runtimeGenerations[result.entryID]
                    == result.generation,
                  projectionRevisions[result.entryID]
                    == result.projectionRevision else {
                continue
            }
            let entryRuntime = runtime(for: result.entryID)
            if let snapshot = result.snapshot {
                entryRuntime.process = snapshot
            }
            if let errorDescription = result.errorDescription {
                entryRuntime.lastError = errorDescription
            }
        }
        stopMonitoringIfIdle()
    }

    func refreshManagedRecords() async throws -> [
        UUID: ProcessSnapshot
    ] {
        let enumerationRevision = advanceManagedEnumerationRevision()
        var captures: [UUID: ManagedProjectionCapture] = [:]
        for entryID in runtimes.keys {
            captures[entryID] = ManagedProjectionCapture(
                generation: runtimeGenerations[entryID],
                projectionRevision: advanceProjectionRevision(
                    entryID: entryID
                )
            )
        }
        let snapshots = try await processClient.snapshots()

        guard managedEnumerationRevision == enumerationRevision else {
            return snapshots
        }
        for entryID in snapshots.keys.sorted(by: uuidLessThan) {
            guard let snapshot = snapshots[entryID] else {
                continue
            }
            if let capture = captures[entryID] {
                guard runtimeGenerations[entryID]
                        == capture.generation,
                      projectionRevisions[entryID]
                        == capture.projectionRevision else {
                    continue
                }
            } else {
                guard runtimes[entryID] == nil,
                      runtimeGenerations[entryID] == nil,
                      projectionRevisions[entryID] == nil else {
                    continue
                }
                _ = advanceProjectionRevision(entryID: entryID)
            }
            adoptManagedSnapshot(snapshot)
        }
        stopMonitoringIfIdle()
        return snapshots
    }

    func clearOutput(entryID: UUID) {
        let entryRuntime = runtime(for: entryID)
        let generations = outputSessions.compactMap {
            generation, session -> UUID? in
            session.entryID == entryID ? generation : nil
        }
        for generation in generations {
            guard var session = outputSessions[generation] else {
                continue
            }
            session.pipeline.clear()
            session.retainedLines.removeAll()
            session.retainedMatch = nil
            session.latestUpdate = OutputUpdate(
                snapshot: OutputSnapshot(
                    committedLines: [],
                    currentLine: "",
                    latestMatch: nil
                ),
                matches: []
            )
            session.latestGlobalMatch = nil
            outputSessions[generation] = session
        }
        entryRuntime.output = OutputSnapshot(
            committedLines: [],
            currentLine: "",
            latestMatch: nil
        )
        entryRuntime.terminalSurface?.clear()
        if latestGlobalMatch?.entryID == entryID {
            latestGlobalMatch = nil
        }
    }

    func removeEntry(entryID: UUID) throws {
        guard !deletionProtectedEntryIDs.contains(entryID) else {
            throw RuntimeStoreError.entryRemovalProtected(entryID)
        }

        _ = advanceManagedEnumerationRevision()
        removeOutputSessions(entryID: entryID, except: nil)
        runtimeGenerations.removeValue(forKey: entryID)
        projectionRevisions.removeValue(forKey: entryID)
        operationIDs.removeValue(forKey: entryID)
        entryLanes.removeValue(forKey: entryID)
        knownEntries.removeValue(forKey: entryID)

        if let entryRuntime = runtimes.removeValue(
            forKey: entryID
        ) {
            entryRuntime.terminalSurface?.dispose()
            entryRuntime.terminalSurface = nil
        }
        if latestGlobalMatch?.entryID == entryID {
            latestGlobalMatch = nil
        }
        stopMonitoringIfIdle()
    }

    func disposeAllTerminalSurfaces() {
        var disposedSurfaceIDs: Set<ObjectIdentifier> = []
        for entryRuntime in runtimes.values {
            guard let surface = entryRuntime.terminalSurface else {
                continue
            }
            let surfaceID = ObjectIdentifier(surface)
            if disposedSurfaceIDs.insert(surfaceID).inserted {
                surface.dispose()
            }
            entryRuntime.terminalSurface = nil
        }
    }

    var liveEntryIDs: Set<UUID> {
        Set(
            runtimes.values.compactMap { entryRuntime in
                guard entryRuntime.process.liveness == .running,
                      entryRuntime.process.processGroupID != nil else {
                    return nil
                }
                return entryRuntime.entryID
            }
        )
    }

    func entries(for entryIDs: [UUID]) -> [CommandEntry] {
        entryIDs.compactMap { knownEntries[$0] }
    }

    func remainingProcesses(
        among entryIDs: [UUID]
    ) -> [RemainingProcess] {
        entryIDs.compactMap { entryID in
            let process = runtime(for: entryID).process
            guard process.liveness == .running,
                  let processGroupID = process.processGroupID else {
                return nil
            }
            return RemainingProcess(
                entryID: entryID,
                processGroupID: processGroupID
            )
        }
    }

    func beginTerminationBarrier() -> TerminationBarrierToken {
        if let terminationBarrier {
            return terminationBarrier
        }
        let token = TerminationBarrierToken(id: UUID())
        terminationBarrier = token
        return token
    }

    func waitForAdmittedLaunches() async {
        guard admittedLaunchCount > 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            launchDrainWaiters.append(continuation)
        }
    }

    func cancelTerminationBarrier(_ token: TerminationBarrierToken) {
        guard terminationBarrier == token else {
            return
        }
        terminationBarrier = nil
    }

    func stopManagedRecords(
        entryIDs: [UUID],
        timeout: Duration
    ) async -> [EntryActionResult] {
        let reservation = reserveOperations(entryIDs: entryIDs)
        defer { releaseReservation(reservation) }
        return await withTaskGroup(
            of: (Int, EntryActionResult).self,
            returning: [EntryActionResult].self
        ) { group in
            for (index, entryID) in entryIDs.enumerated() {
                group.addTask {
                    (
                        index,
                        await self.stopSerialized(
                            entryID: entryID,
                            timeout: timeout
                        )
                    )
                }
            }

            var values: [(Int, EntryActionResult)] = []
            for await value in group {
                values.append(value)
            }
            return values.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func stopSerialized(
        entryID: UUID,
        timeout: Duration
    ) async -> EntryActionResult {
        let lane = lane(for: entryID)
        await lane.acquire()
        let operationID = beginOperation(entryID: entryID)
        let result = await stopLocked(
            entryID: entryID,
            timeout: timeout,
            operationID: operationID
        )
        finishOperation(
            entryID: entryID,
            operationID: operationID
        )
        await lane.release()
        return result
    }

    private func startLocked(
        _ entry: CommandEntry,
        operationID: UUID
    ) async -> EntryActionResult {
        let entryRuntime = runtime(for: entry.id)
        do {
            try validateWorkingDirectory(entry.cwd)
        } catch {
            guard operationIsCurrent(
                entryID: entry.id,
                operationID: operationID
            ) else {
                return supersededResult(entryID: entry.id)
            }
            return recordFailure(error, for: entryRuntime)
        }

        let priorGeneration = runtimeGenerations[entry.id]
        let nextGeneration = UUID()
        let sessionStartedAt = Date()
        installPendingOutputSession(
            for: entry,
            generation: nextGeneration,
            retaining: entryRuntime.output,
            at: sessionStartedAt
        )
        let terminalSurface = prepareTerminalSession(
            entryRuntime: entryRuntime,
            entryID: entry.id,
            generation: nextGeneration
        )

        do {
            let snapshot = try await processClient.start(
                entry: entry,
                generation: nextGeneration
            ) {
                [weak self] data in
                terminalSurface?.feed(
                    data,
                    generation: nextGeneration
                )
                Task { @MainActor [weak self] in
                    self?.consume(
                        data,
                        entryID: entry.id,
                        generation: nextGeneration
                    )
                }
            }
            guard operationIsCurrent(
                entryID: entry.id,
                operationID: operationID
            ), runtimeGenerations[entry.id] == priorGeneration else {
                discardPendingSession(
                    entryID: entry.id,
                    generation: nextGeneration,
                    terminalSurface: terminalSurface
                )
                return supersededResult(entryID: entry.id)
            }

            _ = advanceProjectionRevision(entryID: entry.id)
            promoteOutputSession(
                entryID: entry.id,
                generation: nextGeneration
            )
            terminalSurface?.promote(
                generation: nextGeneration,
                at: sessionStartedAt
            )
            entryRuntime.process = snapshot
            entryRuntime.lastError = nil
            knownEntries[entry.id] = entry
            beginMonitoring()
            return EntryActionResult(
                entryID: entry.id,
                errorDescription: nil
            )
        } catch {
            guard operationIsCurrent(
                entryID: entry.id,
                operationID: operationID
            ), runtimeGenerations[entry.id] == priorGeneration else {
                discardPendingSession(
                    entryID: entry.id,
                    generation: nextGeneration,
                    terminalSurface: terminalSurface
                )
                return supersededResult(entryID: entry.id)
            }
            discardPendingSession(
                entryID: entry.id,
                generation: nextGeneration,
                terminalSurface: terminalSurface
            )
            return recordFailure(error, for: entryRuntime)
        }
    }

    private func stopLocked(
        entryID: UUID,
        timeout: Duration,
        operationID: UUID
    ) async -> EntryActionResult {
        let entryRuntime = runtime(for: entryID)
        guard entryRuntime.process.processGroupID != nil else {
            guard operationIsCurrent(
                entryID: entryID,
                operationID: operationID
            ) else {
                return supersededResult(entryID: entryID)
            }
            _ = advanceProjectionRevision(entryID: entryID)
            entryRuntime.lastError = nil
            stopMonitoringIfIdle()
            return EntryActionResult(
                entryID: entryID,
                errorDescription: nil
            )
        }

        let generation = runtimeGenerations[entryID]
        do {
            let result = try await processClient.stop(
                entryID: entryID,
                timeout: timeout
            )
            guard operationIsCurrent(
                entryID: entryID,
                operationID: operationID
            ), runtimeGenerations[entryID] == generation else {
                return staleStopResult(result, entryID: entryID)
            }

            switch result {
            case .stopped, .alreadyStopped:
                let stopProjectionRevision =
                    advanceProjectionRevision(entryID: entryID)
                entryRuntime.lastError = nil
                let snapshot = try await processClient.refresh(
                    entryID: entryID
                )
                guard operationIsCurrent(
                    entryID: entryID,
                    operationID: operationID
                ), runtimeGenerations[entryID] == generation else {
                    return supersededResult(entryID: entryID)
                }
                guard projectionRevisions[entryID]
                        == stopProjectionRevision else {
                    stopMonitoringIfIdle()
                    return EntryActionResult(
                        entryID: entryID,
                        errorDescription: nil
                    )
                }
                entryRuntime.process = snapshot
                stopMonitoringIfIdle()
                return EntryActionResult(
                    entryID: entryID,
                    errorDescription: nil
                )
            case .timedOut(let snapshot):
                _ = advanceProjectionRevision(entryID: entryID)
                entryRuntime.process = snapshot
                let description = didNotStopDescription(snapshot)
                entryRuntime.lastError = description
                beginMonitoring()
                return EntryActionResult(
                    entryID: entryID,
                    errorDescription: description
                )
            }
        } catch {
            guard operationIsCurrent(
                entryID: entryID,
                operationID: operationID
            ), runtimeGenerations[entryID] == generation else {
                return supersededResult(entryID: entryID)
            }
            return recordFailure(error, for: entryRuntime)
        }
    }

    private func performAll(
        _ entries: [CommandEntry],
        action: GroupAction
    ) async -> [EntryActionResult] {
        await withTaskGroup(
            of: (Int, EntryActionResult).self,
            returning: [EntryActionResult].self
        ) { group in
            for (index, entry) in entries.enumerated() {
                group.addTask {
                    let result: EntryActionResult
                    switch action {
                    case .start:
                        result = await self.startOperation(entry)
                    case .stop(let timeout):
                        result = await self.stopOperation(
                            entry,
                            timeout: timeout
                        )
                    case .restart(let timeout):
                        result = await self.restartOperation(
                            entry,
                            timeout: timeout
                        )
                    }
                    return (index, result)
                }
            }

            var values: [(Int, EntryActionResult)] = []
            for await value in group {
                values.append(value)
            }
            return values.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func stopOperation(
        _ entry: CommandEntry,
        timeout: Duration
    ) async -> EntryActionResult {
        knownEntries[entry.id] = entry
        return await stopSerialized(
            entryID: entry.id,
            timeout: timeout
        )
    }

    private func installPendingOutputSession(
        for entry: CommandEntry,
        generation: UUID,
        retaining priorOutput: OutputSnapshot,
        at timestamp: Date
    ) {
        var retainedLines = priorOutput.committedLines
        if !priorOutput.currentLine.isEmpty {
            retainedLines.append(priorOutput.currentLine)
        }

        var pipeline = OutputPipeline(
            entryID: entry.id,
            keywords: entry.keywords,
            lineLimit: 20_000
        )
        let separator = pipeline.insertSessionSeparator(at: timestamp)
        outputSessions[generation] = OutputSession(
            entryID: entry.id,
            pipeline: pipeline,
            retainedLines: retainedLines,
            retainedMatch: priorOutput.latestMatch,
            latestUpdate: separator,
            latestGlobalMatch: separator.matches.last
        )
    }

    private func prepareTerminalSession(
        entryRuntime: EntryRuntime,
        entryID: UUID,
        generation: UUID
    ) -> (any TerminalSurface)? {
        let terminalSurface: (any TerminalSurface)?
        if let retainedSurface = entryRuntime.terminalSurface {
            terminalSurface = retainedSurface
        } else if let terminalSurfaceFactory {
            do {
                let createdSurface = try terminalSurfaceFactory.makeSurface(
                    entryID,
                    terminalCallbacks(entryID: entryID)
                )
                entryRuntime.terminalSurface = createdSurface
                entryRuntime.terminalRendererState =
                    createdSurface.rendererState
                if case .unavailable =
                        createdSurface.rendererState {
                    entryRuntime.outputDisplayMode = .text
                }
                createdSurface.onRendererStateChange = {
                    [weak entryRuntime] rendererState in
                    Task { @MainActor in
                        entryRuntime?.terminalRendererState =
                            rendererState
                        if case .unavailable = rendererState {
                            entryRuntime?.outputDisplayMode = .text
                        }
                    }
                }
                terminalSurface = createdSurface
            } catch {
                entryRuntime.outputDisplayMode = .text
                entryRuntime.terminalRendererState = .unavailable(
                    error.localizedDescription
                )
                terminalSurface = nil
            }
        } else {
            terminalSurface = nil
        }
        terminalSurface?.prepare(generation: generation)
        return terminalSurface
    }

    private func terminalCallbacks(
        entryID: UUID
    ) -> TerminalSurfaceCallbacks {
        let processClient = processClient
        return TerminalSurfaceCallbacks(
            writeProtocolReply: { [weak self] data, generation in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.runtimeGenerations[entryID]
                            == generation else {
                        return
                    }
                    do {
                        try await processClient.write(
                            entryID: entryID,
                            generation: generation,
                            data: data
                        )
                    } catch {
                        self.projectTerminalCallbackError(
                            error,
                            entryID: entryID,
                            generation: generation
                        )
                    }
                }
            },
            resizePTY: { [weak self] size, generation in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.runtimeGenerations[entryID]
                            == generation else {
                        return
                    }
                    do {
                        try await processClient.resize(
                            entryID: entryID,
                            generation: generation,
                            size: size
                        )
                    } catch {
                        self.projectTerminalCallbackError(
                            error,
                            entryID: entryID,
                            generation: generation
                        )
                    }
                }
            }
        )
    }

    private func projectTerminalCallbackError(
        _ error: Error,
        entryID: UUID,
        generation: UUID
    ) {
        guard runtimeGenerations[entryID] == generation else {
            return
        }
        if let supervisorError = error
                as? ProcessSupervisorError {
            switch supervisorError {
            case .staleGeneration:
                return
            case .unknownEntry
                where runtime(for: entryID).process.liveness
                    == .stopped:
                return
            case .alreadyRunning, .stopTimedOut, .unknownEntry:
                break
            }
        }
        runtime(for: entryID).lastError =
            describeProcessError(error)
    }

    private func discardPendingSession(
        entryID: UUID,
        generation: UUID,
        terminalSurface: (any TerminalSurface)?
    ) {
        outputSessions.removeValue(forKey: generation)
        terminalSurface?.discard(generation: generation)
        if runtimeGenerations[entryID] == generation {
            runtimeGenerations.removeValue(forKey: entryID)
        }
    }

    private func promoteOutputSession(
        entryID: UUID,
        generation: UUID
    ) {
        guard let session = outputSessions[generation] else {
            return
        }
        removeOutputSessions(
            entryID: entryID,
            except: generation
        )
        runtimeGenerations[entryID] = generation
        apply(
            session.latestUpdate,
            from: session,
            to: runtime(for: entryID)
        )
        if let match = session.latestGlobalMatch {
            latestGlobalMatch = match
        }
    }

    private func consume(
        _ data: Data,
        entryID: UUID,
        generation: UUID
    ) {
        guard var session = outputSessions[generation],
              session.entryID == entryID else {
            return
        }

        let update = session.pipeline.consume(data, at: Date())
        session.latestUpdate = update
        session.latestGlobalMatch = update.matches.last
            ?? session.latestGlobalMatch
        outputSessions[generation] = session

        guard runtimeGenerations[entryID] == generation else {
            return
        }
        apply(update, from: session, to: runtime(for: entryID))
        if let match = update.matches.last {
            latestGlobalMatch = match
        }
    }

    private func apply(
        _ update: OutputUpdate,
        from session: OutputSession,
        to entryRuntime: EntryRuntime
    ) {
        let committedLines = Array(
            (session.retainedLines + update.snapshot.committedLines)
                .suffix(20_000)
        )
        entryRuntime.output = OutputSnapshot(
            committedLines: committedLines,
            currentLine: update.snapshot.currentLine,
            latestMatch: update.snapshot.latestMatch
                ?? session.retainedMatch
        )
    }

    private func adoptManagedSnapshot(_ snapshot: ProcessSnapshot) {
        let entryRuntime = runtime(for: snapshot.entryID)
        if !sameProcessIdentity(entryRuntime.process, snapshot) {
            runtimeGenerations[snapshot.entryID] = UUID()
            removeOutputSessions(
                entryID: snapshot.entryID,
                except: nil
            )
        }
        entryRuntime.process = snapshot
    }

    private func sameProcessIdentity(
        _ lhs: ProcessSnapshot,
        _ rhs: ProcessSnapshot
    ) -> Bool {
        lhs.pid == rhs.pid
            && lhs.processGroupID == rhs.processGroupID
            && lhs.launchedAt == rhs.launchedAt
    }

    private func removeOutputSessions(
        entryID: UUID,
        except retainedGeneration: UUID?
    ) {
        let generations = outputSessions.compactMap {
            generation, session -> UUID? in
            guard session.entryID == entryID,
                  generation != retainedGeneration else {
                return nil
            }
            return generation
        }
        generations.forEach {
            outputSessions.removeValue(forKey: $0)
        }
    }

    private func lane(for entryID: UUID) -> EntryOperationLane {
        if let lane = entryLanes[entryID] {
            return lane
        }
        let lane = EntryOperationLane()
        entryLanes[entryID] = lane
        return lane
    }

    private func beginOperation(entryID: UUID) -> UUID {
        let id = UUID()
        operationIDs[entryID] = id
        return id
    }

    private func finishOperation(
        entryID: UUID,
        operationID: UUID
    ) {
        guard operationIDs[entryID] == operationID else {
            return
        }
        operationIDs.removeValue(forKey: entryID)
    }

    private func operationIsCurrent(
        entryID: UUID,
        operationID: UUID
    ) -> Bool {
        operationIDs[entryID] == operationID
    }

    @discardableResult
    private func advanceProjectionRevision(
        entryID: UUID
    ) -> UInt64 {
        let current = projectionRevisions[entryID] ?? 0
        precondition(
            current < UInt64.max,
            "Projection revision exhausted for \(entryID)."
        )
        let next = current + 1
        projectionRevisions[entryID] = next
        return next
    }

    private func advanceManagedEnumerationRevision() -> UInt64 {
        precondition(
            managedEnumerationRevision < UInt64.max,
            "Managed enumeration revision exhausted."
        )
        managedEnumerationRevision += 1
        return managedEnumerationRevision
    }

    private func require(
        _ reservation: RuntimeOperationReservation,
        protects entryIDs: [UUID]
    ) {
        guard let protectedIDs = reservations[reservation.id],
              Set(entryIDs).isSubset(of: protectedIDs) else {
            preconditionFailure(
                "Runtime operation used an inactive or mismatched reservation."
            )
        }
    }

    private func releaseReservation(
        _ reservation: RuntimeOperationReservation
    ) {
        guard let entryIDs = reservations.removeValue(
            forKey: reservation.id
        ) else {
            return
        }
        for entryID in entryIDs {
            guard let count = protectionCounts[entryID],
                  count > 0 else {
                preconditionFailure(
                    "Runtime protection count is unbalanced."
                )
            }
            if count == 1 {
                protectionCounts.removeValue(forKey: entryID)
            } else {
                protectionCounts[entryID] = count - 1
            }
        }
    }

    private func admitLaunch() -> Bool {
        guard terminationBarrier == nil else {
            return false
        }
        admittedLaunchCount += 1
        return true
    }

    private func completeAdmittedLaunch() {
        precondition(admittedLaunchCount > 0)
        admittedLaunchCount -= 1
        guard admittedLaunchCount == 0 else {
            return
        }
        let waiters = launchDrainWaiters
        launchDrainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func recordFailure(
        _ error: Error,
        for entryRuntime: EntryRuntime
    ) -> EntryActionResult {
        _ = advanceProjectionRevision(entryID: entryRuntime.entryID)
        let description = describeProcessError(error)
        entryRuntime.lastError = description
        return EntryActionResult(
            entryID: entryRuntime.entryID,
            errorDescription: description
        )
    }

    private func supersededResult(entryID: UUID) -> EntryActionResult {
        EntryActionResult(
            entryID: entryID,
            errorDescription: RuntimeStoreError.operationSuperseded
                .localizedDescription
        )
    }

    private func staleStopResult(
        _ result: StopResult,
        entryID: UUID
    ) -> EntryActionResult {
        if case .timedOut(let snapshot) = result {
            return EntryActionResult(
                entryID: entryID,
                errorDescription: didNotStopDescription(snapshot)
            )
        }
        return supersededResult(entryID: entryID)
    }

    private func validateWorkingDirectory(_ cwd: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: cwd,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw WorkspaceStoreError.cwdIsNotDirectory(cwd)
        }
    }

    private func stopMonitoringIfIdle() {
        guard liveEntryIDs.isEmpty else {
            return
        }
        monitoringTask?.cancel()
        monitoringTask = nil
        monitoringID = nil
    }

    private func finishMonitoring(id: UUID) {
        guard monitoringID == id else {
            return
        }
        monitoringTask = nil
        monitoringID = nil
    }
}

private actor EntryOperationLane {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        waiters.removeFirst().resume()
    }
}

private func describeProcessError(_ error: Error) -> String {
    if let error = error as? LocalizedError,
       let description = error.errorDescription {
        return description
    }
    if let error = error as? ProcessLaunchError {
        let systemMessage = String(cString: strerror(error.code))
        return L10n.format(
            "Launch failed during %@: %@",
            error.phase.rawValue,
            systemMessage
        )
    }
    if let error = error as? ProcessSupervisorError {
        switch error {
        case .alreadyRunning:
            return L10n.string("The entry is already running.")
        case .staleGeneration:
            return L10n.string(
                "The operation was superseded by a newer process generation."
            )
        case .stopTimedOut:
            return L10n.string(
                "The process group did not stop before the timeout."
            )
        case .unknownEntry:
            return L10n.string(
                "The entry has no managed process."
            )
        }
    }
    return error.localizedDescription
}

private func didNotStopDescription(
    _ snapshot: ProcessSnapshot
) -> String {
    let processGroup = snapshot.processGroupID.map(String.init)
        ?? L10n.string("unknown")
    return L10n.format(
        "Did not stop process group %@.",
        processGroup
    )
}

private func uuidLessThan(_ lhs: UUID, _ rhs: UUID) -> Bool {
    lhs.uuidString < rhs.uuidString
}

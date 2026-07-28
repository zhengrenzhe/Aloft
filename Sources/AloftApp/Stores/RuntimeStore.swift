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
        RuntimeOutputHandler
    ) async throws -> ProcessSnapshot
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
    private let stopOperation: StopOperation
    private let refreshOperation: RefreshOperation
    private let snapshotsOperation: SnapshotsOperation

    init(
        start: @escaping StartOperation,
        stop: @escaping StopOperation,
        refresh: @escaping RefreshOperation,
        snapshots: @escaping SnapshotsOperation
    ) {
        startOperation = start
        stopOperation = stop
        refreshOperation = refresh
        snapshotsOperation = snapshots
    }

    init(supervisor: ProcessSupervisor) {
        self.init(
            start: { entry, onOutput in
                try await supervisor.start(
                    entry: entry,
                    onOutput: onOutput.handler
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
        onOutput: @escaping OutputHandler
    ) async throws -> ProcessSnapshot {
        try await startOperation(
            entry,
            RuntimeOutputHandler(handler: onOutput)
        )
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

    var errorDescription: String? {
        switch self {
        case .terminationInProgress:
            return "Aloft is stopping managed processes for termination."
        case .operationSuperseded:
            return "The operation was superseded by a newer process generation."
        }
    }
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
    }

    private struct ProbeResult: Sendable {
        let entryID: UUID
        let generation: UUID
        let snapshot: ProcessSnapshot?
        let errorDescription: String?
    }

    private enum GroupAction: Sendable {
        case start
        case stop(Duration)
        case restart(Duration)
    }

    private(set) var runtimes: [UUID: EntryRuntime] = [:]
    private(set) var latestGlobalMatch: KeywordMatchEvent?

    @ObservationIgnored
    let supervisor: ProcessSupervisor

    @ObservationIgnored
    private let processClient: RuntimeProcessClient

    @ObservationIgnored
    private var outputSessions: [UUID: OutputSession] = [:]

    @ObservationIgnored
    private var runtimeGenerations: [UUID: UUID] = [:]

    @ObservationIgnored
    private var operationIDs: [UUID: UUID] = [:]

    @ObservationIgnored
    private var entryLanes: [UUID: EntryOperationLane] = [:]

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

    init(supervisor: ProcessSupervisor) {
        self.supervisor = supervisor
        processClient = RuntimeProcessClient(supervisor: supervisor)
    }

    init(
        supervisor: ProcessSupervisor,
        processClient: RuntimeProcessClient
    ) {
        self.supervisor = supervisor
        self.processClient = processClient
    }

    func runtime(for entryID: UUID) -> EntryRuntime {
        if let runtime = runtimes[entryID] {
            return runtime
        }
        let runtime = EntryRuntime(entryID: entryID)
        runtimes[entryID] = runtime
        return runtime
    }

    func start(_ entry: CommandEntry) async -> EntryActionResult {
        guard admitLaunch() else {
            return recordFailure(
                RuntimeStoreError.terminationInProgress,
                for: runtime(for: entry.id)
            )
        }

        let lane = lane(for: entry.id)
        await lane.acquire()
        let operationID = beginOperation(entryID: entry.id)
        let result = await startLocked(
            entry,
            operationID: operationID
        )
        finishOperation(entryID: entry.id, operationID: operationID)
        await lane.release()
        completeAdmittedLaunch()
        return result
    }

    func stop(
        _ entry: CommandEntry,
        timeout: Duration = .seconds(5)
    ) async -> EntryActionResult {
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
        guard admitLaunch() else {
            return recordFailure(
                RuntimeStoreError.terminationInProgress,
                for: runtime(for: entry.id)
            )
        }

        let lane = lane(for: entry.id)
        await lane.acquire()
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
        completeAdmittedLaunch()
        return result
    }

    func startAll(_ entries: [CommandEntry]) async -> [EntryActionResult] {
        await performAll(entries, action: .start)
    }

    func stopAll(
        _ entries: [CommandEntry],
        timeout: Duration = .seconds(5)
    ) async -> [EntryActionResult] {
        await performAll(entries, action: .stop(timeout))
    }

    func restartAll(
        _ entries: [CommandEntry],
        timeout: Duration = .seconds(5)
    ) async -> [EntryActionResult] {
        await performAll(entries, action: .restart(timeout))
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
        let requests = runtimes.values.compactMap {
            entryRuntime -> ProbeRequest? in
            guard entryRuntime.process.liveness == .running,
                  entryRuntime.process.processGroupID != nil,
                  let generation = runtimeGenerations[
                    entryRuntime.entryID
                  ] else {
                return nil
            }
            return ProbeRequest(
                entryID: entryRuntime.entryID,
                generation: generation
            )
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
                            snapshot: try await self.processClient.refresh(
                                entryID: request.entryID
                            ),
                            errorDescription: nil
                        )
                    } catch {
                        return ProbeResult(
                            entryID: request.entryID,
                            generation: request.generation,
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
                    == result.generation else {
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
        let capturedGenerations = runtimeGenerations
        let snapshots = try await processClient.snapshots()

        for entryID in snapshots.keys.sorted(by: uuidLessThan) {
            guard runtimeGenerations[entryID]
                    == capturedGenerations[entryID],
                  let snapshot = snapshots[entryID] else {
                continue
            }
            adoptManagedSnapshot(snapshot)
        }
        stopMonitoringIfIdle()
        return snapshots
    }

    func clearOutput(entryID: UUID) {
        let entryRuntime = runtime(for: entryID)
        if let generation = runtimeGenerations[entryID],
           var session = outputSessions[generation] {
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
        if latestGlobalMatch?.entryID == entryID {
            latestGlobalMatch = nil
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
        await withTaskGroup(
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
        installPendingOutputSession(
            for: entry,
            generation: nextGeneration,
            retaining: entryRuntime.output
        )

        do {
            let snapshot = try await processClient.start(entry: entry) {
                [weak self] data in
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
                return supersededResult(entryID: entry.id)
            }

            promoteOutputSession(
                entryID: entry.id,
                generation: nextGeneration
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
                return supersededResult(entryID: entry.id)
            }
            outputSessions.removeValue(forKey: nextGeneration)
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
                let snapshot = try await processClient.refresh(
                    entryID: entryID
                )
                guard operationIsCurrent(
                    entryID: entryID,
                    operationID: operationID
                ), runtimeGenerations[entryID] == generation else {
                    return supersededResult(entryID: entryID)
                }
                entryRuntime.process = snapshot
                entryRuntime.lastError = nil
                stopMonitoringIfIdle()
                return EntryActionResult(
                    entryID: entryID,
                    errorDescription: nil
                )
            case .timedOut(let snapshot):
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
                        result = await self.start(entry)
                    case .stop(let timeout):
                        result = await self.stop(
                            entry,
                            timeout: timeout
                        )
                    case .restart(let timeout):
                        result = await self.restart(
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

    private func installPendingOutputSession(
        for entry: CommandEntry,
        generation: UUID,
        retaining priorOutput: OutputSnapshot
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
        let separator = pipeline.insertSessionSeparator(at: Date())
        outputSessions[generation] = OutputSession(
            entryID: entry.id,
            pipeline: pipeline,
            retainedLines: retainedLines,
            retainedMatch: priorOutput.latestMatch,
            latestUpdate: separator,
            latestGlobalMatch: separator.matches.last
        )
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
        return "Launch failed during \(error.phase.rawValue): \(systemMessage)"
    }
    if let error = error as? ProcessSupervisorError {
        switch error {
        case .alreadyRunning:
            return "The entry is already running."
        case .stopTimedOut:
            return "The process group did not stop before the timeout."
        case .unknownEntry:
            return "The entry has no managed process."
        }
    }
    return error.localizedDescription
}

private func didNotStopDescription(
    _ snapshot: ProcessSnapshot
) -> String {
    let processGroup = snapshot.processGroupID.map(String.init)
        ?? "unknown"
    return "Did not stop process group \(processGroup)."
}

private func uuidLessThan(_ lhs: UUID, _ rhs: UUID) -> Bool {
    lhs.uuidString < rhs.uuidString
}

import Foundation
import Observation

struct EntryActionResult: Equatable, Sendable {
    let entryID: UUID
    let errorDescription: String?

    var isSuccess: Bool {
        errorDescription == nil
    }
}

@MainActor
@Observable
final class RuntimeStore {
    private struct OutputSession {
        let id: UUID
        var pipeline: OutputPipeline
        var retainedLines: [String]
        var retainedMatch: KeywordMatchEvent?
    }

    private struct ProbeResult: Sendable {
        let entryID: UUID
        let expectedProcessGroupID: pid_t
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
    private var outputSessions: [UUID: OutputSession] = [:]

    @ObservationIgnored
    private var knownEntries: [UUID: CommandEntry] = [:]

    @ObservationIgnored
    private var monitoringTask: Task<Void, Never>?

    @ObservationIgnored
    private var monitoringID: UUID?

    init(supervisor: ProcessSupervisor) {
        self.supervisor = supervisor
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
        let entryRuntime = runtime(for: entry.id)
        do {
            try validateWorkingDirectory(entry.cwd)
        } catch {
            return recordFailure(error, for: entryRuntime)
        }

        let priorOutput = entryRuntime.output
        let priorSession = outputSessions[entry.id]
        let sessionID = UUID()
        installOutputSession(
            for: entry,
            sessionID: sessionID,
            retaining: priorOutput
        )

        do {
            let snapshot = try await supervisor.start(entry: entry) {
                [weak self] data in
                Task { @MainActor [weak self] in
                    self?.consume(
                        data,
                        entryID: entry.id,
                        sessionID: sessionID
                    )
                }
            }
            entryRuntime.process = snapshot
            entryRuntime.lastError = nil
            knownEntries[entry.id] = entry
            beginMonitoring()
            return EntryActionResult(
                entryID: entry.id,
                errorDescription: nil
            )
        } catch {
            entryRuntime.output = priorOutput
            if let priorSession {
                outputSessions[entry.id] = priorSession
            } else {
                outputSessions.removeValue(forKey: entry.id)
            }
            return recordFailure(error, for: entryRuntime)
        }
    }

    func stop(
        _ entry: CommandEntry,
        timeout: Duration = .seconds(5)
    ) async -> EntryActionResult {
        let entryRuntime = runtime(for: entry.id)
        knownEntries[entry.id] = entry

        guard entryRuntime.process.processGroupID != nil else {
            entryRuntime.lastError = nil
            stopMonitoringIfIdle()
            return EntryActionResult(
                entryID: entry.id,
                errorDescription: nil
            )
        }

        do {
            let result = try await supervisor.stop(
                entryID: entry.id,
                timeout: timeout
            )
            switch result {
            case .stopped, .alreadyStopped:
                entryRuntime.process = try await supervisor.refresh(
                    entryID: entry.id
                )
                entryRuntime.lastError = nil
                stopMonitoringIfIdle()
                return EntryActionResult(
                    entryID: entry.id,
                    errorDescription: nil
                )
            case .timedOut(let snapshot):
                entryRuntime.process = snapshot
                let description = "Did not stop process group \(snapshot.processGroupID.map(String.init) ?? "unknown")."
                entryRuntime.lastError = description
                beginMonitoring()
                return EntryActionResult(
                    entryID: entry.id,
                    errorDescription: description
                )
            }
        } catch {
            return recordFailure(error, for: entryRuntime)
        }
    }

    func restart(
        _ entry: CommandEntry,
        timeout: Duration = .seconds(5)
    ) async -> EntryActionResult {
        let stopped = await stop(entry, timeout: timeout)
        guard stopped.isSuccess else {
            return stopped
        }
        return await start(entry)
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
        let requests = runtimes.values.compactMap { runtime -> (UUID, pid_t)? in
            guard runtime.process.liveness == .running,
                  let processGroupID = runtime.process.processGroupID else {
                return nil
            }
            return (runtime.entryID, processGroupID)
        }

        let results = await withTaskGroup(
            of: ProbeResult.self,
            returning: [ProbeResult].self
        ) { group in
            for (entryID, processGroupID) in requests {
                group.addTask {
                    do {
                        return ProbeResult(
                            entryID: entryID,
                            expectedProcessGroupID: processGroupID,
                            snapshot: try await self.supervisor.refresh(
                                entryID: entryID
                            ),
                            errorDescription: nil
                        )
                    } catch {
                        return ProbeResult(
                            entryID: entryID,
                            expectedProcessGroupID: processGroupID,
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
            let entryRuntime = runtime(for: result.entryID)
            guard entryRuntime.process.processGroupID
                    == result.expectedProcessGroupID else {
                continue
            }
            if let snapshot = result.snapshot {
                entryRuntime.process = snapshot
            }
            if let errorDescription = result.errorDescription {
                entryRuntime.lastError = errorDescription
            }
        }
        stopMonitoringIfIdle()
    }

    func clearOutput(entryID: UUID) {
        let entryRuntime = runtime(for: entryID)
        if var session = outputSessions[entryID] {
            session.pipeline.clear()
            session.retainedLines.removeAll()
            session.retainedMatch = nil
            outputSessions[entryID] = session
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
            runtimes.values.compactMap { runtime in
                guard runtime.process.liveness == .running,
                      runtime.process.processGroupID != nil else {
                    return nil
                }
                return runtime.entryID
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
                        result = await self.stop(entry, timeout: timeout)
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

    private func installOutputSession(
        for entry: CommandEntry,
        sessionID: UUID,
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
        let session = OutputSession(
            id: sessionID,
            pipeline: pipeline,
            retainedLines: retainedLines,
            retainedMatch: priorOutput.latestMatch
        )
        outputSessions[entry.id] = session
        apply(separator, from: session, to: runtime(for: entry.id))
    }

    private func consume(
        _ data: Data,
        entryID: UUID,
        sessionID: UUID
    ) {
        guard var session = outputSessions[entryID],
              session.id == sessionID else {
            return
        }

        let update = session.pipeline.consume(data, at: Date())
        outputSessions[entryID] = session
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

private func describeProcessError(_ error: Error) -> String {
    if let error = error as? WorkspaceStoreError {
        return error.localizedDescription
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

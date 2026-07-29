import Darwin
import Foundation

enum ProcessLiveness: String, Equatable, Sendable {
    case stopped
    case running
}

struct ProcessSnapshot: Equatable, Sendable {
    let entryID: UUID
    let pid: pid_t?
    let processGroupID: pid_t?
    let liveness: ProcessLiveness
    let launchedAt: Date?
    let exitResult: ChildWaitResult?
}

enum StopResult: Equatable, Sendable {
    case stopped
    case alreadyStopped
    case timedOut(ProcessSnapshot)
}

enum ProcessSupervisorError: Error, Equatable, Sendable {
    case alreadyRunning
    case stopTimedOut
    case unknownEntry
}

actor ProcessSupervisor {
    typealias OutputHandler = @Sendable (Data) -> Void

    private struct Record {
        let generation: UUID
        let entryID: UUID
        var pid: pid_t?
        var processGroupID: pid_t?
        var liveness: ProcessLiveness
        var launchedAt: Date?
        var exitResult: ChildWaitResult?
        var managedProcess: ManagedProcess?

        var snapshot: ProcessSnapshot {
            ProcessSnapshot(
                entryID: entryID,
                pid: pid,
                processGroupID: processGroupID,
                liveness: liveness,
                launchedAt: launchedAt,
                exitResult: exitResult
            )
        }
    }

    private struct CapturedProcess {
        let generation: UUID
        let entryID: UUID
        let pid: pid_t
        let processGroupID: pid_t
        let launchedAt: Date?
        var exitResult: ChildWaitResult?
        let managedProcess: ManagedProcess

        func snapshot(
            liveness: ProcessLiveness,
            includesIdentity: Bool = true
        ) -> ProcessSnapshot {
            ProcessSnapshot(
                entryID: entryID,
                pid: includesIdentity ? pid : nil,
                processGroupID: includesIdentity ? processGroupID : nil,
                liveness: liveness,
                launchedAt: launchedAt,
                exitResult: exitResult
            )
        }
    }

    private let probeInterval: Duration
    private var records: [UUID: Record] = [:]

    init(probeInterval: Duration = .milliseconds(50)) {
        self.probeInterval = probeInterval
    }

    func start(
        entry: CommandEntry,
        onOutput: @escaping OutputHandler
    ) throws -> ProcessSnapshot {
        if records[entry.id] != nil {
            let existing = try refreshRecord(entryID: entry.id)
            if existing.liveness == .running {
                throw ProcessSupervisorError.alreadyRunning
            }
        }

        let launched = try ProcessLauncher.launch(
            command: entry.command,
            cwd: entry.cwd,
            shell: entry.shell
        )
        let managedProcess = try ManagedProcess(
            masterFileDescriptor: launched.masterFileDescriptor,
            onOutput: onOutput
        )
        let record = Record(
            generation: UUID(),
            entryID: entry.id,
            pid: launched.pid,
            processGroupID: launched.processGroupID,
            liveness: .running,
            launchedAt: Date(),
            exitResult: nil,
            managedProcess: managedProcess
        )
        records[entry.id] = record
        return record.snapshot
    }

    func refresh(entryID: UUID) throws -> ProcessSnapshot {
        try refreshRecord(entryID: entryID)
    }

    func stop(
        entryID: UUID,
        timeout: Duration = .seconds(5)
    ) async throws -> StopResult {
        let snapshot = try refreshRecord(entryID: entryID)
        guard snapshot.liveness == .running,
              let record = records[entryID],
              let pid = record.pid,
              let processGroupID = record.processGroupID,
              let managedProcess = record.managedProcess else {
            return .alreadyStopped
        }
        var captured = CapturedProcess(
            generation: record.generation,
            entryID: entryID,
            pid: pid,
            processGroupID: processGroupID,
            launchedAt: record.launchedAt,
            exitResult: record.exitResult,
            managedProcess: managedProcess
        )

        do {
            try ProcessLauncher.signalProcessGroup(
                processGroupID,
                signal: SIGTERM
            )
        } catch let error as NSError
            where error.domain == NSPOSIXErrorDomain && error.code == ESRCH {
            let refreshed = try refreshCapturedProcess(&captured)
            if refreshed.liveness == .stopped {
                return .stopped
            }
            throw error
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while true {
            let refreshed = try refreshCapturedProcess(&captured)
            if refreshed.liveness == .stopped {
                return .stopped
            }

            let now = clock.now
            if now >= deadline {
                return .timedOut(refreshed)
            }

            let nextProbe = now.advanced(by: probeInterval)
            try await clock.sleep(
                until: min(nextProbe, deadline),
                tolerance: .zero
            )
        }
    }

    func restart(
        entry: CommandEntry,
        onOutput: @escaping OutputHandler,
        timeout: Duration = .seconds(5)
    ) async throws -> ProcessSnapshot {
        switch try await stop(entryID: entry.id, timeout: timeout) {
        case .stopped, .alreadyStopped:
            return try start(entry: entry, onOutput: onOutput)
        case .timedOut:
            throw ProcessSupervisorError.stopTimedOut
        }
    }

    func snapshots() throws -> [UUID: ProcessSnapshot] {
        var result: [UUID: ProcessSnapshot] = [:]
        for entryID in Array(records.keys) {
            result[entryID] = try refreshRecord(entryID: entryID)
        }
        return result
    }

    private func refreshRecord(entryID: UUID) throws -> ProcessSnapshot {
        guard var record = records[entryID] else {
            throw ProcessSupervisorError.unknownEntry
        }
        guard let pid = record.pid,
              let processGroupID = record.processGroupID else {
            return record.snapshot
        }

        record.exitResult = try waitForLeader(
            pid: pid,
            existingResult: record.exitResult
        )

        if try ProcessLauncher.processGroupExists(processGroupID) {
            record.liveness = .running
        } else {
            record.managedProcess?.close()
            record.managedProcess = nil
            record.pid = nil
            record.processGroupID = nil
            record.liveness = .stopped
        }

        records[entryID] = record
        return record.snapshot
    }

    private func refreshCapturedProcess(
        _ captured: inout CapturedProcess
    ) throws -> ProcessSnapshot {
        if captured.exitResult == nil,
           let record = records[captured.entryID],
           record.generation == captured.generation,
           record.pid == captured.pid,
           record.processGroupID == captured.processGroupID,
           record.managedProcess === captured.managedProcess {
            captured.exitResult = record.exitResult
        }

        captured.exitResult = try waitForLeader(
            pid: captured.pid,
            existingResult: captured.exitResult
        )

        if try ProcessLauncher.processGroupExists(captured.processGroupID) {
            updateCurrentRecord(from: captured, liveness: .running)
            return captured.snapshot(liveness: .running)
        }

        captured.managedProcess.close()
        updateCurrentRecord(from: captured, liveness: .stopped)
        return captured.snapshot(
            liveness: .stopped,
            includesIdentity: false
        )
    }

    private func updateCurrentRecord(
        from captured: CapturedProcess,
        liveness: ProcessLiveness
    ) {
        guard var record = records[captured.entryID],
              record.generation == captured.generation,
              record.pid == captured.pid,
              record.processGroupID == captured.processGroupID,
              record.managedProcess === captured.managedProcess else {
            return
        }

        if record.exitResult == nil {
            record.exitResult = captured.exitResult
        }
        record.liveness = liveness
        if liveness == .stopped {
            record.managedProcess = nil
            record.pid = nil
            record.processGroupID = nil
        }
        records[captured.entryID] = record
    }

    private func waitForLeader(
        pid: pid_t,
        existingResult: ChildWaitResult?
    ) throws -> ChildWaitResult? {
        guard existingResult == nil else {
            return existingResult
        }

        do {
            let result = try ProcessLauncher.wait(pid: pid, noHang: true)
            return result == .running ? nil : result
        } catch let error as NSError
            where error.domain == NSPOSIXErrorDomain && error.code == ECHILD {
            return nil
        }
    }
}

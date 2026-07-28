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

    private var records: [UUID: Record] = [:]

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
            cwd: entry.cwd
        )
        let managedProcess = ManagedProcess(
            masterFileDescriptor: launched.masterFileDescriptor,
            onOutput: onOutput
        )
        let record = Record(
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
        var snapshot = try refreshRecord(entryID: entryID)
        guard snapshot.liveness == .running,
              let processGroupID = snapshot.processGroupID else {
            return .alreadyStopped
        }

        do {
            try ProcessLauncher.signalProcessGroup(
                processGroupID,
                signal: SIGTERM
            )
        } catch let error as NSError
            where error.domain == NSPOSIXErrorDomain && error.code == ESRCH {
            snapshot = try refreshRecord(entryID: entryID)
            if snapshot.liveness == .stopped {
                return .stopped
            }
            throw error
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while true {
            snapshot = try refreshRecord(entryID: entryID)
            if snapshot.liveness == .stopped {
                return .stopped
            }

            let now = clock.now
            if now >= deadline {
                return .timedOut(snapshot)
            }

            let nextProbe = now.advanced(by: .milliseconds(50))
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

        if record.exitResult == nil {
            let waitResult = try ProcessLauncher.wait(pid: pid, noHang: true)
            if waitResult != .running {
                record.exitResult = waitResult
            }
        }

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
}

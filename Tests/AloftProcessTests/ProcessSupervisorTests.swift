import Darwin
import Foundation
import XCTest
@testable import AloftApp

final class ProcessSupervisorTests: XCTestCase {
    func testStartStreamsOutputAndRefreshUsesKernelGroupProbe() async throws {
        let supervisor = ProcessSupervisor()
        let recorder = DataRecorder()
        let entry = fixtureEntry(command: "echo START_READY; exec sleep 30")

        let started = try await supervisor.start(entry: entry) { data in
            Task { await recorder.append(data) }
        }
        let pid = try XCTUnwrap(started.pid)
        let pgid = try XCTUnwrap(started.processGroupID)
        defer { cleanupProcessGroup(pid: pid, pgid: pgid) }

        XCTAssertEqual(started.liveness, .running)
        XCTAssertTrue(try ProcessLauncher.processGroupExists(pgid))
        let receivedReady = await recorder.waitForText(
            "START_READY",
            timeout: .seconds(2)
        )
        XCTAssertTrue(receivedReady)

        let refreshed = try await supervisor.refresh(entryID: entry.id)
        XCTAssertEqual(refreshed.liveness, .running)
        XCTAssertEqual(refreshed.pid, pid)
        XCTAssertEqual(refreshed.processGroupID, pgid)
    }

    func testStopTerminatesLeaderAndReadyBackgroundMember() async throws {
        let supervisor = ProcessSupervisor()
        let recorder = DataRecorder()
        let entry = fixtureEntry(
            command: #"/bin/sh -c 'trap "" HUP; "#
                + #"printf "child_pid=%d GROUP_READY\n" "$$"; "#
                + #"exec sleep 30' & exec sleep 30"#
        )

        let started = try await supervisor.start(entry: entry) { data in
            Task { await recorder.append(data) }
        }
        let pid = try XCTUnwrap(started.pid)
        let pgid = try XCTUnwrap(started.processGroupID)
        defer { cleanupProcessGroup(pid: pid, pgid: pgid) }

        let receivedReady = await recorder.waitForText(
            "GROUP_READY",
            timeout: .seconds(2)
        )
        XCTAssertTrue(receivedReady)
        let recordedBackgroundPID = await recorder.pid(after: "child_pid=")
        let backgroundPID = try XCTUnwrap(recordedBackgroundPID)
        XCTAssertNotEqual(backgroundPID, pid)
        XCTAssertEqual(Darwin.getpgid(backgroundPID), pgid)
        XCTAssertTrue(processExists(backgroundPID))
        let leaderExecedSleep = try await waitForExecutableName(
            pid: pid,
            name: "sleep",
            timeout: .seconds(2)
        )
        XCTAssertTrue(
            leaderExecedSleep,
            "leader did not exec sleep"
        )
        let backgroundExecedSleep = try await waitForExecutableName(
            pid: backgroundPID,
            name: "sleep",
            timeout: .seconds(2)
        )
        XCTAssertTrue(
            backgroundExecedSleep,
            "background member did not exec sleep"
        )

        let result = try await supervisor.stop(
            entryID: entry.id,
            timeout: .seconds(2)
        )

        XCTAssertEqual(result, .stopped)
        XCTAssertFalse(try ProcessLauncher.processGroupExists(pgid))
        XCTAssertFalse(processExists(backgroundPID))
    }

    func testRefreshKeepsRunningAfterLeaderExitWhileDescendantLives() async throws {
        let supervisor = ProcessSupervisor()
        let recorder = DataRecorder()
        let entry = fixtureEntry(
            command: #"trap 'exit 7' USR1; "#
                + #"/bin/sh -c 'trap "" HUP; "#
                + #"printf "child_pid=%d DESCENDANT_READY\n" "$$"; "#
                + #"kill -USR1 "$PPID"; exec sleep 30' & wait"#
        )

        let started = try await supervisor.start(entry: entry) { data in
            Task { await recorder.append(data) }
        }
        let pid = try XCTUnwrap(started.pid)
        let pgid = try XCTUnwrap(started.processGroupID)
        defer { cleanupProcessGroup(pid: pid, pgid: pgid) }

        let receivedReady = await recorder.waitForText(
            "DESCENDANT_READY",
            timeout: .seconds(2)
        )
        XCTAssertTrue(receivedReady)
        let recordedBackgroundPID = await recorder.pid(after: "child_pid=")
        let backgroundPID = try XCTUnwrap(recordedBackgroundPID)
        XCTAssertTrue(processExists(backgroundPID))
        XCTAssertEqual(Darwin.getpgid(backgroundPID), pgid)

        let refreshed = try await waitForSnapshot(
            supervisor: supervisor,
            entryID: entry.id,
            timeout: .seconds(2)
        ) {
            $0.exitResult == .exited(code: 7)
        }

        XCTAssertEqual(refreshed.liveness, .running)
        XCTAssertEqual(refreshed.pid, pid)
        XCTAssertEqual(refreshed.processGroupID, pgid)
        XCTAssertEqual(refreshed.exitResult, .exited(code: 7))
    }

    func testStopTimeoutPreservesIdentityPTYAndSubsequentOutput() async throws {
        let supervisor = ProcessSupervisor()
        let recorder = DataRecorder()
        let entry = fixtureEntry(
            command: "trap '' TERM; echo TERM_TRAP_READY; "
                + "counter=0; while true; do "
                + "counter=$((counter + 1)); echo heartbeat_$counter; "
                + "sleep 0.05; done"
        )

        let started = try await supervisor.start(entry: entry) { data in
            Task { await recorder.append(data) }
        }
        let pid = try XCTUnwrap(started.pid)
        let pgid = try XCTUnwrap(started.processGroupID)
        defer { cleanupProcessGroup(pid: pid, pgid: pgid) }

        let receivedTrapReady = await recorder.waitForText(
            "TERM_TRAP_READY",
            timeout: .seconds(2)
        )
        XCTAssertTrue(receivedTrapReady)
        let receivedInitialHeartbeat = await recorder.waitForText(
            "heartbeat_1",
            timeout: .seconds(2)
        )
        XCTAssertTrue(receivedInitialHeartbeat)
        let byteCountBeforeStop = await recorder.byteCount

        let result = try await supervisor.stop(
            entryID: entry.id,
            timeout: .milliseconds(200)
        )
        guard case let .timedOut(snapshot) = result else {
            return XCTFail("Expected stop timeout, got \(result)")
        }

        XCTAssertEqual(snapshot.pid, pid)
        XCTAssertEqual(snapshot.processGroupID, pgid)
        XCTAssertEqual(snapshot.liveness, .running)
        XCTAssertTrue(try ProcessLauncher.processGroupExists(pgid))
        XCTAssertTrue(processExists(pid))
        let receivedOutputAfterTimeout = await recorder.waitForMoreData(
            than: byteCountBeforeStop,
            timeout: .seconds(2)
        )
        XCTAssertTrue(
            receivedOutputAfterTimeout,
            "PTY output stopped after timeout"
        )
    }

    func testRestartUsesNewPIDAndPGID() async throws {
        let supervisor = ProcessSupervisor()
        let firstRecorder = DataRecorder()
        let secondRecorder = DataRecorder()
        let entry = fixtureEntry(
            command: "echo RESTART_READY; exec sleep 30"
        )

        let first = try await supervisor.start(entry: entry) { data in
            Task { await firstRecorder.append(data) }
        }
        let firstPID = try XCTUnwrap(first.pid)
        let firstPGID = try XCTUnwrap(first.processGroupID)
        defer { cleanupProcessGroup(pid: firstPID, pgid: firstPGID) }
        let firstReceivedReady = await firstRecorder.waitForText(
            "RESTART_READY",
            timeout: .seconds(2)
        )
        XCTAssertTrue(firstReceivedReady)
        let firstExecedSleep = try await waitForExecutableName(
            pid: firstPID,
            name: "sleep",
            timeout: .seconds(2)
        )
        XCTAssertTrue(
            firstExecedSleep,
            "first leader did not exec sleep"
        )

        let second = try await supervisor.restart(
            entry: entry,
            onOutput: { data in
                Task { await secondRecorder.append(data) }
            },
            timeout: .seconds(2)
        )
        let secondPID = try XCTUnwrap(second.pid)
        let secondPGID = try XCTUnwrap(second.processGroupID)
        defer { cleanupProcessGroup(pid: secondPID, pgid: secondPGID) }

        XCTAssertNotEqual(secondPID, firstPID)
        XCTAssertNotEqual(secondPGID, firstPGID)
        XCTAssertFalse(try ProcessLauncher.processGroupExists(firstPGID))
        XCTAssertTrue(try ProcessLauncher.processGroupExists(secondPGID))
        let secondReceivedReady = await secondRecorder.waitForText(
            "RESTART_READY",
            timeout: .seconds(2)
        )
        XCTAssertTrue(secondReceivedReady)
    }

    func testRestartDoesNotLaunchAfterStopTimeout() async throws {
        let supervisor = ProcessSupervisor()
        let recorder = DataRecorder()
        let entry = fixtureEntry(
            command: "trap '' TERM; echo RESTART_TRAP_READY; "
                + "while true; do echo restart_heartbeat; sleep 0.05; done"
        )

        let first = try await supervisor.start(entry: entry) { data in
            Task { await recorder.append(data) }
        }
        let pid = try XCTUnwrap(first.pid)
        let pgid = try XCTUnwrap(first.processGroupID)
        defer { cleanupProcessGroup(pid: pid, pgid: pgid) }
        let receivedTrapReady = await recorder.waitForText(
            "RESTART_TRAP_READY",
            timeout: .seconds(2)
        )
        XCTAssertTrue(receivedTrapReady)

        do {
            _ = try await supervisor.restart(
                entry: entry,
                onOutput: { _ in },
                timeout: .milliseconds(200)
            )
            XCTFail("Restart must fail after a stop timeout")
        } catch let error as ProcessSupervisorError {
            XCTAssertEqual(error, .stopTimedOut)
        }

        let refreshed = try await supervisor.refresh(entryID: entry.id)
        XCTAssertEqual(refreshed.pid, pid)
        XCTAssertEqual(refreshed.processGroupID, pgid)
        XCTAssertEqual(refreshed.liveness, .running)
        XCTAssertTrue(try ProcessLauncher.processGroupExists(pgid))
    }

    func testRejectsAlreadyRunningAndReportsUnknownAndAlreadyStopped() async throws {
        let supervisor = ProcessSupervisor()
        let runningEntry = fixtureEntry(command: "exec sleep 30")
        let running = try await supervisor.start(entry: runningEntry) { _ in }
        let pid = try XCTUnwrap(running.pid)
        let pgid = try XCTUnwrap(running.processGroupID)
        defer { cleanupProcessGroup(pid: pid, pgid: pgid) }

        do {
            _ = try await supervisor.start(entry: runningEntry) { _ in }
            XCTFail("Second start must reject a live process group")
        } catch let error as ProcessSupervisorError {
            XCTAssertEqual(error, .alreadyRunning)
        }

        let unknownID = UUID()
        do {
            _ = try await supervisor.refresh(entryID: unknownID)
            XCTFail("Refresh must reject an unknown entry")
        } catch let error as ProcessSupervisorError {
            XCTAssertEqual(error, .unknownEntry)
        }
        do {
            _ = try await supervisor.stop(entryID: unknownID)
            XCTFail("Stop must reject an unknown entry")
        } catch let error as ProcessSupervisorError {
            XCTAssertEqual(error, .unknownEntry)
        }

        let stoppedEntry = fixtureEntry(command: "exit 0")
        _ = try await supervisor.start(entry: stoppedEntry) { _ in }
        let stopped = try await waitForSnapshot(
            supervisor: supervisor,
            entryID: stoppedEntry.id,
            timeout: .seconds(2)
        ) {
            $0.liveness == .stopped
        }
        XCTAssertEqual(stopped.exitResult, .exited(code: 0))
        XCTAssertNil(stopped.pid)
        XCTAssertNil(stopped.processGroupID)

        let stopResult = try await supervisor.stop(entryID: stoppedEntry.id)
        XCTAssertEqual(stopResult, .alreadyStopped)
        let allSnapshots = try await supervisor.snapshots()
        XCTAssertEqual(allSnapshots[stoppedEntry.id], stopped)
    }
}

private actor DataRecorder {
    private var data = Data()

    func append(_ chunk: Data) {
        data.append(chunk)
    }

    func waitForText(_ marker: String, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            if text.contains(marker) {
                return true
            }
            try? await clock.sleep(for: .milliseconds(10))
        }
        return text.contains(marker)
    }

    func pid(after prefix: String) -> pid_t? {
        text
            .split(whereSeparator: \.isWhitespace)
            .first { $0.hasPrefix(prefix) }
            .flatMap { pid_t($0.dropFirst(prefix.count)) }
    }

    var byteCount: Int {
        data.count
    }

    func waitForMoreData(than byteCount: Int, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            if data.count > byteCount {
                return true
            }
            try? await clock.sleep(for: .milliseconds(10))
        }
        return data.count > byteCount
    }

    private var text: String {
        String(decoding: data, as: UTF8.self)
    }
}

private func fixtureEntry(command: String) -> CommandEntry {
    CommandEntry(
        id: UUID(),
        name: "Fixture",
        cwd: "/tmp",
        command: command,
        keywords: ["fixture"],
        order: 0
    )
}

private func waitForSnapshot(
    supervisor: ProcessSupervisor,
    entryID: UUID,
    timeout: Duration,
    predicate: (ProcessSnapshot) -> Bool
) async throws -> ProcessSnapshot {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    var snapshot = try await supervisor.refresh(entryID: entryID)

    while clock.now < deadline {
        if predicate(snapshot) {
            return snapshot
        }
        try await clock.sleep(for: .milliseconds(10))
        snapshot = try await supervisor.refresh(entryID: entryID)
    }
    return snapshot
}

private func processExists(_ pid: pid_t) -> Bool {
    if Darwin.kill(pid, 0) == 0 {
        return true
    }
    return errno != ESRCH
}

private func waitForExecutableName(
    pid: pid_t,
    name: String,
    timeout: Duration
) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while clock.now < deadline {
        if try executableName(pid: pid) == name {
            return true
        }
        try await clock.sleep(for: .milliseconds(10))
    }
    return try executableName(pid: pid) == name
}

private func executableName(pid: pid_t) throws -> String? {
    var path = [CChar](repeating: 0, count: 4_096)
    let length = proc_pidpath(pid, &path, UInt32(path.count))
    if length > 0 {
        return path.withUnsafeBufferPointer {
            URL(fileURLWithPath: String(cString: $0.baseAddress!))
                .lastPathComponent
        }
    }
    if errno == ESRCH {
        return nil
    }
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
}

private func cleanupProcessGroup(pid: pid_t, pgid: pid_t) {
    let killResult = Darwin.killpg(pgid, SIGKILL)
    let killError = killResult == -1 ? errno : 0
    XCTAssertTrue(
        killResult == 0 || (killResult == -1 && killError == ESRCH),
        "cleanup killpg(\(pgid), SIGKILL) failed with errno \(killError)"
    )

    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    var leaderHandled = false
    while ContinuousClock.now < deadline {
        var status: Int32 = 0
        let result = Darwin.waitpid(pid, &status, WNOHANG)
        if result == pid || (result == -1 && errno == ECHILD) {
            leaderHandled = true
            break
        }
        if result == -1 && errno != EINTR {
            XCTFail("cleanup waitpid(\(pid)) failed with errno \(errno)")
            break
        }
        usleep(10_000)
    }
    XCTAssertTrue(leaderHandled, "cleanup did not reap leader \(pid)")

    var groupGone = false
    while ContinuousClock.now < deadline {
        if Darwin.killpg(pgid, 0) == -1 && errno == ESRCH {
            groupGone = true
            break
        }
        usleep(10_000)
    }
    XCTAssertTrue(groupGone, "cleanup left process group \(pgid)")
}

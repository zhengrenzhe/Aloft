import Darwin
import Foundation
import XCTest
@testable import AloftApp

final class ProcessSupervisorTests: XCTestCase {
    func testCurrentGenerationCanWriteAndResizeButOldGenerationCannot()
        async throws {
        let supervisor = ProcessSupervisor()
        let entry = fixtureEntry(
            command: """
            printf 'GENERATION_READY\n'
            IFS= read -r line
            printf 'input=%s\n' "$line"
            exec sleep 30
            """
        )
        let generation = UUID()
        let recorder = DataRecorder()
        let started = try await supervisor.start(
            entry: entry,
            generation: generation
        ) { data in
            Task { await recorder.append(data) }
        }
        let pid = try XCTUnwrap(started.pid)
        let processGroupID = try XCTUnwrap(
            started.processGroupID
        )
        defer {
            cleanupProcessGroup(
                pid: pid,
                pgid: processGroupID
            )
        }
        let receivedReady = await recorder.waitForText(
            "GENERATION_READY",
            timeout: .seconds(2)
        )
        XCTAssertTrue(receivedReady)

        try await supervisor.resize(
            entryID: entry.id,
            generation: generation,
            size: TerminalSize(
                columns: 120,
                rows: 40,
                pixelWidth: 1_200,
                pixelHeight: 800
            )!
        )
        try await supervisor.write(
            entryID: entry.id,
            generation: generation,
            data: Data("hello\n".utf8)
        )

        let receivedInput = await recorder.waitForText(
            "input=hello",
            timeout: .seconds(2)
        )
        XCTAssertTrue(receivedInput)

        for operation in [
            {
                try await supervisor.write(
                    entryID: entry.id,
                    generation: UUID(),
                    data: Data("stale\n".utf8)
                )
            },
            {
                try await supervisor.resize(
                    entryID: entry.id,
                    generation: UUID(),
                    size: TerminalSize(
                        columns: 90,
                        rows: 30,
                        pixelWidth: 900,
                        pixelHeight: 600
                    )!
                )
            },
        ] {
            do {
                try await operation()
                XCTFail("A stale generation operation must fail")
            } catch {
                XCTAssertEqual(
                    error as? ProcessSupervisorError,
                    .staleGeneration
                )
            }
        }
    }

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
        let byteCountAfterTimeout = await recorder.byteCount
        let receivedOutputAfterTimeout = await recorder.waitForMoreData(
            than: byteCountAfterTimeout,
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

    func testForceStopKillsSIGTERMResistantProcessGroup() async throws {
        let supervisor = ProcessSupervisor()
        let recorder = DataRecorder()
        let generation = UUID()
        let entry = fixtureEntry(
            command: "trap '' TERM; echo FORCE_STOP_READY; "
                + "while true; do sleep 1; done"
        )

        let running = try await supervisor.start(
            entry: entry,
            generation: generation
        ) { data in
            Task { await recorder.append(data) }
        }
        let pid = try XCTUnwrap(running.pid)
        let pgid = try XCTUnwrap(running.processGroupID)
        defer { cleanupProcessGroup(pid: pid, pgid: pgid) }
        let receivedReady = await recorder.waitForText(
            "FORCE_STOP_READY",
            timeout: .seconds(2)
        )
        XCTAssertTrue(receivedReady)

        let graceful = try await supervisor.stop(
            entryID: entry.id,
            timeout: .milliseconds(200)
        )
        guard case .timedOut = graceful else {
            return XCTFail("SIGTERM-resistant group must time out")
        }

        let forced = try await supervisor.forceStop(
            entryID: entry.id,
            generation: generation,
            pid: pid,
            processGroupID: pgid,
            timeout: .seconds(2)
        )

        XCTAssertEqual(forced, .stopped)
        XCTAssertFalse(try ProcessLauncher.processGroupExists(pgid))
        let refreshed = try await supervisor.refresh(entryID: entry.id)
        XCTAssertEqual(refreshed.liveness, .stopped)
        XCTAssertNil(refreshed.pid)
        XCTAssertNil(refreshed.processGroupID)
        XCTAssertEqual(refreshed.exitResult, .signaled(signal: SIGKILL))
    }

    func testForceStopTreatsSameGenerationThatAlreadyExitedAsStopped()
        async throws {
        let supervisor = ProcessSupervisor()
        let generation = UUID()
        let entry = fixtureEntry(command: "exit 0")
        let running = try await supervisor.start(
            entry: entry,
            generation: generation
        ) { _ in }
        let pid = try XCTUnwrap(running.pid)
        let pgid = try XCTUnwrap(running.processGroupID)
        let stopped = try await waitForSnapshot(
            supervisor: supervisor,
            entryID: entry.id,
            timeout: .seconds(2)
        ) { $0.liveness == .stopped }
        XCTAssertEqual(stopped.liveness, .stopped)

        let result = try await supervisor.forceStop(
            entryID: entry.id,
            generation: generation,
            pid: pid,
            processGroupID: pgid
        )

        XCTAssertEqual(result, .alreadyStopped)
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

    func testStopUsesCapturedGenerationWhenReplacementStartsDuringAwait() async throws {
        let supervisor = ProcessSupervisor(
            probeInterval: .seconds(1)
        )
        let oldRecorder = DataRecorder()
        let newRecorder = DataRecorder()
        let entryID = UUID()
        let oldEntry = fixtureEntry(
            id: entryID,
            command: "trap '' TERM; "
                + "/bin/sh -c 'trap - TERM; exec sleep 30' & child=$!; "
                + "echo stop_child_pid=$child; echo OLD_STOP_READY; "
                + "wait $child; echo OLD_STOP_TERM_OBSERVED; "
                + "while true; do :; done"
        )

        let old = try await supervisor.start(entry: oldEntry) { data in
            Task { await oldRecorder.append(data) }
        }
        let oldPID = try XCTUnwrap(old.pid)
        let oldPGID = try XCTUnwrap(old.processGroupID)
        defer { cleanupProcessGroup(pid: oldPID, pgid: oldPGID) }
        let oldReady = await oldRecorder.waitForText(
            "OLD_STOP_READY",
            timeout: .seconds(2)
        )
        XCTAssertTrue(oldReady)
        let childReady = await oldRecorder.waitForText(
            "stop_child_pid=",
            timeout: .seconds(2)
        )
        XCTAssertTrue(childReady)
        let recordedChildPID = await oldRecorder.pid(after: "stop_child_pid=")
        let termSensitiveChildPID = try XCTUnwrap(recordedChildPID)
        XCTAssertTrue(processExists(termSensitiveChildPID))

        let stopTask = Task {
            try await supervisor.stop(
                entryID: entryID,
                timeout: .seconds(2)
            )
        }
        defer { stopTask.cancel() }
        let oldObservedTerm = await oldRecorder.waitForText(
            "OLD_STOP_TERM_OBSERVED",
            timeout: .seconds(2)
        )
        XCTAssertTrue(oldObservedTerm)
        XCTAssertFalse(processExists(termSensitiveChildPID))

        XCTAssertEqual(Darwin.killpg(oldPGID, SIGKILL), 0)
        let oldStopped = try await waitForSnapshot(
            supervisor: supervisor,
            entryID: entryID,
            timeout: .milliseconds(500)
        ) {
            $0.liveness == .stopped
        }
        XCTAssertEqual(oldStopped.liveness, .stopped)
        let newEntry = fixtureEntry(
            id: entryID,
            command: "echo NEW_STOP_READY; exec sleep 30"
        )
        let replacement = try await supervisor.start(entry: newEntry) { data in
            Task { await newRecorder.append(data) }
        }
        let replacementPID = try XCTUnwrap(replacement.pid)
        let replacementPGID = try XCTUnwrap(replacement.processGroupID)
        defer {
            cleanupProcessGroup(
                pid: replacementPID,
                pgid: replacementPGID
            )
        }
        let replacementReady = await newRecorder.waitForText(
            "NEW_STOP_READY",
            timeout: .seconds(2)
        )
        XCTAssertTrue(replacementReady)

        let stopResult = try await stopTask.value
        XCTAssertEqual(stopResult, .stopped)
        XCTAssertTrue(try ProcessLauncher.processGroupExists(replacementPGID))
        let current = try await supervisor.refresh(entryID: entryID)
        XCTAssertEqual(current.pid, replacementPID)
        XCTAssertEqual(current.processGroupID, replacementPGID)
        XCTAssertEqual(current.liveness, .running)
    }

    func testStopPreservesExitResultStoredByConcurrentRefresh() async throws {
        let supervisor = ProcessSupervisor(
            probeInterval: .seconds(5)
        )
        let recorder = DataRecorder()
        let entry = fixtureEntry(
            command: "trap 'echo MONOTONIC_STOP_SUSPENDED' TERM; "
                + "trap 'exit 7' USR1; "
                + "/bin/sh -c 'trap \"\" HUP TERM USR1; "
                + "echo MONOTONIC_DESCENDANT_READY; exec sleep 30' & "
                + "child=$!; while true; do wait $child; done"
        )

        let started = try await supervisor.start(entry: entry) { data in
            Task { await recorder.append(data) }
        }
        let pid = try XCTUnwrap(started.pid)
        let pgid = try XCTUnwrap(started.processGroupID)
        defer { cleanupProcessGroup(pid: pid, pgid: pgid) }
        let descendantReady = await recorder.waitForText(
            "MONOTONIC_DESCENDANT_READY",
            timeout: .seconds(2)
        )
        XCTAssertTrue(descendantReady)

        let stopTask = Task {
            try await supervisor.stop(
                entryID: entry.id,
                timeout: .seconds(2)
            )
        }
        defer { stopTask.cancel() }
        let stopSuspended = await recorder.waitForText(
            "MONOTONIC_STOP_SUSPENDED",
            timeout: .seconds(2)
        )
        XCTAssertTrue(stopSuspended)

        XCTAssertEqual(Darwin.kill(pid, SIGUSR1), 0)
        let concurrentlyRefreshed = try await waitForSnapshot(
            supervisor: supervisor,
            entryID: entry.id,
            timeout: .seconds(2)
        ) {
            $0.exitResult == .exited(code: 7)
        }
        XCTAssertEqual(
            concurrentlyRefreshed.exitResult,
            .exited(code: 7)
        )
        XCTAssertEqual(concurrentlyRefreshed.liveness, .running)

        let result = try await stopTask.value
        guard case let .timedOut(snapshot) = result else {
            return XCTFail("Expected stop timeout, got \(result)")
        }
        XCTAssertEqual(snapshot.exitResult, .exited(code: 7))

        let subsequent = try await supervisor.refresh(entryID: entry.id)
        XCTAssertEqual(subsequent.exitResult, .exited(code: 7))
        XCTAssertEqual(subsequent.liveness, .running)
    }

    func testRestartDoesNotConsumeReplacementGenerationDuringAwait() async throws {
        let supervisor = ProcessSupervisor(
            probeInterval: .seconds(1)
        )
        let oldRecorder = DataRecorder()
        let newRecorder = DataRecorder()
        let entryID = UUID()
        let oldEntry = fixtureEntry(
            id: entryID,
            command: "trap '' TERM; "
                + "/bin/sh -c 'trap - TERM; exec sleep 30' & child=$!; "
                + "echo restart_child_pid=$child; echo OLD_RESTART_READY; "
                + "wait $child; echo OLD_RESTART_TERM_OBSERVED; "
                + "while true; do :; done"
        )

        let old = try await supervisor.start(entry: oldEntry) { data in
            Task { await oldRecorder.append(data) }
        }
        let oldPID = try XCTUnwrap(old.pid)
        let oldPGID = try XCTUnwrap(old.processGroupID)
        defer { cleanupProcessGroup(pid: oldPID, pgid: oldPGID) }
        let oldReady = await oldRecorder.waitForText(
            "OLD_RESTART_READY",
            timeout: .seconds(2)
        )
        XCTAssertTrue(oldReady)
        let childReady = await oldRecorder.waitForText(
            "restart_child_pid=",
            timeout: .seconds(2)
        )
        XCTAssertTrue(childReady)
        let recordedChildPID = await oldRecorder.pid(
            after: "restart_child_pid="
        )
        let termSensitiveChildPID = try XCTUnwrap(recordedChildPID)
        XCTAssertTrue(processExists(termSensitiveChildPID))

        let restartTask = Task {
            try await supervisor.restart(
                entry: fixtureEntry(
                    id: entryID,
                    command: "echo RESTART_TASK_LAUNCHED; exec sleep 30"
                ),
                onOutput: { _ in },
                timeout: .seconds(2)
            )
        }
        defer { restartTask.cancel() }
        let oldObservedTerm = await oldRecorder.waitForText(
            "OLD_RESTART_TERM_OBSERVED",
            timeout: .seconds(2)
        )
        XCTAssertTrue(oldObservedTerm)
        XCTAssertFalse(processExists(termSensitiveChildPID))

        XCTAssertEqual(Darwin.killpg(oldPGID, SIGKILL), 0)
        let oldStopped = try await waitForSnapshot(
            supervisor: supervisor,
            entryID: entryID,
            timeout: .milliseconds(500)
        ) {
            $0.liveness == .stopped
        }
        XCTAssertEqual(oldStopped.liveness, .stopped)
        let replacement = try await supervisor.start(
            entry: fixtureEntry(
                id: entryID,
                command: "echo NEW_RESTART_READY; exec sleep 30"
            )
        ) { data in
            Task { await newRecorder.append(data) }
        }
        let replacementPID = try XCTUnwrap(replacement.pid)
        let replacementPGID = try XCTUnwrap(replacement.processGroupID)
        defer {
            cleanupProcessGroup(
                pid: replacementPID,
                pgid: replacementPGID
            )
        }
        let replacementReady = await newRecorder.waitForText(
            "NEW_RESTART_READY",
            timeout: .seconds(2)
        )
        XCTAssertTrue(replacementReady)

        do {
            _ = try await restartTask.value
            XCTFail("Restart must not replace a concurrent generation")
        } catch let error as ProcessSupervisorError {
            XCTAssertEqual(error, .alreadyRunning)
        }
        XCTAssertTrue(try ProcessLauncher.processGroupExists(replacementPGID))
        let current = try await supervisor.refresh(entryID: entryID)
        XCTAssertEqual(current.pid, replacementPID)
        XCTAssertEqual(current.processGroupID, replacementPGID)
    }

    func testRefreshAndStopProbeGroupAfterLeaderWasExternallyReaped() async throws {
        let supervisor = ProcessSupervisor()
        let recorder = DataRecorder()
        let entry = fixtureEntry(
            command: #"trap 'exit 7' USR1; "#
                + #"/bin/sh -c 'trap "" HUP; "#
                + #"printf "child_pid=%d EXTERNAL_REAP_READY\n" "$$"; "#
                + #"kill -USR1 "$PPID"; exec sleep 30' & wait"#
        )

        let started = try await supervisor.start(entry: entry) { data in
            Task { await recorder.append(data) }
        }
        let pid = try XCTUnwrap(started.pid)
        let pgid = try XCTUnwrap(started.processGroupID)
        defer { cleanupProcessGroup(pid: pid, pgid: pgid) }
        let descendantReady = await recorder.waitForText(
            "EXTERNAL_REAP_READY",
            timeout: .seconds(2)
        )
        XCTAssertTrue(descendantReady)
        let recordedBackgroundPID = await recorder.pid(after: "child_pid=")
        let backgroundPID = try XCTUnwrap(recordedBackgroundPID)
        XCTAssertTrue(
            externallyReapLeader(pid: pid, timeout: .seconds(2))
        )
        XCTAssertTrue(processExists(backgroundPID))
        XCTAssertEqual(Darwin.getpgid(backgroundPID), pgid)

        let refreshed = try await supervisor.refresh(entryID: entry.id)
        XCTAssertEqual(refreshed.liveness, .running)
        XCTAssertEqual(refreshed.pid, pid)
        XCTAssertEqual(refreshed.processGroupID, pgid)
        XCTAssertNil(refreshed.exitResult)

        let stopResult = try await supervisor.stop(
            entryID: entry.id,
            timeout: .seconds(2)
        )
        XCTAssertEqual(stopResult, .stopped)
        XCTAssertFalse(try ProcessLauncher.processGroupExists(pgid))
        XCTAssertFalse(processExists(backgroundPID))
    }

    func testStopWithZeroTimeoutReturnsLiveCapturedSnapshot() async throws {
        try await assertImmediateStopTimeout(.zero, marker: "ZERO_TIMEOUT_READY")
    }

    func testStopWithNegativeTimeoutReturnsLiveCapturedSnapshot() async throws {
        try await assertImmediateStopTimeout(
            .milliseconds(-1),
            marker: "NEGATIVE_TIMEOUT_READY"
        )
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

private func fixtureEntry(
    id: UUID = UUID(),
    command: String
) -> CommandEntry {
    CommandEntry(
        id: id,
        name: "Fixture",
        cwd: "/tmp",
        command: command,
        keywords: ["fixture"],
        order: 0
    )
}

private func assertImmediateStopTimeout(
    _ timeout: Duration,
    marker: String
) async throws {
    let supervisor = ProcessSupervisor()
    let recorder = DataRecorder()
    let entry = fixtureEntry(
        command: "trap '' TERM; echo \(marker); "
            + "exec sleep 30"
    )
    let started = try await supervisor.start(entry: entry) { data in
        Task { await recorder.append(data) }
    }
    let pid = try XCTUnwrap(started.pid)
    let pgid = try XCTUnwrap(started.processGroupID)
    defer { cleanupProcessGroup(pid: pid, pgid: pgid) }
    let receivedReady = await recorder.waitForText(
        marker,
        timeout: .seconds(2)
    )
    XCTAssertTrue(receivedReady)

    let result = try await supervisor.stop(
        entryID: entry.id,
        timeout: timeout
    )
    guard case let .timedOut(snapshot) = result else {
        return XCTFail("Expected immediate timeout, got \(result)")
    }
    XCTAssertEqual(snapshot.pid, pid)
    XCTAssertEqual(snapshot.processGroupID, pgid)
    XCTAssertEqual(snapshot.liveness, .running)
    XCTAssertTrue(try ProcessLauncher.processGroupExists(pgid))
}

private func externallyReapLeader(pid: pid_t, timeout: Duration) -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while clock.now < deadline {
        var status: Int32 = 0
        let result = Darwin.waitpid(pid, &status, WNOHANG)
        if result == pid {
            return true
        }
        if result == -1 && errno != EINTR {
            return false
        }
        usleep(10_000)
    }
    return false
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

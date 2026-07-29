import Darwin
import Foundation
import XCTest
@testable import AloftApp

@MainActor
final class RuntimeStoreConcurrencyTests: XCTestCase {
    func testStartsPassDistinctGenerationsToProcessClient() async {
        let fake = ControlledProcessSupervisor()
        let entry = concurrencyEntry(name: "Generations")
        await fake.enqueueStartSnapshot(
            runningSnapshot(
                entryID: entry.id,
                pid: 91,
                processGroupID: 91
            )
        )
        await fake.enqueueStartSnapshot(
            runningSnapshot(
                entryID: entry.id,
                pid: 92,
                processGroupID: 92
            )
        )
        let runtime = await makeRuntimeStore(fake)

        let firstStart = await runtime.start(entry)
        XCTAssertTrue(firstStart.isSuccess)
        let stop = await runtime.stop(
            entry,
            timeout: .seconds(1)
        )
        XCTAssertTrue(stop.isSuccess)
        let secondStart = await runtime.start(entry)
        XCTAssertTrue(secondStart.isSuccess)

        let generations = await fake.startedGenerations
        XCTAssertEqual(generations.count, 2)
        XCTAssertNotEqual(generations[0], generations[1])
    }

    func testThreeOverlappingStartsSerializeAndPreserveDelayedSuccessfulOutput() async throws {
        let fake = ControlledProcessSupervisor()
        let firstGate = AsyncTestGate()
        let secondGate = AsyncTestGate()
        let entry = concurrencyEntry(name: "Serialized")
        await fake.setStartGate(firstGate, call: 1)
        await fake.setStartGate(secondGate, call: 2)
        await fake.enqueueStartSnapshot(
            runningSnapshot(
                entryID: entry.id,
                pid: 101,
                processGroupID: 101
            )
        )
        let runtime = await makeRuntimeStore(fake)

        let firstTask = Task { await runtime.start(entry) }
        let firstEntered = await waitUntilAsync {
            await fake.startCallCount == 1
        }
        XCTAssertTrue(firstEntered)
        let secondTask = Task { await runtime.start(entry) }
        let thirdTask = Task { await runtime.start(entry) }
        let allStartsAdmitted = await waitUntilMainActor {
            runtime.inFlightLaunchCount == 3
        }
        XCTAssertTrue(allStartsAdmitted)
        let startCountWhileFirstBlocked = await fake.startCallCount
        XCTAssertEqual(startCountWhileFirstBlocked, 1)

        await firstGate.open()
        let secondEntered = await waitUntilAsync {
            await fake.startCallCount == 2
        }
        XCTAssertTrue(secondEntered)
        await fake.emit(
            Data("DELAYED_SUCCESS\n".utf8),
            entryID: entry.id
        )
        let receivedDelayedOutput = await waitUntilMainActor {
            runtime.runtime(for: entry.id)
                .output.displayText.contains("DELAYED_SUCCESS")
        }
        XCTAssertTrue(receivedDelayedOutput)
        await secondGate.open()

        let first = await firstTask.value
        let second = await secondTask.value
        let third = await thirdTask.value

        XCTAssertTrue(first.isSuccess)
        XCTAssertFalse(second.isSuccess)
        XCTAssertFalse(third.isSuccess)
        let finalStartCallCount = await fake.startCallCount
        XCTAssertEqual(finalStartCallCount, 3)
        XCTAssertTrue(
            runtime.runtime(for: entry.id)
                .output.displayText.contains("DELAYED_SUCCESS")
        )
        XCTAssertEqual(
            runtime.runtime(for: entry.id).process.processGroupID,
            101
        )
    }

    func testDifferentEntryStartRunsWhileFirstEntryLaneIsBlocked() async throws {
        let fake = ControlledProcessSupervisor()
        let firstGate = AsyncTestGate()
        let first = concurrencyEntry(name: "First")
        let second = concurrencyEntry(name: "Second")
        await fake.setStartGate(firstGate, call: 1)
        await fake.enqueueStartSnapshot(
            runningSnapshot(
                entryID: first.id,
                pid: 151,
                processGroupID: 151
            )
        )
        await fake.enqueueStartSnapshot(
            runningSnapshot(
                entryID: second.id,
                pid: 152,
                processGroupID: 152
            )
        )
        let runtime = await makeRuntimeStore(fake)

        let firstTask = Task { await runtime.start(first) }
        let firstEntered = await waitUntilAsync {
            await fake.startCallCount == 1
        }
        XCTAssertTrue(firstEntered)
        let secondTask = Task { await runtime.start(second) }
        let secondEntered = await waitUntilAsync {
            await fake.startCallCount == 2
        }
        XCTAssertTrue(secondEntered)
        let secondResult = await secondTask.value
        XCTAssertTrue(secondResult.isSuccess)

        await firstGate.open()
        let firstResult = await firstTask.value
        XCTAssertTrue(firstResult.isSuccess)
    }

    func testStaleRefreshCannotOverwriteReplacementWithSameSyntheticPGID() async throws {
        let fake = ControlledProcessSupervisor()
        let staleRefreshGate = AsyncTestGate()
        let entry = concurrencyEntry(name: "Refresh")
        await fake.enqueueStartSnapshot(
            runningSnapshot(
                entryID: entry.id,
                pid: 201,
                processGroupID: 777
            )
        )
        await fake.enqueueStartSnapshot(
            runningSnapshot(
                entryID: entry.id,
                pid: 202,
                processGroupID: 777
            )
        )
        let runtime = await makeRuntimeStore(fake)
        let initialStart = await runtime.start(entry)
        XCTAssertTrue(initialStart.isSuccess)
        await fake.setRefreshOverride(
            stoppedSnapshot(entryID: entry.id),
            gate: staleRefreshGate,
            call: 1
        )

        let staleRefresh = Task {
            await runtime.refreshAll()
        }
        let staleRefreshEntered = await waitUntilAsync {
            await fake.refreshCallCount == 1
        }
        XCTAssertTrue(staleRefreshEntered)

        let stopResult = await runtime.stop(
            entry,
            timeout: .seconds(1)
        )
        XCTAssertTrue(stopResult.isSuccess)
        let replacementStart = await runtime.start(entry)
        XCTAssertTrue(replacementStart.isSuccess)
        XCTAssertEqual(
            runtime.runtime(for: entry.id).process.pid,
            202
        )
        await staleRefreshGate.open()
        await staleRefresh.value

        let current = runtime.runtime(for: entry.id)
        XCTAssertEqual(current.process.pid, 202)
        XCTAssertEqual(current.process.processGroupID, 777)
        XCTAssertEqual(current.process.liveness, .running)
        XCTAssertNil(current.lastError)
    }

    func testOldRunningProbeCannotReviveEntryAfterSuccessfulStop() async throws {
        let fake = ControlledProcessSupervisor()
        let oldProbeGate = AsyncTestGate()
        let entry = concurrencyEntry(name: "Stop Wins")
        let running = runningSnapshot(
            entryID: entry.id,
            pid: 251,
            processGroupID: 251
        )
        await fake.enqueueStartSnapshot(running)
        await fake.setRefreshOverride(
            running,
            gate: oldProbeGate,
            call: 1
        )
        let runtime = await makeRuntimeStore(fake)
        let start = await runtime.start(entry)
        XCTAssertTrue(start.isSuccess)

        let oldProbe = Task {
            await runtime.refreshAll()
        }
        let oldProbeEntered = await waitUntilAsync {
            await fake.refreshCallCount == 1
        }
        XCTAssertTrue(oldProbeEntered)

        let stop = await runtime.stop(entry, timeout: .seconds(1))
        XCTAssertTrue(stop.isSuccess)
        XCTAssertEqual(
            runtime.runtime(for: entry.id).process,
            stoppedSnapshot(entryID: entry.id)
        )

        await oldProbeGate.open()
        await oldProbe.value

        let current = runtime.runtime(for: entry.id)
        XCTAssertEqual(
            current.process,
            stoppedSnapshot(entryID: entry.id)
        )
        XCTAssertNil(current.lastError)
    }

    func testOldProbeCannotEraseNewerStopTimeoutProjection() async throws {
        let fake = ControlledProcessSupervisor()
        let oldProbeGate = AsyncTestGate()
        let entry = concurrencyEntry(name: "Timeout Wins")
        let running = runningSnapshot(
            entryID: entry.id,
            pid: 261,
            processGroupID: 261
        )
        let timedOut = ProcessSnapshot(
            entryID: entry.id,
            pid: nil,
            processGroupID: 261,
            liveness: .running,
            launchedAt: running.launchedAt,
            exitResult: .exited(code: 143)
        )
        await fake.enqueueStartSnapshot(running)
        await fake.setRefreshOverride(
            running,
            gate: oldProbeGate,
            call: 1
        )
        await fake.setStopBehavior(
            .timedOut(timedOut),
            gate: nil,
            call: 1
        )
        let runtime = await makeRuntimeStore(fake)
        let start = await runtime.start(entry)
        XCTAssertTrue(start.isSuccess)

        let oldProbe = Task {
            await runtime.refreshAll()
        }
        let oldProbeEntered = await waitUntilAsync {
            await fake.refreshCallCount == 1
        }
        XCTAssertTrue(oldProbeEntered)

        let stop = await runtime.stop(
            entry,
            timeout: .milliseconds(50)
        )
        XCTAssertFalse(stop.isSuccess)
        XCTAssertEqual(
            runtime.runtime(for: entry.id).process,
            timedOut
        )
        XCTAssertEqual(
            runtime.runtime(for: entry.id).lastError,
            L10n.format(
                "Did not stop process group %@.",
                "261"
            )
        )

        await oldProbeGate.open()
        await oldProbe.value

        let current = runtime.runtime(for: entry.id)
        XCTAssertEqual(current.process, timedOut)
        XCTAssertEqual(
            current.lastError,
            L10n.format(
                "Did not stop process group %@.",
                "261"
            )
        )
    }

    func testActionErrorInvalidatesOlderProbe() async throws {
        let fake = ControlledProcessSupervisor()
        let oldProbeGate = AsyncTestGate()
        let entry = concurrencyEntry(name: "Error Wins")
        let running = runningSnapshot(
            entryID: entry.id,
            pid: 266,
            processGroupID: 266
        )
        await fake.enqueueStartSnapshot(running)
        await fake.setRefreshOverride(
            stoppedSnapshot(entryID: entry.id),
            gate: oldProbeGate,
            call: 1
        )
        let runtime = await makeRuntimeStore(fake)
        let start = await runtime.start(entry)
        XCTAssertTrue(start.isSuccess)

        let oldProbe = Task {
            await runtime.refreshAll()
        }
        let oldProbeEntered = await waitUntilAsync {
            await fake.refreshCallCount == 1
        }
        XCTAssertTrue(oldProbeEntered)

        let duplicateStart = await runtime.start(entry)
        XCTAssertFalse(duplicateStart.isSuccess)
        XCTAssertEqual(
            runtime.runtime(for: entry.id).process,
            running
        )
        XCTAssertEqual(
            runtime.runtime(for: entry.id).lastError,
            L10n.string("The entry is already running.")
        )

        await oldProbeGate.open()
        await oldProbe.value

        let current = runtime.runtime(for: entry.id)
        XCTAssertEqual(current.process, running)
        XCTAssertEqual(
            current.lastError,
            L10n.string("The entry is already running.")
        )
    }

    func testLaterIssuedProbeWinsWhenOverlappingProbesReturnInReverseOrder() async throws {
        let fake = ControlledProcessSupervisor()
        let olderProbeGate = AsyncTestGate()
        let entry = concurrencyEntry(name: "Probe Revision")
        let olderProjection = runningSnapshot(
            entryID: entry.id,
            pid: 271,
            processGroupID: 271
        )
        let newerProjection = ProcessSnapshot(
            entryID: entry.id,
            pid: 271,
            processGroupID: 271,
            liveness: .running,
            launchedAt: olderProjection.launchedAt,
            exitResult: .exited(code: 22)
        )
        await fake.enqueueStartSnapshot(olderProjection)
        await fake.setRefreshOverride(
            olderProjection,
            gate: olderProbeGate,
            call: 1
        )
        await fake.setRefreshOverride(
            newerProjection,
            gate: nil,
            call: 2
        )
        let runtime = await makeRuntimeStore(fake)
        let start = await runtime.start(entry)
        XCTAssertTrue(start.isSuccess)

        let olderProbe = Task {
            await runtime.refreshAll()
        }
        let olderProbeEntered = await waitUntilAsync {
            await fake.refreshCallCount == 1
        }
        XCTAssertTrue(olderProbeEntered)

        await runtime.refreshAll()
        XCTAssertEqual(
            runtime.runtime(for: entry.id).process,
            newerProjection
        )

        await olderProbeGate.open()
        await olderProbe.value

        XCTAssertEqual(
            runtime.runtime(for: entry.id).process,
            newerProjection
        )
    }

    func testLaterManagedEnumerationWinsWhenEnumerationsReturnInReverseOrder() async throws {
        let fake = ControlledProcessSupervisor()
        let olderEnumerationGate = AsyncTestGate()
        let entry = concurrencyEntry(name: "Enumeration Revision")
        let olderProjection = runningSnapshot(
            entryID: entry.id,
            pid: 281,
            processGroupID: 281
        )
        let newerProjection = ProcessSnapshot(
            entryID: entry.id,
            pid: 281,
            processGroupID: 281,
            liveness: .running,
            launchedAt: olderProjection.launchedAt,
            exitResult: .exited(code: 23)
        )
        await fake.enqueueStartSnapshot(olderProjection)
        await fake.setSnapshotsOverride(
            [entry.id: olderProjection],
            gate: olderEnumerationGate,
            call: 1
        )
        await fake.setSnapshotsOverride(
            [entry.id: newerProjection],
            gate: nil,
            call: 2
        )
        let runtime = await makeRuntimeStore(fake)
        let start = await runtime.start(entry)
        XCTAssertTrue(start.isSuccess)

        let olderEnumeration = Task {
            try await runtime.refreshManagedRecords()
        }
        let olderEnumerationEntered = await waitUntilAsync {
            await fake.snapshotsCallCount == 1
        }
        XCTAssertTrue(olderEnumerationEntered)

        _ = try await runtime.refreshManagedRecords()
        XCTAssertEqual(
            runtime.runtime(for: entry.id).process,
            newerProjection
        )

        await olderEnumerationGate.open()
        _ = try await olderEnumeration.value

        XCTAssertEqual(
            runtime.runtime(for: entry.id).process,
            newerProjection
        )
    }

    func testStaleStopTimeoutCannotOverwriteEnumeratedReplacement() async throws {
        let fake = ControlledProcessSupervisor()
        let stopGate = AsyncTestGate()
        let entry = concurrencyEntry(name: "Stop")
        let original = runningSnapshot(
            entryID: entry.id,
            pid: 301,
            processGroupID: 301
        )
        let replacement = runningSnapshot(
            entryID: entry.id,
            pid: 302,
            processGroupID: 302
        )
        await fake.enqueueStartSnapshot(original)
        await fake.setStopBehavior(
            .timedOut(original),
            gate: stopGate,
            call: 1
        )
        let runtime = await makeRuntimeStore(fake)
        let initialStart = await runtime.start(entry)
        XCTAssertTrue(initialStart.isSuccess)

        let stopTask = Task {
            await runtime.stop(entry, timeout: .milliseconds(50))
        }
        let staleStopEntered = await waitUntilAsync {
            await fake.stopCallCount == 1
        }
        XCTAssertTrue(staleStopEntered)

        await fake.replaceRecord(replacement)
        _ = try await runtime.refreshManagedRecords()
        XCTAssertEqual(
            runtime.runtime(for: entry.id).process.pid,
            replacement.pid
        )
        await stopGate.open()
        let staleResult = await stopTask.value

        XCTAssertFalse(staleResult.isSuccess)
        let current = runtime.runtime(for: entry.id)
        XCTAssertEqual(current.process, replacement)
        XCTAssertNil(current.lastError)
    }

    func testRestartOwnsEntryLaneAcrossStopAndStart() async throws {
        let fake = ControlledProcessSupervisor()
        let stopGate = AsyncTestGate()
        let entry = concurrencyEntry(name: "Restart")
        await fake.enqueueStartSnapshot(
            runningSnapshot(
                entryID: entry.id,
                pid: 401,
                processGroupID: 401
            )
        )
        await fake.enqueueStartSnapshot(
            runningSnapshot(
                entryID: entry.id,
                pid: 402,
                processGroupID: 402
            )
        )
        await fake.setStopBehavior(
            .stopped,
            gate: stopGate,
            call: 1
        )
        let runtime = await makeRuntimeStore(fake)
        let initialStart = await runtime.start(entry)
        XCTAssertTrue(initialStart.isSuccess)

        let restartTask = Task {
            await runtime.restart(entry, timeout: .seconds(1))
        }
        let restartStopEntered = await waitUntilAsync {
            await fake.stopCallCount == 1
        }
        XCTAssertTrue(restartStopEntered)
        let competingStart = Task {
            await runtime.start(entry)
        }
        let bothLaunchesAdmitted = await waitUntilMainActor {
            runtime.inFlightLaunchCount == 2
        }
        XCTAssertTrue(bothLaunchesAdmitted)
        let startCountDuringRestartStop = await fake.startCallCount
        XCTAssertEqual(startCountDuringRestartStop, 1)

        await stopGate.open()
        let restartResult = await restartTask.value
        let competingResult = await competingStart.value

        XCTAssertTrue(restartResult.isSuccess)
        XCTAssertFalse(competingResult.isSuccess)
        let events = await fake.events
        XCTAssertEqual(
            events,
            ["start:1", "stop:1", "refresh", "start:2", "start:3"]
        )
        XCTAssertEqual(
            runtime.runtime(for: entry.id).process.pid,
            402
        )
    }

    func testClearOutputDoesNotRestoreRetainedPriorSessionLines() async throws {
        let fake = ControlledProcessSupervisor()
        let entry = concurrencyEntry(name: "Clear")
        await fake.enqueueStartSnapshot(
            runningSnapshot(
                entryID: entry.id,
                pid: 451,
                processGroupID: 451
            )
        )
        await fake.enqueueStartSnapshot(
            runningSnapshot(
                entryID: entry.id,
                pid: 452,
                processGroupID: 452
            )
        )
        let runtime = await makeRuntimeStore(fake)
        let firstStart = await runtime.start(entry)
        XCTAssertTrue(firstStart.isSuccess)
        await fake.emit(Data("OLD_SESSION\n".utf8), entryID: entry.id)
        let oldArrived = await waitUntilMainActor {
            runtime.runtime(for: entry.id)
                .output.displayText.contains("OLD_SESSION")
        }
        XCTAssertTrue(oldArrived)
        let stop = await runtime.stop(entry, timeout: .seconds(1))
        XCTAssertTrue(stop.isSuccess)
        let secondStart = await runtime.start(entry)
        XCTAssertTrue(secondStart.isSuccess)

        runtime.clearOutput(entryID: entry.id)
        await fake.emit(Data("NEW_OUTPUT\n".utf8), entryID: entry.id)
        let newArrived = await waitUntilMainActor {
            runtime.runtime(for: entry.id)
                .output.displayText.contains("NEW_OUTPUT")
        }
        XCTAssertTrue(newArrived)
        XCTAssertFalse(
            runtime.runtime(for: entry.id)
                .output.displayText.contains("OLD_SESSION")
        )
    }

    func testClearOutputResetsActiveAndBlockedPendingSessions() async throws {
        let fake = ControlledProcessSupervisor()
        let pendingStartGate = AsyncTestGate()
        let entry = concurrencyEntry(
            name: "Pending Clear",
            keywords: ["OLD_SESSION", "NEW_OUTPUT"]
        )
        await fake.enqueueStartSnapshot(
            runningSnapshot(
                entryID: entry.id,
                pid: 461,
                processGroupID: 461
            )
        )
        await fake.enqueueStartSnapshot(
            runningSnapshot(
                entryID: entry.id,
                pid: 462,
                processGroupID: 462
            )
        )
        await fake.setStartGate(pendingStartGate, call: 2)
        let runtime = await makeRuntimeStore(fake)
        let firstStart = await runtime.start(entry)
        XCTAssertTrue(firstStart.isSuccess)
        await fake.emit(Data("OLD_SESSION\n".utf8), entryID: entry.id)
        let oldMatchArrived = await waitUntilMainActor {
            runtime.latestGlobalMatch?.keyword == "OLD_SESSION"
        }
        XCTAssertTrue(oldMatchArrived)
        let stop = await runtime.stop(entry, timeout: .seconds(1))
        XCTAssertTrue(stop.isSuccess)

        let pendingStart = Task {
            await runtime.start(entry)
        }
        let pendingSessionCreated = await waitUntilAsync {
            await fake.startCallCount == 2
        }
        XCTAssertTrue(pendingSessionCreated)

        runtime.clearOutput(entryID: entry.id)
        XCTAssertEqual(
            runtime.runtime(for: entry.id).output,
            OutputSnapshot(
                committedLines: [],
                currentLine: "",
                latestMatch: nil
            )
        )
        XCTAssertNil(runtime.latestGlobalMatch)

        await pendingStartGate.open()
        let secondStart = await pendingStart.value
        XCTAssertTrue(secondStart.isSuccess)
        await fake.emit(Data("NEW_OUTPUT\n".utf8), entryID: entry.id)
        let newMatchArrived = await waitUntilMainActor {
            runtime.latestGlobalMatch?.keyword == "NEW_OUTPUT"
        }
        XCTAssertTrue(newMatchArrived)

        let finalOutput = runtime.runtime(for: entry.id).output
        XCTAssertEqual(finalOutput.committedLines, ["NEW_OUTPUT"])
        XCTAssertEqual(finalOutput.currentLine, "")
        XCTAssertEqual(finalOutput.latestMatch?.keyword, "NEW_OUTPUT")
        XCTAssertEqual(
            runtime.latestGlobalMatch?.keyword,
            "NEW_OUTPUT"
        )
    }

    func testStartEnteringAfterTerminationBarrierIsRejected() async throws {
        let fake = ControlledProcessSupervisor()
        let snapshotsGate = AsyncTestGate()
        await fake.setSnapshotsGate(snapshotsGate, call: 1)
        let runtime = await makeRuntimeStore(fake)
        let coordinator = TerminationCoordinator(runtimeStore: runtime)

        let terminationTask = Task {
            await coordinator.stopAllForTermination(
                timeout: .milliseconds(50)
            )
        }
        let enumerationEntered = await waitUntilAsync {
            await fake.snapshotsCallCount == 1
        }
        XCTAssertTrue(enumerationEntered)
        XCTAssertTrue(runtime.isTerminating)

        let entry = concurrencyEntry(name: "Blocked Start")
        let startResult = await runtime.start(entry)

        XCTAssertFalse(startResult.isSuccess)
        let startCalls = await fake.startCallCount
        XCTAssertEqual(startCalls, 0)
        await snapshotsGate.open()
        let terminationResult = await terminationTask.value
        XCTAssertEqual(
            terminationResult,
            .safeToTerminate
        )
        XCTAssertTrue(runtime.isTerminating)
        let snapshots = try await fake.snapshots()
        XCTAssertTrue(snapshots.isEmpty)
    }

    func testTerminationWaitsForAdmittedStartAndReportsItsLivePGID() async throws {
        let fake = ControlledProcessSupervisor()
        let startGate = AsyncTestGate()
        let entry = concurrencyEntry(name: "Inflight")
        let live = runningSnapshot(
            entryID: entry.id,
            pid: 501,
            processGroupID: 501
        )
        await fake.setStartGate(startGate, call: 1)
        await fake.enqueueStartSnapshot(live)
        await fake.setStopBehavior(
            .timedOut(live),
            gate: nil,
            call: 1
        )
        let runtime = await makeRuntimeStore(fake)

        let startTask = Task {
            await runtime.start(entry)
        }
        let admittedStartEntered = await waitUntilAsync {
            await fake.startCallCount == 1
        }
        XCTAssertTrue(admittedStartEntered)
        let terminationTask = Task {
            await TerminationCoordinator(runtimeStore: runtime)
                .stopAllForTermination(timeout: .milliseconds(50))
        }
        let barrierActive = await waitUntilMainActor {
            runtime.isTerminating
        }
        XCTAssertTrue(barrierActive)
        let snapshotsBeforeStartCompletes = await fake.snapshotsCallCount
        XCTAssertEqual(snapshotsBeforeStartCompletes, 0)

        await startGate.open()
        let startResult = await startTask.value
        XCTAssertTrue(startResult.isSuccess)
        let result = await terminationTask.value

        XCTAssertEqual(
            result,
            .remaining([
                RemainingProcess(
                    entryID: entry.id,
                    processGroupID: 501
                )
            ])
        )
        XCTAssertFalse(runtime.isTerminating)

        let later = concurrencyEntry(name: "After Cancel")
        await fake.enqueueStartSnapshot(
            runningSnapshot(
                entryID: later.id,
                pid: 502,
                processGroupID: 502
            )
        )
        let laterStart = await runtime.start(later)
        XCTAssertTrue(laterStart.isSuccess)
    }

    func testRealStartAfterTerminationBarrierCannotCreateLivePGID() async throws {
        let supervisor = ProcessSupervisor()
        let harness = GatedRealClientHarness()
        let snapshotsGate = AsyncTestGate()
        let client = makeGatedRealProcessClient(
            supervisor: supervisor,
            harness: harness,
            snapshotsGate: snapshotsGate
        )
        let runtime = RuntimeStore(
            supervisor: supervisor,
            processClient: client
        )

        let terminationTask = Task {
            await TerminationCoordinator(runtimeStore: runtime)
                .stopAllForTermination(timeout: .milliseconds(200))
        }
        let enumerationEntered = await waitUntilAsync {
            await harness.snapshotsCallCount == 1
        }
        XCTAssertTrue(enumerationEntered)
        XCTAssertTrue(runtime.isTerminating)

        let blockedEntry = concurrencyEntry(name: "Real Blocked")
        let blockedStart = await runtime.start(blockedEntry)
        XCTAssertFalse(blockedStart.isSuccess)
        let startCalls = await harness.startCallCountValue()
        XCTAssertEqual(startCalls, 0)

        await snapshotsGate.open()
        let result = await terminationTask.value
        XCTAssertEqual(result, .safeToTerminate)
        let snapshots = try await supervisor.snapshots()
        XCTAssertTrue(snapshots.isEmpty)
    }

    func testCancelledTerminationReleasesBarrierAndDoesNotReportSafe() async {
        let fake = ControlledProcessSupervisor()
        let snapshotsGate = AsyncTestGate()
        await fake.setSnapshotsGate(snapshotsGate, call: 1)
        let runtime = await makeRuntimeStore(fake)

        let terminationTask = Task {
            await TerminationCoordinator(runtimeStore: runtime)
                .stopAllForTermination(timeout: .milliseconds(50))
        }
        let enumerationEntered = await waitUntilAsync {
            await fake.snapshotsCallCount == 1
        }
        XCTAssertTrue(enumerationEntered)
        XCTAssertTrue(runtime.isTerminating)

        terminationTask.cancel()
        await snapshotsGate.open()
        let result = await terminationTask.value

        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(runtime.isTerminating)
    }

    func testTerminationEnumerationErrorReleasesBarrier() async {
        let fake = ControlledProcessSupervisor()
        await fake.setSnapshotsError(call: 1)
        let runtime = await makeRuntimeStore(fake)

        let result = await TerminationCoordinator(runtimeStore: runtime)
            .stopAllForTermination(timeout: .milliseconds(50))

        XCTAssertEqual(result, .remaining([]))
        XCTAssertFalse(runtime.isTerminating)
    }

    func testTerminationWaitsForGatedRealStartAndReportsActualLivePGID() async throws {
        let supervisor = ProcessSupervisor()
        let harness = GatedRealClientHarness()
        let startReturnGate = AsyncTestGate()
        let client = makeGatedRealProcessClient(
            supervisor: supervisor,
            harness: harness,
            startReturnGate: startReturnGate
        )
        let runtime = RuntimeStore(
            supervisor: supervisor,
            processClient: client
        )
        let entry = CommandEntry(
            id: UUID(),
            name: "Real Inflight",
            cwd: "/tmp",
            command: "trap '' TERM; echo REAL_TERM_READY; exec sleep 30",
            keywords: [],
            order: 0
        )
        var identity: (pid: pid_t, pgid: pid_t)?
        defer {
            if let identity {
                cleanupConcurrencyProcess(identity)
            }
        }

        let startTask = Task {
            await runtime.start(entry)
        }
        let realProcessReady = await waitUntilAsync {
            await harness.outputContains("REAL_TERM_READY")
        }
        XCTAssertTrue(realProcessReady)
        let recordedSnapshot = await harness.startedSnapshot
        let startedSnapshot = try XCTUnwrap(
            recordedSnapshot
        )
        let pid = try XCTUnwrap(startedSnapshot.pid)
        let pgid = try XCTUnwrap(startedSnapshot.processGroupID)
        identity = (pid, pgid)
        let didExecSleep = try await waitForConcurrencyExecutableName(
            pid: pid,
            name: "sleep",
            timeout: .seconds(2)
        )
        XCTAssertTrue(didExecSleep)

        let terminationTask = Task {
            await TerminationCoordinator(runtimeStore: runtime)
                .stopAllForTermination(timeout: .milliseconds(200))
        }
        let barrierActive = await waitUntilMainActor {
            runtime.isTerminating
        }
        XCTAssertTrue(barrierActive)
        let snapshotsBeforeStartReturn = await harness
            .snapshotsCallCountValue()
        XCTAssertEqual(snapshotsBeforeStartReturn, 0)

        await startReturnGate.open()
        let startResult = await startTask.value
        XCTAssertTrue(startResult.isSuccess)
        let terminationResult = await terminationTask.value

        XCTAssertEqual(
            terminationResult,
            .remaining([
                RemainingProcess(
                    entryID: entry.id,
                    processGroupID: pgid
                )
            ])
        )
        XCTAssertTrue(
            try ProcessLauncher.processGroupExists(pgid)
        )
        XCTAssertFalse(runtime.isTerminating)
    }
}

private actor ControlledProcessSupervisor {
    enum StopBehavior: Sendable {
        case stopped
        case timedOut(ProcessSnapshot)
    }

    private var records: [UUID: ProcessSnapshot] = [:]
    private var outputHandlers: [UUID: @Sendable (Data) -> Void] = [:]
    private var queuedStartSnapshots: [ProcessSnapshot] = []
    private var startGates: [Int: AsyncTestGate] = [:]
    private var stopConfigurations: [
        Int: (behavior: StopBehavior, gate: AsyncTestGate?)
    ] = [:]
    private var refreshOverrides: [
        Int: (snapshot: ProcessSnapshot, gate: AsyncTestGate?)
    ] = [:]
    private var snapshotsGates: [Int: AsyncTestGate] = [:]
    private var snapshotsOverrides: [
        Int: (
            snapshots: [UUID: ProcessSnapshot],
            gate: AsyncTestGate?
        )
    ] = [:]
    private var snapshotsErrorCalls: Set<Int> = []

    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var refreshCallCount = 0
    private(set) var snapshotsCallCount = 0
    private(set) var events: [String] = []
    private(set) var startedGenerations: [UUID] = []
    private(set) var writes: [
        (entryID: UUID, generation: UUID, data: Data)
    ] = []
    private(set) var resizes: [
        (entryID: UUID, generation: UUID, size: TerminalSize)
    ] = []

    func client() -> RuntimeProcessClient {
        RuntimeProcessClient(
            start: { entry, generation, onOutput in
                try await self.start(
                    entry: entry,
                    generation: generation,
                    onOutput: onOutput.handler
                )
            },
            write: { entryID, generation, data in
                await self.recordWrite(
                    entryID: entryID,
                    generation: generation,
                    data: data
                )
            },
            resize: { entryID, generation, size in
                await self.recordResize(
                    entryID: entryID,
                    generation: generation,
                    size: size
                )
            },
            stop: { entryID, timeout in
                try await self.stop(entryID: entryID, timeout: timeout)
            },
            refresh: { entryID in
                try await self.refresh(entryID: entryID)
            },
            snapshots: {
                try await self.snapshots()
            }
        )
    }

    func setStartGate(_ gate: AsyncTestGate, call: Int) {
        startGates[call] = gate
    }

    func recordWrite(
        entryID: UUID,
        generation: UUID,
        data: Data
    ) {
        writes.append((entryID, generation, data))
    }

    func recordResize(
        entryID: UUID,
        generation: UUID,
        size: TerminalSize
    ) {
        resizes.append((entryID, generation, size))
    }

    func enqueueStartSnapshot(_ snapshot: ProcessSnapshot) {
        queuedStartSnapshots.append(snapshot)
    }

    func setStopBehavior(
        _ behavior: StopBehavior,
        gate: AsyncTestGate?,
        call: Int
    ) {
        stopConfigurations[call] = (behavior, gate)
    }

    func setRefreshOverride(
        _ snapshot: ProcessSnapshot,
        gate: AsyncTestGate?,
        call: Int
    ) {
        refreshOverrides[call] = (snapshot, gate)
    }

    func setSnapshotsGate(_ gate: AsyncTestGate, call: Int) {
        snapshotsGates[call] = gate
    }

    func setSnapshotsOverride(
        _ snapshots: [UUID: ProcessSnapshot],
        gate: AsyncTestGate?,
        call: Int
    ) {
        snapshotsOverrides[call] = (snapshots, gate)
    }

    func setSnapshotsError(call: Int) {
        snapshotsErrorCalls.insert(call)
    }

    func replaceRecord(_ snapshot: ProcessSnapshot) {
        records[snapshot.entryID] = snapshot
    }

    func emit(_ data: Data, entryID: UUID) {
        outputHandlers[entryID]?(data)
    }

    func start(
        entry: CommandEntry,
        generation: UUID,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> ProcessSnapshot {
        startCallCount += 1
        startedGenerations.append(generation)
        let call = startCallCount
        events.append("start:\(call)")
        if let gate = startGates[call] {
            await gate.wait()
        }
        if records[entry.id]?.liveness == .running {
            throw ProcessSupervisorError.alreadyRunning
        }
        guard let snapshotIndex = queuedStartSnapshots.firstIndex(
            where: { $0.entryID == entry.id }
        ) else {
            throw ProcessSupervisorError.unknownEntry
        }
        let snapshot = queuedStartSnapshots.remove(at: snapshotIndex)
        records[entry.id] = snapshot
        outputHandlers[entry.id] = onOutput
        return snapshot
    }

    func stop(
        entryID: UUID,
        timeout: Duration
    ) async throws -> StopResult {
        _ = timeout
        stopCallCount += 1
        let call = stopCallCount
        events.append("stop:\(call)")
        let configuration = stopConfigurations[call]
            ?? (.stopped, nil)
        if let gate = configuration.gate {
            await gate.wait()
        }

        switch configuration.behavior {
        case .stopped:
            guard let current = records[entryID] else {
                throw ProcessSupervisorError.unknownEntry
            }
            records[entryID] = stoppedSnapshot(
                entryID: entryID,
                exitResult: current.exitResult
            )
            return .stopped
        case .timedOut(let snapshot):
            return .timedOut(snapshot)
        }
    }

    func refresh(entryID: UUID) async throws -> ProcessSnapshot {
        refreshCallCount += 1
        let call = refreshCallCount
        events.append("refresh")
        if let override = refreshOverrides[call] {
            if let gate = override.gate {
                await gate.wait()
            }
            return override.snapshot
        }
        guard let snapshot = records[entryID] else {
            throw ProcessSupervisorError.unknownEntry
        }
        return snapshot
    }

    func snapshots() async throws -> [UUID: ProcessSnapshot] {
        snapshotsCallCount += 1
        let call = snapshotsCallCount
        if snapshotsErrorCalls.contains(call) {
            throw ProcessSupervisorError.unknownEntry
        }
        if let override = snapshotsOverrides[call] {
            if let gate = override.gate {
                await gate.wait()
            }
            return override.snapshots
        }
        if let gate = snapshotsGates[call] {
            await gate.wait()
        }
        return records
    }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }
}

private actor GatedRealClientHarness {
    private var output = Data()
    private(set) var startedSnapshot: ProcessSnapshot?
    private(set) var startCallCount = 0
    private(set) var snapshotsCallCount = 0

    func recordStart(_ snapshot: ProcessSnapshot) {
        startCallCount += 1
        startedSnapshot = snapshot
    }

    func recordOutput(_ data: Data) {
        output.append(data)
    }

    func recordSnapshotsCall() {
        snapshotsCallCount += 1
    }

    func outputContains(_ marker: String) -> Bool {
        String(decoding: output, as: UTF8.self).contains(marker)
    }

    func startCallCountValue() -> Int {
        startCallCount
    }

    func snapshotsCallCountValue() -> Int {
        snapshotsCallCount
    }
}

private func makeGatedRealProcessClient(
    supervisor: ProcessSupervisor,
    harness: GatedRealClientHarness,
    startReturnGate: AsyncTestGate? = nil,
    snapshotsGate: AsyncTestGate? = nil
) -> RuntimeProcessClient {
    RuntimeProcessClient(
        start: { entry, generation, outputHandler in
            let snapshot = try await supervisor.start(
                entry: entry,
                generation: generation
            ) { data in
                outputHandler.handler(data)
                Task {
                    await harness.recordOutput(data)
                }
            }
            await harness.recordStart(snapshot)
            if let startReturnGate {
                await startReturnGate.wait()
            }
            return snapshot
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
            await harness.recordSnapshotsCall()
            if let snapshotsGate {
                await snapshotsGate.wait()
            }
            return try await supervisor.snapshots()
        }
    )
}

@MainActor
private func makeRuntimeStore(
    _ fake: ControlledProcessSupervisor
) async -> RuntimeStore {
    RuntimeStore(
        supervisor: ProcessSupervisor(),
        processClient: await fake.client()
    )
}

private func concurrencyEntry(
    name: String,
    keywords: [String] = []
) -> CommandEntry {
    CommandEntry(
        id: UUID(),
        name: name,
        cwd: "/tmp",
        command: "exec sleep 30",
        keywords: keywords,
        order: 0
    )
}

private func runningSnapshot(
    entryID: UUID,
    pid: pid_t,
    processGroupID: pid_t
) -> ProcessSnapshot {
    ProcessSnapshot(
        entryID: entryID,
        pid: pid,
        processGroupID: processGroupID,
        liveness: .running,
        launchedAt: Date(timeIntervalSince1970: TimeInterval(pid)),
        exitResult: nil
    )
}

private func stoppedSnapshot(
    entryID: UUID,
    exitResult: ChildWaitResult? = nil
) -> ProcessSnapshot {
    ProcessSnapshot(
        entryID: entryID,
        pid: nil,
        processGroupID: nil,
        liveness: .stopped,
        launchedAt: nil,
        exitResult: exitResult
    )
}

@MainActor
private func waitUntilAsync(
    timeout: Duration = .seconds(2),
    condition: @MainActor () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() {
            return true
        }
        try? await clock.sleep(for: .milliseconds(5))
    }
    return await condition()
}

@MainActor
private func waitUntilMainActor(
    timeout: Duration = .seconds(2),
    condition: () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() {
            return true
        }
        try? await clock.sleep(for: .milliseconds(5))
    }
    return condition()
}

private func waitForConcurrencyExecutableName(
    pid: pid_t,
    name: String,
    timeout: Duration
) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if try concurrencyExecutableName(pid: pid) == name {
            return true
        }
        try await clock.sleep(for: .milliseconds(10))
    }
    return try concurrencyExecutableName(pid: pid) == name
}

private func concurrencyExecutableName(pid: pid_t) throws -> String? {
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

private func cleanupConcurrencyProcess(
    _ identity: (pid: pid_t, pgid: pid_t)
) {
    let killResult = Darwin.killpg(identity.pgid, SIGKILL)
    let killError = killResult == -1 ? errno : 0
    XCTAssertTrue(
        killResult == 0 || (killResult == -1 && killError == ESRCH),
        "cleanup killpg(\(identity.pgid), SIGKILL) failed with errno \(killError)"
    )

    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    var leaderHandled = false
    while ContinuousClock.now < deadline {
        var status: Int32 = 0
        let result = Darwin.waitpid(identity.pid, &status, WNOHANG)
        if result == identity.pid || (result == -1 && errno == ECHILD) {
            leaderHandled = true
            break
        }
        if result == -1 && errno != EINTR {
            XCTFail(
                "cleanup waitpid(\(identity.pid)) failed with errno \(errno)"
            )
            break
        }
        usleep(10_000)
    }
    XCTAssertTrue(
        leaderHandled,
        "cleanup did not reap leader \(identity.pid)"
    )

    var groupGone = false
    while ContinuousClock.now < deadline {
        if Darwin.killpg(identity.pgid, 0) == -1 && errno == ESRCH {
            groupGone = true
            break
        }
        usleep(10_000)
    }
    XCTAssertTrue(
        groupGone,
        "cleanup left process group \(identity.pgid)"
    )
}

import Darwin
import Foundation
import XCTest
@testable import AloftApp

@MainActor
final class RuntimeStoreTests: XCTestCase {
    func testClearOutputRetainsLastTermination() {
        let runtime = RuntimeStore(
            supervisor: ProcessSupervisor()
        )
        let entryID = UUID()
        let record = ProcessTerminationRecord(
            endedAt: Date(timeIntervalSince1970: 123),
            result: .exited(code: 17),
            kind: .unexpected,
            detail: "Exited with status 17."
        )
        runtime.runtime(for: entryID).lastTermination = record

        runtime.clearOutput(entryID: entryID)

        XCTAssertEqual(
            runtime.runtime(for: entryID).lastTermination,
            record
        )
    }

    func testNewStartRetainsPreviousTerminationUntilCurrentGenerationEnds()
        async {
        let fixture = await makeTerminalRuntimeFixture(
            startPlans: [
                .success(outputBeforeReturn: Data()),
            ]
        )
        let record = ProcessTerminationRecord(
            endedAt: Date(timeIntervalSince1970: 123),
            result: .exited(code: 17),
            kind: .unexpected,
            detail: "Exited with status 17."
        )
        fixture.runtime.runtime(for: fixture.entry.id)
            .lastTermination = record

        let result = await fixture.runtime.start(fixture.entry)

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(
            fixture.runtime.runtime(for: fixture.entry.id)
                .lastTermination,
            record
        )
    }

    func testMonitoredNormalExitRecordsWithoutAttention() async {
        let fixture = await makeTerminalRuntimeFixture(
            startPlans: [
                .success(outputBeforeReturn: Data()),
            ]
        )
        var delivered: [RuntimeAttentionItem] = []
        fixture.runtime.onAttention = { delivered.append($0) }
        let start = await fixture.runtime.start(fixture.entry)
        XCTAssertTrue(start.isSuccess)
        await fixture.process.setRefreshSnapshot(
            stoppedSnapshot(
                entryID: fixture.entry.id,
                exitResult: .exited(code: 0)
            )
        )

        await fixture.runtime.refreshAll()

        XCTAssertEqual(
            fixture.runtime.runtime(for: fixture.entry.id)
                .lastTermination?.kind,
            .normal
        )
        XCTAssertEqual(
            fixture.runtime.runtime(for: fixture.entry.id)
                .lastTermination?.result,
            .exited(code: 0)
        )
        XCTAssertTrue(
            fixture.runtime.unacknowledgedAttentionItems.isEmpty
        )
        XCTAssertTrue(delivered.isEmpty)
    }

    func testMonitoredNonzeroExitRecordsAndPublishesOneAttention()
        async {
        let fixture = await makeTerminalRuntimeFixture(
            startPlans: [
                .success(outputBeforeReturn: Data()),
            ]
        )
        var delivered: [RuntimeAttentionItem] = []
        fixture.runtime.onAttention = { delivered.append($0) }
        let start = await fixture.runtime.start(fixture.entry)
        XCTAssertTrue(start.isSuccess)
        await fixture.process.setRefreshSnapshot(
            stoppedSnapshot(
                entryID: fixture.entry.id,
                exitResult: .exited(code: 17)
            )
        )

        await fixture.runtime.refreshAll()

        let entryRuntime = fixture.runtime.runtime(
            for: fixture.entry.id
        )
        XCTAssertEqual(entryRuntime.lastTermination?.kind, .unexpected)
        XCTAssertEqual(
            entryRuntime.lastTermination?.result,
            .exited(code: 17)
        )
        XCTAssertEqual(
            fixture.runtime.unacknowledgedAttentionItems.count,
            1
        )
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.entryID, fixture.entry.id)
    }

    func testMonitoredSignalExitIncludesSignalAndPublishesAttention()
        async {
        let fixture = await makeTerminalRuntimeFixture(
            startPlans: [
                .success(outputBeforeReturn: Data()),
            ]
        )
        var delivered: [RuntimeAttentionItem] = []
        fixture.runtime.onAttention = { delivered.append($0) }
        let start = await fixture.runtime.start(fixture.entry)
        XCTAssertTrue(start.isSuccess)
        await fixture.process.setRefreshSnapshot(
            stoppedSnapshot(
                entryID: fixture.entry.id,
                exitResult: .signaled(signal: SIGABRT)
            )
        )

        await fixture.runtime.refreshAll()

        let termination = fixture.runtime.runtime(
            for: fixture.entry.id
        ).lastTermination
        XCTAssertEqual(termination?.kind, .unexpected)
        XCTAssertEqual(
            termination?.result,
            .signaled(signal: SIGABRT)
        )
        XCTAssertTrue(
            termination?.detail.contains(String(SIGABRT)) == true
        )
        XCTAssertEqual(delivered.count, 1)
    }

    func testMonitoredExitWithoutWaitStatusPublishesUnavailableAttention()
        async {
        let fixture = await makeTerminalRuntimeFixture(
            startPlans: [
                .success(outputBeforeReturn: Data()),
            ]
        )
        var delivered: [RuntimeAttentionItem] = []
        fixture.runtime.onAttention = { delivered.append($0) }
        let start = await fixture.runtime.start(fixture.entry)
        XCTAssertTrue(start.isSuccess)
        await fixture.process.setRefreshSnapshot(
            stoppedSnapshot(
                entryID: fixture.entry.id,
                exitResult: nil
            )
        )

        await fixture.runtime.refreshAll()

        XCTAssertEqual(
            fixture.runtime.runtime(for: fixture.entry.id)
                .lastTermination?.kind,
            .unavailable
        )
        XCTAssertEqual(delivered.count, 1)
    }

    func testSuccessfulStopRecordsIntentionalTerminationWithoutAttention()
        async {
        let fixture = await makeTerminalRuntimeFixture(
            startPlans: [
                .success(outputBeforeReturn: Data()),
            ]
        )
        var delivered: [RuntimeAttentionItem] = []
        fixture.runtime.onAttention = { delivered.append($0) }
        let start = await fixture.runtime.start(fixture.entry)
        XCTAssertTrue(start.isSuccess)
        await fixture.process.setStopResult(.stopped)
        await fixture.process.setRefreshSnapshot(
            stoppedSnapshot(
                entryID: fixture.entry.id,
                exitResult: .signaled(signal: SIGTERM)
            )
        )

        let stop = await fixture.runtime.stop(fixture.entry)

        XCTAssertTrue(stop.isSuccess)
        XCTAssertEqual(
            fixture.runtime.runtime(for: fixture.entry.id)
                .lastTermination?.kind,
            .intentional
        )
        XCTAssertEqual(
            fixture.runtime.runtime(for: fixture.entry.id)
                .lastTermination?.result,
            .signaled(signal: SIGTERM)
        )
        XCTAssertTrue(
            fixture.runtime.unacknowledgedAttentionItems.isEmpty
        )
        XCTAssertTrue(delivered.isEmpty)
    }

    func testStopManagedRecordsDoesNotPublishUnexpectedTermination()
        async {
        let fixture = await makeTerminalRuntimeFixture(
            startPlans: [
                .success(outputBeforeReturn: Data()),
            ]
        )
        var delivered: [RuntimeAttentionItem] = []
        fixture.runtime.onAttention = { delivered.append($0) }
        let start = await fixture.runtime.start(fixture.entry)
        XCTAssertTrue(start.isSuccess)
        await fixture.process.setStopResult(.stopped)
        await fixture.process.setRefreshSnapshot(
            stoppedSnapshot(
                entryID: fixture.entry.id,
                exitResult: .signaled(signal: SIGTERM)
            )
        )

        let results = await fixture.runtime.stopManagedRecords(
            entryIDs: [fixture.entry.id],
            timeout: .seconds(1)
        )

        XCTAssertEqual(results.map(\.isSuccess), [true])
        XCTAssertEqual(
            fixture.runtime.runtime(for: fixture.entry.id)
                .lastTermination?.kind,
            .intentional
        )
        XCTAssertTrue(delivered.isEmpty)
    }

    func testAttentionQueueKeepsNewestFiftyItems() {
        let runtime = RuntimeStore(
            supervisor: ProcessSupervisor()
        )

        for index in 0 ..< 51 {
            let entry = CommandEntry(
                id: UUID(),
                name: "Entry \(index)",
                cwd: "/tmp",
                command: "unused",
                keywords: [],
                order: index
            )
            runtime.recordOperationFailure(
                operation: .stop,
                entries: [entry],
                results: [
                    EntryActionResult(
                        entryID: entry.id,
                        errorDescription: "Failure \(index)"
                    ),
                ]
            )
        }

        XCTAssertEqual(runtime.attentionItems.count, 50)
        XCTAssertTrue(
            runtime.attentionItems.first?.detail
                .contains("Failure 50") == true
        )
        XCTAssertFalse(
            runtime.attentionItems.contains {
                $0.detail.contains("Failure 0")
            }
        )
    }

    func testAcknowledgingAttentionUpdatesActiveCountWithoutDeletingHistory()
        throws {
        let runtime = RuntimeStore(
            supervisor: ProcessSupervisor()
        )
        let entries = [0, 1].map { index in
            CommandEntry(
                id: UUID(),
                name: "Entry \(index)",
                cwd: "/tmp",
                command: "unused",
                keywords: [],
                order: index
            )
        }
        for entry in entries {
            runtime.recordOperationFailure(
                operation: .stop,
                entries: [entry],
                results: [
                    EntryActionResult(
                        entryID: entry.id,
                        errorDescription: "Failure"
                    ),
                ]
            )
        }
        let newestID = try XCTUnwrap(runtime.attentionItems.first?.id)

        runtime.acknowledgeAttention(id: newestID)

        XCTAssertEqual(runtime.attentionItems.count, 2)
        XCTAssertEqual(runtime.unacknowledgedAttentionItems.count, 1)

        runtime.acknowledgeAllAttention()

        XCTAssertEqual(runtime.attentionItems.count, 2)
        XCTAssertTrue(runtime.unacknowledgedAttentionItems.isEmpty)
    }

    func testRemovingEntryRemovesItsAttentionItems() throws {
        let runtime = RuntimeStore(
            supervisor: ProcessSupervisor()
        )
        let entry = CommandEntry(
            id: UUID(),
            name: "Removed",
            cwd: "/tmp",
            command: "unused",
            keywords: [],
            order: 0
        )
        runtime.recordOperationFailure(
            operation: .stop,
            entries: [entry],
            results: [
                EntryActionResult(
                    entryID: entry.id,
                    errorDescription: "Failure"
                ),
            ]
        )

        try runtime.removeEntry(entryID: entry.id)

        XCTAssertFalse(
            runtime.attentionItems.contains {
                $0.entryID == entry.id
            }
        )
    }

    func testRemovingEntryRemovesAggregateAttentionRelatedToIt()
        throws {
        let runtime = RuntimeStore(
            supervisor: ProcessSupervisor()
        )
        let entries = ["One", "Two"].enumerated().map {
            index, name in
            CommandEntry(
                id: UUID(),
                name: name,
                cwd: "/tmp",
                command: "unused",
                keywords: [],
                order: index
            )
        }
        runtime.recordOperationFailure(
            operation: .stop,
            entries: entries,
            results: entries.map {
                EntryActionResult(
                    entryID: $0.id,
                    errorDescription: "Failure"
                )
            }
        )
        XCTAssertNil(runtime.attentionItems.first?.entryID)

        try runtime.removeEntry(entryID: entries[0].id)

        XCTAssertTrue(runtime.attentionItems.isEmpty)
    }

    func testClearOutputClearsTextAndTerminalWithoutStoppingProcess()
        async {
        let fixture = await makeTerminalRuntimeFixture(
            startPlans: [
                .success(
                    outputBeforeReturn: Data("visible".utf8)
                ),
            ]
        )
        let start = await fixture.runtime.start(fixture.entry)
        XCTAssertTrue(start.isSuccess)

        fixture.runtime.clearOutput(entryID: fixture.entry.id)

        XCTAssertEqual(
            fixture.runtime.runtime(for: fixture.entry.id)
                .output.displayText,
            ""
        )
        XCTAssertTrue(fixture.surface.events.contains(.clear))
        XCTAssertEqual(
            fixture.runtime.runtime(for: fixture.entry.id)
                .process.liveness,
            .running
        )
    }

    func testSuccessfulStopClearsOutputAndRejectsLateTerminalBytes()
        async throws {
        let fixture = await makeTerminalRuntimeFixture(
            startPlans: [
                .success(
                    outputBeforeReturn: Data("visible".utf8)
                ),
            ]
        )
        let start = await fixture.runtime.start(fixture.entry)
        XCTAssertTrue(start.isSuccess)
        let generations = await fixture.process.startedGenerations
        let generation = try XCTUnwrap(
            generations.first
        )
        let outputArrived = await waitUntilMainActor(
            timeout: .seconds(1)
        ) {
            fixture.runtime.runtime(for: fixture.entry.id)
                .output.displayText.contains("visible")
        }
        XCTAssertTrue(outputArrived)
        XCTAssertEqual(fixture.surface.visibleText, "visible")

        let stop = await fixture.runtime.stop(fixture.entry)

        XCTAssertTrue(stop.isSuccess)
        XCTAssertEqual(
            fixture.runtime.runtime(for: fixture.entry.id)
                .output.displayText,
            ""
        )
        XCTAssertEqual(fixture.surface.visibleText, "")

        fixture.surface.feed(
            Data("late".utf8),
            generation: generation
        )

        XCTAssertEqual(fixture.surface.visibleText, "")
        XCTAssertEqual(
            fixture.runtime.runtime(for: fixture.entry.id)
                .output.displayText,
            ""
        )
    }

    func testTimedOutStopPreservesOutputAndAcceptsContinuedBytes()
        async throws {
        let fixture = await makeTerminalRuntimeFixture(
            startPlans: [
                .success(
                    outputBeforeReturn: Data("visible".utf8)
                ),
            ]
        )
        let start = await fixture.runtime.start(fixture.entry)
        XCTAssertTrue(start.isSuccess)
        let generations = await fixture.process.startedGenerations
        let generation = try XCTUnwrap(generations.first)
        let running = fixture.runtime.runtime(
            for: fixture.entry.id
        ).process
        await fixture.process.setStopResult(
            .timedOut(running)
        )
        let outputArrived = await waitUntilMainActor(
            timeout: .seconds(1)
        ) {
            fixture.runtime.runtime(for: fixture.entry.id)
                .output.displayText.contains("visible")
        }
        XCTAssertTrue(outputArrived)

        let stop = await fixture.runtime.stop(fixture.entry)

        XCTAssertFalse(stop.isSuccess)
        XCTAssertTrue(
            fixture.runtime.runtime(for: fixture.entry.id)
                .output.displayText.contains("visible")
        )
        XCTAssertEqual(fixture.surface.visibleText, "visible")

        fixture.surface.feed(
            Data("continued".utf8),
            generation: generation
        )

        XCTAssertEqual(
            fixture.surface.visibleText,
            "visiblecontinued"
        )
    }

    func testUnavailableTerminalDoesNotStopProcess()
        async {
        let fixture = await makeTerminalRuntimeFixture(
            startPlans: [
                .success(
                    outputBeforeReturn: Data("visible".utf8)
                ),
            ]
        )
        let start = await fixture.runtime.start(fixture.entry)
        XCTAssertTrue(start.isSuccess)

        fixture.surface.publishRendererState(
            .unavailable("renderer unavailable")
        )
        let rendererStateUpdated = await waitUntilMainActor(
            timeout: .seconds(1)
        ) {
            fixture.runtime.runtime(for: fixture.entry.id)
                .terminalRendererState
                == .unavailable("renderer unavailable")
        }

        XCTAssertTrue(rendererStateUpdated)
        XCTAssertEqual(
            fixture.runtime.runtime(for: fixture.entry.id)
                .terminalRendererState,
            .unavailable("renderer unavailable")
        )
        XCTAssertEqual(
            fixture.runtime.runtime(for: fixture.entry.id)
                .process.liveness,
            .running
        )
    }

    func testCurrentGenerationTerminalWriteErrorProjectsLastError()
        async throws {
        let fixture = await makeTerminalRuntimeFixture(
            startPlans: [
                .success(
                    outputBeforeReturn: Data("visible".utf8)
                ),
            ]
        )
        let start = await fixture.runtime.start(fixture.entry)
        XCTAssertTrue(start.isSuccess)
        await fixture.process.setCallbackErrors(
            write: .unknownEntry,
            resize: nil
        )
        let generations = await fixture.process.startedGenerations
        let generation = try XCTUnwrap(generations.first)
        let callbacks = try XCTUnwrap(
            fixture.surface.callbacks(for: generation)
        )

        callbacks.writeProtocolReply(
            Data("reply".utf8),
            generation
        )
        await fixture.process.waitForCallbackTasks(
            expectedCount: 1
        )
        let projected = await waitUntilMainActor(
            timeout: .seconds(1)
        ) {
            fixture.runtime.runtime(for: fixture.entry.id)
                .lastError
                == L10n.string(
                    "The entry has no managed process."
                )
        }

        XCTAssertTrue(projected)
        XCTAssertEqual(
            fixture.runtime.runtime(for: fixture.entry.id)
                .process.liveness,
            .running
        )
    }

    func testStaleTerminalCallbackErrorsPreserveCurrentError()
        async throws {
        let fixture = await makeTerminalRuntimeFixture(
            startPlans: [
                .success(
                    outputBeforeReturn: Data("visible".utf8)
                ),
            ]
        )
        let start = await fixture.runtime.start(fixture.entry)
        XCTAssertTrue(start.isSuccess)
        await fixture.process.setCallbackErrors(
            write: .staleGeneration,
            resize: .staleGeneration
        )
        let generations = await fixture.process.startedGenerations
        let generation = try XCTUnwrap(generations.first)
        let callbacks = try XCTUnwrap(
            fixture.surface.callbacks(for: generation)
        )
        fixture.runtime.runtime(for: fixture.entry.id)
            .lastError = "retained error"

        callbacks.writeProtocolReply(
            Data("reply".utf8),
            generation
        )
        callbacks.resizePTY(
            TerminalSize(
                columns: 90,
                rows: 30,
                pixelWidth: 900,
                pixelHeight: 600
            )!,
            generation
        )
        await fixture.process.waitForCallbackTasks(
            expectedCount: 2
        )
        await Task.yield()

        XCTAssertEqual(
            fixture.runtime.runtime(for: fixture.entry.id)
                .lastError,
            "retained error"
        )
    }

    func testStartPromotesPendingTerminalBytesOnlyAfterLaunchSuccess()
        async {
        let fixture = await makeTerminalRuntimeFixture(
            startPlans: [
                .success(
                    outputBeforeReturn: Data("early".utf8)
                ),
            ]
        )

        let result = await fixture.runtime.start(fixture.entry)

        XCTAssertTrue(result.isSuccess)
        let generations = await fixture.process.startedGenerations
        XCTAssertEqual(generations.count, 1)
        XCTAssertEqual(fixture.surface.events, [
            .prepare(generations[0]),
            .promote(generations[0]),
            .feed("early", generations[0]),
        ])
        XCTAssertEqual(fixture.surface.visibleText, "early")
    }

    func testFailedStartDiscardsPendingBytesAndPreservesRetainedSurface()
        async {
        let fixture = await makeTerminalRuntimeFixture(
            startPlans: [
                .success(
                    outputBeforeReturn: Data("old".utf8)
                ),
                .failure(
                    .launchFailed,
                    outputBeforeReturn: Data("new".utf8)
                ),
            ]
        )

        let first = await fixture.runtime.start(fixture.entry)
        let second = await fixture.runtime.start(fixture.entry)

        XCTAssertTrue(first.isSuccess)
        XCTAssertFalse(second.isSuccess)
        let generations = await fixture.process.startedGenerations
        XCTAssertEqual(generations.count, 2)
        XCTAssertEqual(fixture.surface.visibleText, "old")
        XCTAssertTrue(
            fixture.surface.events.contains(
                .discard(generations[1])
            )
        )
        XCTAssertFalse(
            fixture.surface.events.contains(
                .feed("new", generations[1])
            )
        )
    }

    func testStartAllStreamsIndependentOutputAndStopAllStopsEveryGroup() async throws {
        let runtime = RuntimeStore(supervisor: ProcessSupervisor())
        let entries = [
            fixtureEntry(name: "One", command: "echo one; exec sleep 30"),
            fixtureEntry(name: "Two", command: "echo two; exec sleep 30"),
        ]
        var identities: [(pid: pid_t, pgid: pid_t)] = []
        defer { identities.forEach(cleanupRuntimeProcess) }

        let startResults = await runtime.startAll(entries)
        identities = entries.compactMap {
            let process = runtime.runtime(for: $0.id).process
            guard let pid = process.pid,
                  let pgid = process.processGroupID else {
                return nil
            }
            return (pid, pgid)
        }

        XCTAssertEqual(startResults.map(\.entryID), entries.map(\.id))
        XCTAssertEqual(startResults.filter(\.isSuccess).count, 2)
        let receivedIndependentOutput = await waitUntilMainActor(
            timeout: .seconds(2)
        ) {
            runtime.runtime(for: entries[0].id)
                .output.displayText.contains("one")
                && runtime.runtime(for: entries[1].id)
                .output.displayText.contains("two")
        }
        XCTAssertTrue(receivedIndependentOutput)

        let stopResults = await runtime.stopAll(
            entries,
            timeout: .seconds(2)
        )

        XCTAssertEqual(stopResults.map(\.entryID), entries.map(\.id))
        XCTAssertEqual(stopResults.filter(\.isSuccess).count, 2)
        XCTAssertTrue(runtime.liveEntryIDs.isEmpty)
        for identity in identities {
            XCTAssertFalse(
                try ProcessLauncher.processGroupExists(identity.pgid)
            )
        }
    }

    func testGroupActionReturnsSuccessAndFailureWithoutSkippingEntries() async throws {
        let runtime = RuntimeStore(supervisor: ProcessSupervisor())
        let valid = fixtureEntry(
            name: "Valid",
            command: "echo VALID_READY; exec sleep 30"
        )
        let invalid = fixtureEntry(
            name: "Invalid",
            cwd: "/path/that/does/not/exist",
            command: "exec sleep 30"
        )
        var identity: (pid: pid_t, pgid: pid_t)?
        defer {
            if let identity {
                cleanupRuntimeProcess(identity)
            }
        }

        let results = await runtime.startAll([valid, invalid])
        let process = runtime.runtime(for: valid.id).process
        if let pid = process.pid, let pgid = process.processGroupID {
            identity = (pid, pgid)
        }

        XCTAssertEqual(results.map(\.entryID), [valid.id, invalid.id])
        XCTAssertTrue(results[0].isSuccess)
        XCTAssertFalse(results[1].isSuccess)
        XCTAssertNotNil(
            runtime.runtime(for: invalid.id).lastError
        )
        XCTAssertTrue(runtime.liveEntryIDs.contains(valid.id))
        XCTAssertFalse(runtime.liveEntryIDs.contains(invalid.id))

        let stop = await runtime.stop(valid, timeout: .seconds(2))
        XCTAssertTrue(stop.isSuccess)
    }

    func testRestartRetainsOutputAddsSessionSeparatorAndProjectsLatestMatch() async throws {
        let runtime = RuntimeStore(supervisor: ProcessSupervisor())
        let entryID = UUID()
        let firstEntry = fixtureEntry(
            id: entryID,
            name: "Matcher",
            command: "echo FIRST_READY; exec sleep 30",
            keywords: ["FIRST_READY"]
        )
        let secondEntry = fixtureEntry(
            id: entryID,
            name: "Matcher",
            command: "echo SECOND_READY; exec sleep 30",
            keywords: ["SECOND_READY"]
        )
        var identities: [(pid: pid_t, pgid: pid_t)] = []
        defer { identities.forEach(cleanupRuntimeProcess) }

        let firstResult = await runtime.start(firstEntry)
        let first = runtime.runtime(for: entryID).process
        identities.append(
            (
                try XCTUnwrap(first.pid),
                try XCTUnwrap(first.processGroupID)
            )
        )
        XCTAssertTrue(firstResult.isSuccess)
        let receivedFirstMatch = await waitUntilMainActor(
            timeout: .seconds(2)
        ) {
            runtime.latestGlobalMatch?.entryID == entryID
                && runtime.latestGlobalMatch?.keyword == "FIRST_READY"
        }
        XCTAssertTrue(receivedFirstMatch)

        let restartResult = await runtime.restart(
            secondEntry,
            timeout: .seconds(2)
        )
        let second = runtime.runtime(for: entryID).process
        identities.append(
            (
                try XCTUnwrap(second.pid),
                try XCTUnwrap(second.processGroupID)
            )
        )
        XCTAssertTrue(restartResult.isSuccess)
        XCTAssertNotEqual(first.processGroupID, second.processGroupID)
        let receivedSecondSession = await waitUntilMainActor(
            timeout: .seconds(2)
        ) {
            runtime.runtime(for: entryID)
                .output.displayText.contains("FIRST_READY")
                && runtime.runtime(for: entryID)
                .output.displayText.contains("SECOND_READY")
                && runtime.latestGlobalMatch?.keyword == "SECOND_READY"
        }
        XCTAssertTrue(receivedSecondSession)
        XCTAssertEqual(
            occurrences(
                of: L10n.string(
                    "──── Session started %@ ────"
                ).components(separatedBy: "%@")[0],
                in: runtime.runtime(for: entryID).output.displayText
            ),
            2
        )

        runtime.clearOutput(entryID: entryID)

        XCTAssertEqual(
            runtime.runtime(for: entryID).output,
            OutputSnapshot(
                committedLines: [],
                currentLine: "",
                latestMatch: nil
            )
        )
        XCTAssertNil(runtime.latestGlobalMatch)
        XCTAssertEqual(
            runtime.runtime(for: entryID).process.processGroupID,
            second.processGroupID
        )

        let stop = await runtime.stop(secondEntry, timeout: .seconds(2))
        XCTAssertTrue(stop.isSuccess)
    }

    func testRestartAllReturnsEveryEntryWithFreshProcessGroups() async throws {
        let runtime = RuntimeStore(supervisor: ProcessSupervisor())
        let entries = [
            fixtureEntry(name: "One", command: "exec sleep 30"),
            fixtureEntry(name: "Two", command: "exec sleep 30"),
        ]
        var identities: [(pid: pid_t, pgid: pid_t)] = []
        defer { identities.forEach(cleanupRuntimeProcess) }

        let starts = await runtime.startAll(entries)
        XCTAssertEqual(starts.filter(\.isSuccess).count, 2)
        let firstIdentities = try entries.map { entry in
            let process = runtime.runtime(for: entry.id).process
            return (
                pid: try XCTUnwrap(process.pid),
                pgid: try XCTUnwrap(process.processGroupID)
            )
        }
        identities.append(contentsOf: firstIdentities)
        for identity in firstIdentities {
            let didExec = try await waitForExecutableName(
                pid: identity.pid,
                name: "sleep",
                timeout: .seconds(2)
            )
            XCTAssertTrue(didExec)
        }

        let restarts = await runtime.restartAll(
            entries,
            timeout: .seconds(2)
        )
        XCTAssertEqual(restarts.map(\.entryID), entries.map(\.id))
        XCTAssertEqual(restarts.filter(\.isSuccess).count, 2)

        let secondIdentities = try entries.map { entry in
            let process = runtime.runtime(for: entry.id).process
            return (
                pid: try XCTUnwrap(process.pid),
                pgid: try XCTUnwrap(process.processGroupID)
            )
        }
        identities.append(contentsOf: secondIdentities)
        XCTAssertEqual(Set(firstIdentities.map(\.pgid)).count, 2)
        XCTAssertEqual(Set(secondIdentities.map(\.pgid)).count, 2)
        XCTAssertTrue(
            Set(firstIdentities.map(\.pgid))
                .isDisjoint(with: Set(secondIdentities.map(\.pgid)))
        )
        for identity in secondIdentities {
            let didExec = try await waitForExecutableName(
                pid: identity.pid,
                name: "sleep",
                timeout: .seconds(2)
            )
            XCTAssertTrue(didExec)
        }
        for identity in firstIdentities {
            XCTAssertFalse(
                try ProcessLauncher.processGroupExists(identity.pgid)
            )
        }

        let stops = await runtime.stopAll(entries, timeout: .seconds(2))
        XCTAssertEqual(stops.filter(\.isSuccess).count, 2)
        XCTAssertTrue(runtime.liveEntryIDs.isEmpty)
    }

    func testMonitoringReplacesRunningProjectionWithFreshKernelProbe() async throws {
        let runtime = RuntimeStore(supervisor: ProcessSupervisor())
        let entry = fixtureEntry(
            name: "Short",
            command: "echo NATURAL_EXIT_OUTPUT; exec sleep 0.2"
        )
        let result = await runtime.start(entry)
        let started = runtime.runtime(for: entry.id).process
        let pid = try XCTUnwrap(started.pid)
        let pgid = try XCTUnwrap(started.processGroupID)
        defer { cleanupRuntimeProcess((pid, pgid)) }

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(started.liveness, .running)
        let observedOutput = await waitUntilMainActor(
            timeout: .seconds(1)
        ) {
            runtime.runtime(for: entry.id)
                .output.displayText.contains(
                    "NATURAL_EXIT_OUTPUT"
                )
        }
        XCTAssertTrue(observedOutput)
        let observedNaturalExit = await waitUntilMainActor(
            timeout: .seconds(2)
        ) {
            runtime.runtime(for: entry.id).process.liveness == .stopped
        }
        XCTAssertTrue(observedNaturalExit)

        let refreshed = runtime.runtime(for: entry.id).process
        XCTAssertEqual(refreshed.exitResult, .exited(code: 0))
        XCTAssertNil(refreshed.pid)
        XCTAssertNil(refreshed.processGroupID)
        XCTAssertTrue(runtime.liveEntryIDs.isEmpty)
        XCTAssertEqual(
            runtime.runtime(for: entry.id).output.displayText,
            ""
        )
    }

    func testTerminationReturnsEverySIGTERMResistantEntryAndPGID() async throws {
        let runtime = RuntimeStore(supervisor: ProcessSupervisor())
        let entries = [
            fixtureEntry(
                name: "One",
                command: "trap '' TERM; echo TERM_READY_ONE; exec sleep 30"
            ),
            fixtureEntry(
                name: "Two",
                command: "trap '' TERM; echo TERM_READY_TWO; exec sleep 30"
            ),
        ]
        var identities: [(entryID: UUID, pid: pid_t, pgid: pid_t)] = []
        defer {
            identities.forEach {
                cleanupRuntimeProcess(($0.pid, $0.pgid))
            }
        }

        let starts = await runtime.startAll(entries)
        XCTAssertEqual(starts.filter(\.isSuccess).count, 2)
        identities = try entries.map { entry in
            let process = runtime.runtime(for: entry.id).process
            return (
                entry.id,
                try XCTUnwrap(process.pid),
                try XCTUnwrap(process.processGroupID)
            )
        }
        let trapsReady = await waitUntilMainActor(timeout: .seconds(2)) {
            runtime.runtime(for: entries[0].id)
                .output.displayText.contains("TERM_READY_ONE")
                && runtime.runtime(for: entries[1].id)
                .output.displayText.contains("TERM_READY_TWO")
        }
        XCTAssertTrue(trapsReady)
        for identity in identities {
            let didExec = try await waitForExecutableName(
                pid: identity.pid,
                name: "sleep",
                timeout: .seconds(2)
            )
            XCTAssertTrue(didExec)
        }

        let result = await TerminationCoordinator(runtimeStore: runtime)
            .stopAllForTermination(timeout: .milliseconds(200))

        let expected = identities
            .map { RemainingProcess(entryID: $0.entryID, processGroupID: $0.pgid) }
            .sorted { $0.entryID.uuidString < $1.entryID.uuidString }
        XCTAssertEqual(
            result.remaining.sorted {
                $0.entryID.uuidString < $1.entryID.uuidString
            },
            expected
        )
        XCTAssertEqual(runtime.liveEntryIDs, Set(entries.map(\.id)))
    }

    func testTerminationIsSafeOnlyAfterEveryResponsiveGroupDisappears() async throws {
        let runtime = RuntimeStore(supervisor: ProcessSupervisor())
        let entries = [
            fixtureEntry(name: "One", command: "exec sleep 30"),
            fixtureEntry(name: "Two", command: "exec sleep 30"),
        ]
        var identities: [(pid: pid_t, pgid: pid_t)] = []
        defer { identities.forEach(cleanupRuntimeProcess) }

        let starts = await runtime.startAll(entries)
        XCTAssertEqual(starts.filter(\.isSuccess).count, 2)
        identities = try entries.map {
            let process = runtime.runtime(for: $0.id).process
            return (
                try XCTUnwrap(process.pid),
                try XCTUnwrap(process.processGroupID)
            )
        }
        for identity in identities {
            let didExec = try await waitForExecutableName(
                pid: identity.pid,
                name: "sleep",
                timeout: .seconds(2)
            )
            XCTAssertTrue(didExec)
        }

        let result = await TerminationCoordinator(runtimeStore: runtime)
            .stopAllForTermination(timeout: .seconds(2))

        XCTAssertEqual(result, .safeToTerminate)
        XCTAssertTrue(runtime.liveEntryIDs.isEmpty)
        for identity in identities {
            XCTAssertFalse(
                try ProcessLauncher.processGroupExists(identity.pgid)
            )
        }
    }
}

private func stoppedSnapshot(
    entryID: UUID,
    exitResult: ChildWaitResult?
) -> ProcessSnapshot {
    ProcessSnapshot(
        entryID: entryID,
        pid: nil,
        processGroupID: nil,
        liveness: .stopped,
        launchedAt: .distantPast,
        exitResult: exitResult
    )
}

private func fixtureEntry(
    id: UUID = UUID(),
    name: String,
    cwd: String = "/tmp",
    command: String,
    keywords: [String] = []
) -> CommandEntry {
    CommandEntry(
        id: id,
        name: name,
        cwd: cwd,
        command: command,
        keywords: keywords,
        order: 0
    )
}

@MainActor
private func waitUntilMainActor(
    timeout: Duration,
    condition: () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while clock.now < deadline {
        if condition() {
            return true
        }
        try? await clock.sleep(for: .milliseconds(10))
    }
    return condition()
}

private func occurrences(of needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
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

private func cleanupRuntimeProcess(
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

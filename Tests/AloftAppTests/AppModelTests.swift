import AppKit
import Foundation
import XCTest
@testable import AloftApp

@MainActor
final class AppModelTests: XCTestCase {
    func testInitialSelectionUsesFirstOrderedGroupAndEntry() throws {
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [
                ("Frontend", ["One", "Two"]),
                ("Backend", ["API"]),
            ]
        )

        XCTAssertEqual(
            fixture.model.selectedGroupID,
            fixture.model.workspace.configuration.groups[0].id
        )
        XCTAssertEqual(
            fixture.model.selectedEntryID,
            fixture.model.workspace.configuration.groups[0].entries[0].id
        )
    }

    func testDeletingEntryDisposesItsTerminalAfterWorkspaceDeletion() throws {
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [("Frontend", ["One"])]
        )
        let group = try XCTUnwrap(
            fixture.model.workspace.configuration.groups.first
        )
        let entry = try XCTUnwrap(group.entries.first)
        let surface = TerminalSurfaceStub(nativeView: NSView())
        fixture.model.runtime.runtime(for: entry.id).terminalSurface =
            surface

        try fixture.model.deleteEntry(id: entry.id, in: group.id)

        XCTAssertEqual(surface.disposeCount, 1)
        XCTAssertNil(fixture.model.runtime.runtimes[entry.id])
    }

    func testDeletingGroupDisposesEveryEntryTerminal() throws {
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [
                ("Frontend", ["One", "Two"])
            ]
        )
        let group = try XCTUnwrap(
            fixture.model.workspace.configuration.groups.first
        )
        let surfaces = group.entries.map { entry in
            let surface = TerminalSurfaceStub(nativeView: NSView())
            fixture.model.runtime.runtime(for: entry.id).terminalSurface =
                surface
            return surface
        }

        try fixture.model.deleteGroup(id: group.id)

        XCTAssertEqual(surfaces.map(\.disposeCount), [1, 1])
        XCTAssertTrue(
            group.entries.allSatisfy {
                fixture.model.runtime.runtimes[$0.id] == nil
            }
        )
    }

    func testFailedWorkspaceDeletionDoesNotDisposeTerminal() throws {
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [("Frontend", ["One"])]
        )
        let group = try XCTUnwrap(
            fixture.model.workspace.configuration.groups.first
        )
        let entry = try XCTUnwrap(group.entries.first)
        let surface = TerminalSurfaceStub(nativeView: NSView())
        fixture.model.runtime.runtime(for: entry.id).terminalSurface =
            surface

        try FileManager.default.removeItem(at: fixture.directory)
        try Data("not-a-directory".utf8).write(
            to: fixture.directory
        )

        XCTAssertThrowsError(
            try fixture.model.deleteEntry(
                id: entry.id,
                in: group.id
            )
        )
        XCTAssertEqual(surface.disposeCount, 0)
        XCTAssertNotNil(fixture.model.entry(id: entry.id))
        XCTAssertIdentical(
            fixture.model.runtime.runtimes[entry.id]?.terminalSurface,
            surface
        )
    }

    func testRuntimeRemovalRejectsLiveAndProtectedEntries() {
        let runtime = RuntimeStore(supervisor: ProcessSupervisor())
        let liveID = UUID()
        let protectedID = UUID()
        let liveSurface = TerminalSurfaceStub(nativeView: NSView())
        let protectedSurface = TerminalSurfaceStub(nativeView: NSView())
        let liveRuntime = runtime.runtime(for: liveID)
        liveRuntime.process = runningSnapshot(
            entryID: liveID,
            pid: 801
        )
        liveRuntime.terminalSurface = liveSurface
        runtime.runtime(for: protectedID).terminalSurface =
            protectedSurface
        _ = runtime.reserveOperations(entryIDs: [protectedID])

        XCTAssertThrowsError(
            try runtime.removeEntry(entryID: liveID)
        ) {
            XCTAssertEqual(
                $0 as? RuntimeStoreError,
                .entryRemovalProtected(liveID)
            )
        }
        XCTAssertThrowsError(
            try runtime.removeEntry(entryID: protectedID)
        ) {
            XCTAssertEqual(
                $0 as? RuntimeStoreError,
                .entryRemovalProtected(protectedID)
            )
        }
        XCTAssertEqual(liveSurface.disposeCount, 0)
        XCTAssertEqual(protectedSurface.disposeCount, 0)
        XCTAssertNotNil(runtime.runtimes[liveID])
        XCTAssertNotNil(runtime.runtimes[protectedID])
    }

    func testDisposeAllTerminalSurfacesIsIdempotent() {
        let runtime = RuntimeStore(supervisor: ProcessSupervisor())
        let surface = TerminalSurfaceStub(nativeView: NSView())
        runtime.runtime(for: UUID()).terminalSurface = surface

        runtime.disposeAllTerminalSurfaces()
        runtime.disposeAllTerminalSurfaces()

        XCTAssertEqual(surface.disposeCount, 1)
        XCTAssertTrue(
            runtime.runtimes.values.allSatisfy {
                $0.terminalSurface == nil
            }
        )
    }

    func testDeletingSelectedEntrySelectsNextEntryInSameGroup() throws {
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [("Frontend", ["One", "Two"])]
        )
        let group = try XCTUnwrap(
            fixture.model.workspace.configuration.groups.first
        )
        let firstID = group.entries[0].id
        let secondID = group.entries[1].id
        fixture.model.selectedGroupID = group.id
        fixture.model.selectedEntryID = firstID

        try fixture.model.deleteEntry(id: firstID, in: group.id)

        XCTAssertEqual(fixture.model.selectedGroupID, group.id)
        XCTAssertEqual(fixture.model.selectedEntryID, secondID)
    }

    func testDeletingLastSelectedEntrySelectsPreviousEntry() throws {
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [("Frontend", ["One", "Two"])]
        )
        let group = try XCTUnwrap(
            fixture.model.workspace.configuration.groups.first
        )
        fixture.model.selectedGroupID = group.id
        fixture.model.selectedEntryID = group.entries[1].id

        try fixture.model.deleteEntry(
            id: group.entries[1].id,
            in: group.id
        )

        XCTAssertEqual(
            fixture.model.selectedEntryID,
            group.entries[0].id
        )
    }

    func testDeletingMiddleSelectedEntrySelectsNextEntry() throws {
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [
                ("Frontend", ["One", "Two", "Three"])
            ]
        )
        let group = try XCTUnwrap(
            fixture.model.workspace.configuration.groups.first
        )
        fixture.model.selectEntry(group.entries[1].id)

        try fixture.model.deleteEntry(
            id: group.entries[1].id,
            in: group.id
        )

        XCTAssertEqual(
            fixture.model.selectedEntryID,
            group.entries[2].id
        )
    }

    func testDeletingSelectedGroupSelectsNextGroupAndItsFirstEntry() throws {
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [
                ("Frontend", ["Web"]),
                ("Backend", ["API"]),
            ]
        )
        let groups = fixture.model.workspace.configuration.groups
        fixture.model.selectedGroupID = groups[0].id
        fixture.model.selectedEntryID = groups[0].entries[0].id

        try fixture.model.deleteGroup(id: groups[0].id)

        XCTAssertEqual(fixture.model.selectedGroupID, groups[1].id)
        XCTAssertEqual(
            fixture.model.selectedEntryID,
            groups[1].entries[0].id
        )
    }

    func testDeletingMiddleSelectedGroupSelectsNextGroup() throws {
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [
                ("One", ["A"]),
                ("Two", ["B", "C"]),
                ("Three", ["C"]),
            ]
        )
        let groups = fixture.model.workspace.configuration.groups
        fixture.model.selectEntry(groups[1].entries[0].id)

        try fixture.model.deleteGroup(id: groups[1].id)

        XCTAssertEqual(fixture.model.selectedGroupID, groups[2].id)
        XCTAssertEqual(
            fixture.model.selectedEntryID,
            groups[2].entries[0].id
        )
    }

    func testDeletingLastSelectedGroupSelectsPreviousGroup() throws {
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [
                ("One", ["A"]),
                ("Two", ["B"]),
                ("Three", ["C"]),
            ]
        )
        let groups = fixture.model.workspace.configuration.groups
        fixture.model.selectEntry(groups[2].entries[0].id)

        try fixture.model.deleteGroup(id: groups[2].id)

        XCTAssertEqual(fixture.model.selectedGroupID, groups[1].id)
        XCTAssertEqual(
            fixture.model.selectedEntryID,
            groups[1].entries[0].id
        )
    }

    func testRepairSelectionLetsValidEntryOverrideStaleGroup() throws {
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [
                ("One", ["A"]),
                ("Two", ["B"]),
            ]
        )
        let groups = fixture.model.workspace.configuration.groups
        fixture.model.selectedGroupID = UUID()
        fixture.model.selectedEntryID = groups[1].entries[0].id

        fixture.model.repairSelection()

        XCTAssertEqual(fixture.model.selectedGroupID, groups[1].id)
        XCTAssertEqual(
            fixture.model.selectedEntryID,
            groups[1].entries[0].id
        )
    }

    func testDeletingMismatchedSelectedGroupPreservesValidEntry() throws {
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [
                ("One", ["A"]),
                ("Two", ["B", "C"]),
            ]
        )
        let groups = fixture.model.workspace.configuration.groups
        fixture.model.selectedGroupID = groups[0].id
        fixture.model.selectedEntryID = groups[1].entries[1].id

        try fixture.model.deleteGroup(id: groups[0].id)

        XCTAssertEqual(fixture.model.selectedGroupID, groups[1].id)
        XCTAssertEqual(
            fixture.model.selectedEntryID,
            groups[1].entries[1].id
        )
    }

    func testRepairSelectionPreservesValidGroupForStaleEntry() throws {
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [
                ("One", ["A"]),
                ("Two", ["B", "C"]),
            ]
        )
        let groups = fixture.model.workspace.configuration.groups
        fixture.model.selectedGroupID = groups[1].id
        fixture.model.selectedEntryID = UUID()

        fixture.model.repairSelection()

        XCTAssertEqual(fixture.model.selectedGroupID, groups[1].id)
        XCTAssertEqual(
            fixture.model.selectedEntryID,
            groups[1].entries[0].id
        )
    }

    func testRepairSelectionPreservesSelectedEmptyGroup() throws {
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [
                ("One", ["A"]),
                ("Empty", []),
            ]
        )
        let groups = fixture.model.workspace.configuration.groups
        fixture.model.selectedGroupID = groups[1].id
        fixture.model.selectedEntryID = UUID()

        fixture.model.repairSelection()

        XCTAssertEqual(fixture.model.selectedGroupID, groups[1].id)
        XCTAssertNil(fixture.model.selectedEntryID)
    }

    func testReorderingPreservesStableIDSelection() throws {
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [
                ("Frontend", ["One", "Two"]),
                ("Backend", ["API"]),
            ]
        )
        let groups = fixture.model.workspace.configuration.groups
        let selectedEntryID = groups[0].entries[1].id
        fixture.model.selectEntry(selectedEntryID)

        try fixture.model.moveEntries(
            in: groups[0].id,
            fromOffsets: IndexSet(integer: 1),
            toOffset: 0
        )
        try fixture.model.moveGroups(
            fromOffsets: IndexSet(integer: 0),
            toOffset: 2
        )

        XCTAssertEqual(fixture.model.selectedGroupID, groups[0].id)
        XCTAssertEqual(fixture.model.selectedEntryID, selectedEntryID)
    }

    func testLatestMatchSelectionTargetsItsEntryAndGroup() throws {
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [("Frontend", ["One", "Two"])]
        )
        let group = try XCTUnwrap(
            fixture.model.workspace.configuration.groups.first
        )
        let target = group.entries[1]

        fixture.model.selectEntry(target.id)

        XCTAssertEqual(fixture.model.selectedGroupID, group.id)
        XCTAssertEqual(fixture.model.selectedEntryID, target.id)
    }

    func testScheduledStartProtectsEntryBeforeTaskCanRun() async throws {
        let fake = ModelProcessClient()
        let gate = ModelTestGate()
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [("Frontend", ["One"])],
            runtime: await makeRuntime(fake)
        )
        let group = try XCTUnwrap(
            fixture.model.workspace.configuration.groups.first
        )
        let entry = try XCTUnwrap(group.entries.first)
        await fake.enqueueStart(
            runningSnapshot(entryID: entry.id, pid: 701),
            gate: gate
        )

        let task = try XCTUnwrap(
            fixture.model.startEntry(id: entry.id)
        )

        XCTAssertEqual(
            fixture.model.runtime.protectionCount(for: entry.id),
            1
        )
        XCTAssertThrowsError(
            try fixture.model.deleteEntry(id: entry.id, in: group.id)
        )
        XCTAssertEqual(
            fixture.model.workspace.configuration.groups[0].entries
                .map(\.id),
            [entry.id]
        )

        await gate.open()
        let result = await task.value

        XCTAssertTrue(result.isSuccess)
        XCTAssertTrue(
            fixture.model.runtime.protectedEntryIDs.isEmpty
        )
        XCTAssertTrue(
            fixture.model.runtime.liveEntryIDs.contains(entry.id)
        )
        XCTAssertNotNil(fixture.model.entry(id: entry.id))
    }

    func testOverlappingScheduledStartsUseReferenceCountedProtection() async throws {
        let fake = ModelProcessClient()
        let gate = ModelTestGate()
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [("Frontend", ["One"])],
            runtime: await makeRuntime(fake)
        )
        let entry = try XCTUnwrap(
            fixture.model.workspace.configuration.groups[0].entries.first
        )
        await fake.enqueueStart(
            runningSnapshot(entryID: entry.id, pid: 702),
            gate: gate
        )

        let first = try XCTUnwrap(
            fixture.model.startEntry(id: entry.id)
        )
        let second = try XCTUnwrap(
            fixture.model.startEntry(id: entry.id)
        )

        XCTAssertEqual(
            fixture.model.runtime.protectionCount(for: entry.id),
            2
        )
        await gate.open()
        _ = await first.value
        _ = await second.value
        XCTAssertEqual(
            fixture.model.runtime.protectionCount(for: entry.id),
            0
        )
    }

    func testScheduledStartAllProtectsWholeGroupImmediately() async throws {
        let fake = ModelProcessClient()
        let gate = ModelTestGate()
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [
                ("Frontend", ["One", "Two"])
            ],
            runtime: await makeRuntime(fake)
        )
        let group = fixture.model.workspace.configuration.groups[0]
        for (index, entry) in group.entries.enumerated() {
            await fake.enqueueStart(
                runningSnapshot(
                    entryID: entry.id,
                    pid: pid_t(710 + index)
                ),
                gate: index == 0 ? gate : nil
            )
        }

        let task = try XCTUnwrap(
            fixture.model.startGroup(id: group.id)
        )

        XCTAssertEqual(
            fixture.model.runtime.protectedEntryIDs,
            Set(group.entries.map(\.id))
        )
        XCTAssertThrowsError(
            try fixture.model.deleteGroup(id: group.id)
        )

        await gate.open()
        let results = await task.value
        XCTAssertEqual(results.filter(\.isSuccess).count, 2)
        XCTAssertTrue(
            fixture.model.runtime.protectedEntryIDs.isEmpty
        )
    }

    func testStartGroupSkipsEntriesThatAreAlreadyRunning() async throws {
        let fake = ModelProcessClient()
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [
                ("Frontend", ["Running", "Stopped"])
            ],
            runtime: await makeRuntime(fake)
        )
        let group = fixture.model.workspace.configuration.groups[0]
        let runningEntry = group.entries[0]
        let stoppedEntry = group.entries[1]
        await fake.enqueueStart(
            runningSnapshot(entryID: runningEntry.id, pid: 715),
            gate: nil
        )
        let initialStart = await fixture.model.runtime.start(
            runningEntry
        )
        XCTAssertTrue(initialStart.isSuccess)
        await fake.enqueueStart(
            runningSnapshot(entryID: stoppedEntry.id, pid: 716),
            gate: nil
        )

        let task = try XCTUnwrap(
            fixture.model.startGroup(id: group.id)
        )

        XCTAssertEqual(
            fixture.model.runtime.protectedEntryIDs,
            [stoppedEntry.id]
        )
        let results = await task.value
        XCTAssertEqual(results.map(\.entryID), [stoppedEntry.id])
        XCTAssertTrue(results.allSatisfy(\.isSuccess))
        let startCallCount = await fake.startCallCount
        XCTAssertEqual(startCallCount, 2)
        XCTAssertEqual(
            fixture.model.runtime.liveEntryIDs,
            Set(group.entries.map(\.id))
        )
    }

    func testScheduledRestartProtectsStoppedGapBeforeReplacementStarts() async throws {
        let fake = ModelProcessClient()
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [("Frontend", ["One"])],
            runtime: await makeRuntime(fake)
        )
        let group = fixture.model.workspace.configuration.groups[0]
        let entry = group.entries[0]
        await fake.enqueueStart(
            runningSnapshot(entryID: entry.id, pid: 720),
            gate: nil
        )
        let initialStart = await fixture.model.runtime.start(entry)
        XCTAssertTrue(initialStart.isSuccess)

        let replacementGate = ModelTestGate()
        await fake.enqueueStart(
            runningSnapshot(entryID: entry.id, pid: 721),
            gate: replacementGate
        )
        let task = try XCTUnwrap(
            fixture.model.restartEntry(id: entry.id)
        )
        let replacementEntered = await waitUntilModelTest {
            await fake.startCallCount == 2
        }
        XCTAssertTrue(replacementEntered)
        XCTAssertFalse(
            fixture.model.runtime.liveEntryIDs.contains(entry.id)
        )
        XCTAssertTrue(
            fixture.model.runtime.protectedEntryIDs.contains(entry.id)
        )
        XCTAssertThrowsError(
            try fixture.model.deleteEntry(id: entry.id, in: group.id)
        )

        await replacementGate.open()
        let restartResult = await task.value
        XCTAssertTrue(restartResult.isSuccess)
        XCTAssertFalse(
            fixture.model.runtime.protectedEntryIDs.contains(entry.id)
        )
        XCTAssertTrue(
            fixture.model.runtime.liveEntryIDs.contains(entry.id)
        )
    }

    func testScheduledStartProtectionClearsAfterError() async throws {
        let fake = ModelProcessClient()
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [("Frontend", ["One"])],
            runtime: await makeRuntime(fake)
        )
        let group = fixture.model.workspace.configuration.groups[0]
        let entry = group.entries[0]

        let task = try XCTUnwrap(
            fixture.model.startEntry(id: entry.id)
        )
        XCTAssertTrue(
            fixture.model.runtime.protectedEntryIDs.contains(entry.id)
        )
        let result = await task.value
        XCTAssertFalse(result.isSuccess)
        XCTAssertFalse(
            fixture.model.runtime.protectedEntryIDs.contains(entry.id)
        )
        XCTAssertNoThrow(
            try fixture.model.deleteEntry(id: entry.id, in: group.id)
        )
    }

    func testScheduledStartProtectionClearsAfterCancellation() async throws {
        let fake = ModelProcessClient()
        let gate = ModelTestGate()
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [("Frontend", ["One"])],
            runtime: await makeRuntime(fake)
        )
        let group = fixture.model.workspace.configuration.groups[0]
        let entry = group.entries[0]
        await fake.enqueueStart(
            runningSnapshot(entryID: entry.id, pid: 730),
            gate: gate
        )

        let task = try XCTUnwrap(
            fixture.model.startEntry(id: entry.id)
        )
        let entered = await waitUntilModelTest {
            await fake.startCallCount == 1
        }
        XCTAssertTrue(entered)
        task.cancel()
        await gate.open()
        let result = await task.value
        XCTAssertFalse(result.isSuccess)

        XCTAssertFalse(
            fixture.model.runtime.protectedEntryIDs.contains(entry.id)
        )
        XCTAssertFalse(
            fixture.model.runtime.liveEntryIDs.contains(entry.id)
        )
        XCTAssertNoThrow(
            try fixture.model.deleteEntry(id: entry.id, in: group.id)
        )
    }

    func testScheduledActionReresolvesStableIDFromWorkspace() async throws {
        let fake = ModelProcessClient()
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [("Frontend", ["One"])],
            runtime: await makeRuntime(fake)
        )
        let group = fixture.model.workspace.configuration.groups[0]
        let entryID = group.entries[0].id
        try fixture.model.deleteEntry(id: entryID, in: group.id)

        let task = fixture.model.startEntry(id: entryID)

        XCTAssertNil(task)
        XCTAssertTrue(
            fixture.model.runtime.protectedEntryIDs.isEmpty
        )
        let startCallCount = await fake.startCallCount
        XCTAssertEqual(startCallCount, 0)
    }

    func testFailedStopPublishesOneAttention() async throws {
        let fake = ModelProcessClient()
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [("Frontend", ["One"])],
            runtime: await makeRuntime(fake)
        )
        let entry = fixture.model.workspace.configuration
            .groups[0].entries[0]
        let running = runningSnapshot(entryID: entry.id, pid: 740)
        await fake.enqueueStart(running, gate: nil)
        let start = await fixture.model.runtime.start(entry)
        XCTAssertTrue(start.isSuccess)
        await fake.setStopResult(.timedOut(running), for: entry.id)

        let task = try XCTUnwrap(
            fixture.model.stopEntry(id: entry.id)
        )
        let result = await task.value

        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(
            fixture.model.runtime.unacknowledgedAttentionItems.count,
            1
        )
        XCTAssertEqual(
            fixture.model.runtime.unacknowledgedAttentionItems.first?
                .entryID,
            entry.id
        )
    }

    func testFailedRestartPublishesOneAttention() async throws {
        let fake = ModelProcessClient()
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [("Frontend", ["One"])],
            runtime: await makeRuntime(fake)
        )
        let entry = fixture.model.workspace.configuration
            .groups[0].entries[0]
        let running = runningSnapshot(entryID: entry.id, pid: 741)
        await fake.enqueueStart(running, gate: nil)
        let start = await fixture.model.runtime.start(entry)
        XCTAssertTrue(start.isSuccess)
        await fake.setStopResult(.timedOut(running), for: entry.id)

        let task = try XCTUnwrap(
            fixture.model.restartEntry(id: entry.id)
        )
        let result = await task.value

        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(
            fixture.model.runtime.unacknowledgedAttentionItems.count,
            1
        )
        XCTAssertEqual(
            fixture.model.runtime.unacknowledgedAttentionItems.first?
                .kind,
            .operationFailure
        )
    }

    func testGroupStopPublishesOneAggregatedAttention() async throws {
        let fake = ModelProcessClient()
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [
                ("Frontend", ["One", "Two"]),
            ],
            runtime: await makeRuntime(fake)
        )
        let group = fixture.model.workspace.configuration.groups[0]
        for (index, entry) in group.entries.enumerated() {
            let running = runningSnapshot(
                entryID: entry.id,
                pid: pid_t(750 + index)
            )
            await fake.enqueueStart(running, gate: nil)
            let start = await fixture.model.runtime.start(entry)
            XCTAssertTrue(start.isSuccess)
            await fake.setStopResult(
                .timedOut(running),
                for: entry.id
            )
        }

        let task = try XCTUnwrap(
            fixture.model.stopGroup(id: group.id)
        )
        let results = await task.value

        XCTAssertEqual(results.filter { !$0.isSuccess }.count, 2)
        XCTAssertEqual(
            fixture.model.runtime.unacknowledgedAttentionItems.count,
            1
        )
        let item = try XCTUnwrap(
            fixture.model.runtime.unacknowledgedAttentionItems.first
        )
        XCTAssertNil(item.entryID)
        XCTAssertTrue(item.detail.contains("One"))
        XCTAssertTrue(item.detail.contains("Two"))
    }

    func testGroupRestartPublishesOneAggregatedAttention() async throws {
        let fake = ModelProcessClient()
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [
                ("Frontend", ["One", "Two"]),
            ],
            runtime: await makeRuntime(fake)
        )
        let group = fixture.model.workspace.configuration.groups[0]
        for (index, entry) in group.entries.enumerated() {
            let running = runningSnapshot(
                entryID: entry.id,
                pid: pid_t(760 + index)
            )
            await fake.enqueueStart(running, gate: nil)
            let start = await fixture.model.runtime.start(entry)
            XCTAssertTrue(start.isSuccess)
            await fake.setStopResult(
                .timedOut(running),
                for: entry.id
            )
        }

        let task = try XCTUnwrap(
            fixture.model.restartGroup(id: group.id)
        )
        let results = await task.value

        XCTAssertEqual(results.filter { !$0.isSuccess }.count, 2)
        XCTAssertEqual(
            fixture.model.runtime.unacknowledgedAttentionItems.count,
            1
        )
        let item = try XCTUnwrap(
            fixture.model.runtime.unacknowledgedAttentionItems.first
        )
        XCTAssertEqual(item.kind, .operationFailure)
        XCTAssertNil(item.entryID)
        XCTAssertEqual(item.relatedEntryIDs, Set(group.entries.map(\.id)))
        XCTAssertTrue(item.detail.contains("One"))
        XCTAssertTrue(item.detail.contains("Two"))
    }

    func testMalformedBootstrapDoesNotOverwriteConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let malformed = Data("{ not-json".utf8)
        try malformed.write(to: url)

        let model = AppModel.bootstrap(configurationURL: url)

        XCTAssertEqual(model.workspace.configuration, .empty)
        XCTAssertNotNil(model.presentedError)
        XCTAssertEqual(try Data(contentsOf: url), malformed)
    }

}

@MainActor
private func makeAppModel(
    groupNamesAndEntryNames: [(String, [String])],
    runtime: RuntimeStore? = nil
) throws -> (model: AppModel, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let url = directory.appendingPathComponent("config.json")
    let workspace = try WorkspaceStore(
        repository: ConfigurationRepository(fileURL: url)
    )
    for (groupName, entryNames) in groupNamesAndEntryNames {
        let groupID = try workspace.addGroup(name: groupName)
        for entryName in entryNames {
            _ = try workspace.addEntry(
                to: groupID,
                name: entryName,
                cwd: "/tmp",
                command: "echo \(entryName)",
                keywords: []
            )
        }
    }
    return (
        AppModel(
            workspace: workspace,
            runtime: runtime
                ?? RuntimeStore(supervisor: ProcessSupervisor()),
            ghostty: GhosttyService()
        ),
        directory
    )
}

private actor ModelProcessClient {
    private struct QueuedStart {
        let snapshot: ProcessSnapshot
        let gate: ModelTestGate?
    }

    private var queuedStarts: [QueuedStart] = []
    private var records: [UUID: ProcessSnapshot] = [:]
    private var stopResults: [UUID: StopResult] = [:]
    private(set) var startCallCount = 0

    func enqueueStart(
        _ snapshot: ProcessSnapshot,
        gate: ModelTestGate?
    ) {
        queuedStarts.append(
            QueuedStart(snapshot: snapshot, gate: gate)
        )
    }

    func setStopResult(
        _ result: StopResult,
        for entryID: UUID
    ) {
        stopResults[entryID] = result
    }

    func client() -> RuntimeProcessClient {
        RuntimeProcessClient(
            start: { entry, _, _ in
                try await self.start(entryID: entry.id)
            },
            write: { _, _, _ in
                throw ProcessSupervisorError.unknownEntry
            },
            resize: { _, _, _ in
                throw ProcessSupervisorError.unknownEntry
            },
            stop: { entryID, _ in
                try await self.stop(entryID: entryID)
            },
            refresh: { entryID in
                try await self.refresh(entryID: entryID)
            },
            snapshots: {
                await self.records
            }
        )
    }

    private func start(entryID: UUID) async throws -> ProcessSnapshot {
        startCallCount += 1
        guard let index = queuedStarts.firstIndex(
            where: { $0.snapshot.entryID == entryID }
        ) else {
            throw ProcessSupervisorError.unknownEntry
        }
        let queued = queuedStarts.remove(at: index)
        if let gate = queued.gate {
            await gate.wait()
        }
        try Task.checkCancellation()
        records[entryID] = queued.snapshot
        return queued.snapshot
    }

    private func stop(entryID: UUID) throws -> StopResult {
        guard records[entryID] != nil else {
            throw ProcessSupervisorError.unknownEntry
        }
        if let result = stopResults[entryID] {
            return result
        }
        records[entryID] = stoppedModelSnapshot(entryID: entryID)
        return .stopped
    }

    private func refresh(entryID: UUID) throws -> ProcessSnapshot {
        guard let snapshot = records[entryID] else {
            throw ProcessSupervisorError.unknownEntry
        }
        return snapshot
    }
}

private actor ModelTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

@MainActor
private func makeRuntime(
    _ fake: ModelProcessClient
) async -> RuntimeStore {
    RuntimeStore(
        supervisor: ProcessSupervisor(),
        processClient: await fake.client()
    )
}

private func runningSnapshot(
    entryID: UUID,
    pid: pid_t
) -> ProcessSnapshot {
    ProcessSnapshot(
        entryID: entryID,
        pid: pid,
        processGroupID: pid,
        liveness: .running,
        launchedAt: Date(timeIntervalSince1970: TimeInterval(pid)),
        exitResult: nil
    )
}

private func stoppedModelSnapshot(
    entryID: UUID
) -> ProcessSnapshot {
    ProcessSnapshot(
        entryID: entryID,
        pid: nil,
        processGroupID: nil,
        liveness: .stopped,
        launchedAt: nil,
        exitResult: nil
    )
}

@MainActor
private func waitUntilModelTest(
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

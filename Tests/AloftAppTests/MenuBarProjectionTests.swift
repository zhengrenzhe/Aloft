import AppKit
import XCTest
@testable import AloftApp

final class MenuBarProjectionTests: XCTestCase {
    func testProjectionShowsOnlyLiveEntriesAndTruncatesMatchToThirtyCharacters() {
        let liveEntryID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000011"
        )!
        let stoppedEntryID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000012"
        )!
        let groups = [
            fixtureGroup(
                id: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000001"
                )!,
                name: "Development",
                order: 0,
                entries: [
                    fixtureEntry(
                        id: stoppedEntryID,
                        name: "Stopped",
                        order: 0
                    ),
                    fixtureEntry(
                        id: liveEntryID,
                        name: "Live",
                        order: 1
                    ),
                ]
            ),
        ]
        let line = String(repeating: "👩🏽‍💻", count: 30) + "EXTRA"

        let projection = MenuBarProjection(
            groups: groups,
            liveEntryIDs: [liveEntryID],
            latestMatch: KeywordMatchEvent(
                entryID: liveEntryID,
                keyword: "ready",
                line: line,
                timestamp: .distantPast
            )
        )

        XCTAssertEqual(projection.runningCount, 1)
        XCTAssertEqual(projection.latestMatch?.title.count, 30)
        XCTAssertEqual(
            projection.groupMenus.flatMap(\.liveEntries).map(\.id),
            [liveEntryID]
        )
        XCTAssertEqual(
            projection.latestMatch?.title,
            String(repeating: "👩🏽‍💻", count: 30)
        )
    }

    func testProjectionSortsPersistedOrderAndKeepsStoppedGroups() {
        let firstGroupID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"
        )!
        let secondGroupID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000002"
        )!
        let laterEntryID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000011"
        )!
        let earlierEntryID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000012"
        )!
        let groups = [
            fixtureGroup(
                id: secondGroupID,
                name: "Stopped",
                order: 1,
                entries: []
            ),
            fixtureGroup(
                id: firstGroupID,
                name: "Live",
                order: 0,
                entries: [
                    fixtureEntry(
                        id: laterEntryID,
                        name: "Later",
                        order: 1
                    ),
                    fixtureEntry(
                        id: earlierEntryID,
                        name: "Earlier",
                        order: 0
                    ),
                ]
            ),
        ]

        let projection = MenuBarProjection(
            groups: groups,
            liveEntryIDs: [laterEntryID, earlierEntryID],
            latestMatch: nil
        )

        XCTAssertEqual(
            projection.groupMenus.map(\.id),
            [firstGroupID, secondGroupID]
        )
        XCTAssertEqual(
            projection.groupMenus[0].liveEntries.map(\.id),
            [earlierEntryID, laterEntryID]
        )
        XCTAssertEqual(projection.groupMenus[1].liveEntries, [])
    }

    func testEverySourceDerivedMenuTitleIsAtMostThirtyCharacters() {
        let entryID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000011"
        )!
        let group = fixtureGroup(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000001"
            )!,
            name: String(repeating: "组", count: 40),
            order: 0,
            entries: [
                fixtureEntry(
                    id: entryID,
                    name: String(repeating: "👨‍👩‍👧‍👦", count: 40),
                    order: 0
                ),
            ]
        )

        let projection = MenuBarProjection(
            groups: [group],
            liveEntryIDs: [entryID],
            latestMatch: KeywordMatchEvent(
                entryID: entryID,
                keyword: "ready",
                line: String(repeating: "e\u{301}", count: 40),
                timestamp: .distantPast
            )
        )

        XCTAssertLessThanOrEqual(
            projection.groupMenus[0].title.count,
            30
        )
        XCTAssertLessThanOrEqual(
            projection.groupMenus[0].liveEntries[0].title.count,
            30
        )
        XCTAssertEqual(projection.latestMatch?.title.count, 30)
    }

    func testProjectionHidesMatchForUnknownEntryID() {
        let configuredEntry = fixtureEntry(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000011"
            )!,
            name: "Configured",
            order: 0
        )
        let group = fixtureGroup(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000001"
            )!,
            name: "Commands",
            order: 0,
            entries: [configuredEntry]
        )
        let unknownEntryID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000099"
        )!

        let projection = MenuBarProjection(
            groups: [group],
            liveEntryIDs: [],
            latestMatch: KeywordMatchEvent(
                entryID: unknownEntryID,
                keyword: "ready",
                line: "STALE READY",
                timestamp: .distantPast
            )
        )

        XCTAssertNil(projection.latestMatch)
    }

    func testProjectionKeepsMatchForConfiguredStoppedEntry() {
        let entryID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000011"
        )!
        let group = fixtureGroup(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000001"
            )!,
            name: "Commands",
            order: 0,
            entries: [
                fixtureEntry(
                    id: entryID,
                    name: "Stopped",
                    order: 0
                ),
            ]
        )

        let projection = MenuBarProjection(
            groups: [group],
            liveEntryIDs: [],
            latestMatch: KeywordMatchEvent(
                entryID: entryID,
                keyword: "ready",
                line: "STOPPED READY",
                timestamp: .distantPast
            )
        )

        XCTAssertEqual(projection.latestMatch?.entryID, entryID)
        XCTAssertEqual(projection.latestMatch?.title, "STOPPED READY")
    }

    @MainActor
    func testProjectionHidesMatchAfterAppModelDeletesStoppedEntry() throws {
        let entry = terminationEntry(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000011"
            )!,
            name: "Deleted"
        )
        let model = terminationModel(entries: [entry])
        let groupID = try XCTUnwrap(model.orderedGroups.first?.id)
        try model.deleteEntry(id: entry.id, in: groupID)

        let projection = MenuBarProjection(
            groups: model.orderedGroups,
            liveEntryIDs: model.runtime.liveEntryIDs,
            latestMatch: KeywordMatchEvent(
                entryID: entry.id,
                keyword: "ready",
                line: "DELETED READY",
                timestamp: .distantPast
            )
        )

        XCTAssertNil(projection.latestMatch)
    }

    @MainActor
    func testProjectionHidesMatchAfterAppModelDeletesMatchedGroup() throws {
        let entry = terminationEntry(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000011"
            )!,
            name: "Deleted Group Entry"
        )
        let model = terminationModel(entries: [entry])
        let groupID = try XCTUnwrap(model.orderedGroups.first?.id)
        try model.deleteGroup(id: groupID)

        let projection = MenuBarProjection(
            groups: model.orderedGroups,
            liveEntryIDs: model.runtime.liveEntryIDs,
            latestMatch: KeywordMatchEvent(
                entryID: entry.id,
                keyword: "ready",
                line: "DELETED GROUP READY",
                timestamp: .distantPast
            )
        )

        XCTAssertNil(projection.latestMatch)
    }
}

final class ApplicationTerminationStateTests: XCTestCase {
    func testRequestWithoutManagedWorkTerminatesNow() {
        var state = ApplicationTerminationState()

        let disposition = state.request(
            liveEntryIDs: [],
            protectedEntryIDs: [],
            inFlightLaunchCount: 0
        )

        XCTAssertEqual(disposition, .terminateNow)
    }

    func testProtectedEntryStartsOneDeferredTermination() {
        let entryID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000011"
        )!
        var state = ApplicationTerminationState()

        let first = state.request(
            liveEntryIDs: [],
            protectedEntryIDs: [entryID],
            inFlightLaunchCount: 0
        )
        let duplicate = state.request(
            liveEntryIDs: [],
            protectedEntryIDs: [entryID],
            inFlightLaunchCount: 0
        )

        XCTAssertEqual(first, .beginDeferredTermination)
        XCTAssertEqual(duplicate, .awaitDeferredTermination)
    }

    func testInFlightLaunchDefersEvenWithoutProjectedOrProtectedEntry() {
        var state = ApplicationTerminationState()

        let disposition = state.request(
            liveEntryIDs: [],
            protectedEntryIDs: [],
            inFlightLaunchCount: 1
        )

        XCTAssertEqual(disposition, .beginDeferredTermination)
    }

    func testSafeCompletionProducesExactlyOneAffirmativeReply() {
        var state = ApplicationTerminationState()
        XCTAssertEqual(
            state.request(
                liveEntryIDs: [UUID()],
                protectedEntryIDs: [],
                inFlightLaunchCount: 0
            ),
            .beginDeferredTermination
        )

        let first = state.complete(
            result: .safeToTerminate,
            entryNames: [:]
        )
        let duplicate = state.complete(
            result: .safeToTerminate,
            entryNames: [:]
        )

        XCTAssertEqual(
            first,
            ApplicationTerminationCompletion(
                shouldTerminate: true,
                alert: nil
            )
        )
        XCTAssertNil(duplicate)
    }

    func testCancelledCompletionRepliesNoWithoutPresentingRemainingAlert() {
        var state = ApplicationTerminationState()
        _ = state.request(
            liveEntryIDs: [UUID()],
            protectedEntryIDs: [],
            inFlightLaunchCount: 0
        )

        let completion = state.complete(
            result: .cancelled,
            entryNames: [:]
        )

        XCTAssertEqual(
            completion,
            ApplicationTerminationCompletion(
                shouldTerminate: false,
                alert: nil
            )
        )
    }

    func testRemainingCompletionUsesNameThenStableIDFallbackAndRepliesNo() {
        let namedID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000011"
        )!
        let missingID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000012"
        )!
        var state = ApplicationTerminationState()
        _ = state.request(
            liveEntryIDs: [namedID, missingID],
            protectedEntryIDs: [],
            inFlightLaunchCount: 0
        )

        let completion = state.complete(
            result: .remaining([
                RemainingProcess(
                    entryID: missingID,
                    processGroupID: 902
                ),
                RemainingProcess(
                    entryID: namedID,
                    processGroupID: 901
                ),
            ]),
            entryNames: [namedID: "Development Server"]
        )

        XCTAssertEqual(completion?.shouldTerminate, false)
        XCTAssertEqual(
            completion?.alert,
            TerminationAlertPresentation(
                messageText: L10n.string(
                    "Aloft Could Not Stop All Commands"
                ),
                informativeText: """
                Development Server — PGID 901
                00000000-0000-0000-0000-000000000012 — PGID 902
                """
            )
        )
    }
}

@MainActor
final class AppDelegateTerminationTests: XCTestCase {
    func testNoManagedWorkTerminatesWithoutStartingCoordinator() {
        let model = terminationModel(entries: [])
        let surface = TerminalSurfaceStub(nativeView: NSView())
        model.runtime.runtime(for: UUID()).terminalSurface = surface
        var coordinatorCallCount = 0
        let delegate = AppDelegate(
            model: model,
            stopAllForTermination: {
                coordinatorCallCount += 1
                return .safeToTerminate
            },
            replyToTermination: { _ in
                XCTFail("Immediate termination must not send a deferred reply.")
            },
            presentTerminationAlert: { _ in
                XCTFail("Immediate termination must not present an alert.")
            }
        )

        let reply = delegate.applicationShouldTerminate(.shared)

        XCTAssertEqual(reply, .terminateNow)
        XCTAssertEqual(coordinatorCallCount, 0)
        XCTAssertEqual(surface.disposeCount, 1)
    }

    func testProtectedOnlyAndDuplicateRequestsRunOneCoordinatorAndReplyOnce() async {
        let entry = terminationEntry(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000011"
            )!,
            name: "Reserved"
        )
        let model = terminationModel(entries: [entry])
        _ = model.runtime.reserveOperations(entryIDs: [entry.id])
        let surface = TerminalSurfaceStub(nativeView: NSView())
        model.runtime.runtime(for: entry.id).terminalSurface = surface
        let gate = TerminationOperationGate()
        var replies: [Bool] = []
        var disposeCountsAtReply: [Int] = []
        var alerts: [TerminationAlertPresentation] = []
        let delegate = AppDelegate(
            model: model,
            stopAllForTermination: {
                await gate.run()
            },
            replyToTermination: {
                disposeCountsAtReply.append(surface.disposeCount)
                replies.append($0)
            },
            presentTerminationAlert: {
                alerts.append($0)
            }
        )

        let first = delegate.applicationShouldTerminate(.shared)
        let coordinatorEntered = await waitForTerminationTest {
            await gate.callCount == 1
        }
        XCTAssertTrue(coordinatorEntered)
        let duplicate = delegate.applicationShouldTerminate(.shared)
        await gate.finish(with: .safeToTerminate)
        let replied = await waitForTerminationTest {
            !replies.isEmpty
        }

        XCTAssertEqual(first, .terminateLater)
        XCTAssertEqual(duplicate, .terminateLater)
        XCTAssertTrue(replied)
        let coordinatorCallCount = await gate.callCount
        XCTAssertEqual(coordinatorCallCount, 1)
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(disposeCountsAtReply, [1])
        XCTAssertEqual(surface.disposeCount, 1)
        XCTAssertEqual(alerts, [])
    }

    func testCancelledTerminationPreservesTerminalSurfaces() async {
        let entry = terminationEntry(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000011"
            )!,
            name: "Reserved"
        )
        let model = terminationModel(entries: [entry])
        _ = model.runtime.reserveOperations(entryIDs: [entry.id])
        let surface = TerminalSurfaceStub(nativeView: NSView())
        model.runtime.runtime(for: entry.id).terminalSurface = surface
        var replies: [Bool] = []
        let delegate = AppDelegate(
            model: model,
            stopAllForTermination: { .cancelled },
            replyToTermination: { replies.append($0) }
        )

        XCTAssertEqual(
            delegate.applicationShouldTerminate(.shared),
            .terminateLater
        )
        let completed = await waitForTerminationTest {
            !replies.isEmpty
        }

        XCTAssertTrue(completed)
        XCTAssertEqual(replies, [false])
        XCTAssertEqual(surface.disposeCount, 0)
    }

    func testRemainingPresentsOneAlertBeforeNegativeReply() async {
        let namedEntry = terminationEntry(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000011"
            )!,
            name: "Development Server"
        )
        let missingID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000012"
        )!
        let model = terminationModel(entries: [namedEntry])
        _ = model.runtime.reserveOperations(
            entryIDs: [namedEntry.id, missingID]
        )
        let surface = TerminalSurfaceStub(nativeView: NSView())
        model.runtime.runtime(for: namedEntry.id).terminalSurface =
            surface
        var events: [String] = []
        var alerts: [TerminationAlertPresentation] = []
        let delegate = AppDelegate(
            model: model,
            stopAllForTermination: {
                .remaining([
                    RemainingProcess(
                        entryID: missingID,
                        processGroupID: 902
                    ),
                    RemainingProcess(
                        entryID: namedEntry.id,
                        processGroupID: 901
                    ),
                ])
            },
            replyToTermination: {
                events.append("reply:\($0)")
            },
            presentTerminationAlert: {
                alerts.append($0)
                events.append("alert")
            }
        )

        let reply = delegate.applicationShouldTerminate(.shared)
        let completed = await waitForTerminationTest {
            events.contains("reply:false")
        }

        XCTAssertEqual(reply, .terminateLater)
        XCTAssertTrue(completed)
        XCTAssertEqual(events, ["alert", "reply:false"])
        XCTAssertEqual(surface.disposeCount, 0)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(
            alerts[0].informativeText,
            """
            Development Server — PGID 901
            00000000-0000-0000-0000-000000000012 — PGID 902
            """
        )
    }
}

private func fixtureGroup(
    id: UUID,
    name: String,
    order: Int,
    entries: [CommandEntry]
) -> CommandGroup {
    CommandGroup(
        id: id,
        name: name,
        order: order,
        entries: entries
    )
}

@MainActor
private func terminationModel(entries: [CommandEntry]) -> AppModel {
    let group = CommandGroup(
        id: UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"
        )!,
        name: "Commands",
        order: 0,
        entries: entries
    )
    let repository = ConfigurationRepository(
        fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("config.json")
    )
    return AppModel(
        workspace: WorkspaceStore(
            repository: repository,
            initialConfiguration: WorkspaceConfiguration(groups: [group])
        ),
        runtime: RuntimeStore(supervisor: ProcessSupervisor()),
        ghostty: GhosttyService()
    )
}

private func terminationEntry(
    id: UUID,
    name: String
) -> CommandEntry {
    CommandEntry(
        id: id,
        name: name,
        cwd: "/tmp",
        command: "exec sleep 30",
        keywords: [],
        order: 0
    )
}

private actor TerminationOperationGate {
    private(set) var callCount = 0
    private var continuation:
        CheckedContinuation<TerminationResult, Never>?

    func run() async -> TerminationResult {
        callCount += 1
        return await withCheckedContinuation {
            continuation = $0
        }
    }

    func finish(with result: TerminationResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

@MainActor
private func waitForTerminationTest(
    _ condition: () async -> Bool
) async -> Bool {
    for _ in 0..<1_000 {
        if await condition() {
            return true
        }
        await Task.yield()
    }
    return false
}

private func fixtureEntry(
    id: UUID,
    name: String,
    order: Int
) -> CommandEntry {
    CommandEntry(
        id: id,
        name: name,
        cwd: "/tmp",
        command: "exec sleep 30",
        keywords: [],
        order: order
    )
}

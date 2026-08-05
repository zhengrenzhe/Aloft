import AppKit
import Darwin
import Foundation
import Observation
import XCTest
@testable import AloftApp

@MainActor
final class TerminalPTYIntegrationTests: XCTestCase {
    func testCursorPositionQueryReceivesSwiftTermProtocolReply()
        async throws {
        let harness = try TerminalPTYIntegrationHarness(
            shell: "/bin/zsh",
            command: """
            stty -echo
            printf '\\033[6n'
            IFS= read -r -d R reply
            stty echo
            printf 'ALOFT_DSR='
            printf '%sR' "$reply" | /usr/bin/od -An -tx1 | /usr/bin/tr -d ' \\n'
            printf '\\n'
            /bin/sleep 30
            """
        )
        defer { harness.forceStopForTestCleanup() }

        try await harness.start()

        let receivedReply = try await harness.waitForOutput(
            prefix: "ALOFT_DSR=1b5b",
            timeout: .seconds(2)
        )
        XCTAssertTrue(
            receivedReply,
            """
            text=\(harness.textOutput.debugDescription)
            terminal=\(harness.terminalText.debugDescription)
            callbacks=\(harness.terminalIOCompletionCount)
            errors=\(harness.completedTerminalIOErrors)
            """
        )
    }

    func testResizeUpdatesSttyAndDeliversWINCH() async throws {
        let harness = try TerminalPTYIntegrationHarness(
            shell: "/bin/zsh",
            command: """
            trap 'printf "WINCH=%s\\n" "$(stty size)"' WINCH
            printf 'READY\\n'
            while :; do /bin/sleep 1; done
            """
        )
        defer { harness.forceStopForTestCleanup() }
        try await harness.start()
        let receivedReady = try await harness.waitForOutput(
            containing: "READY",
            timeout: .seconds(2)
        )
        XCTAssertTrue(receivedReady)

        try await harness.resize(
            TerminalSize(
                columns: 121,
                rows: 41,
                pixelWidth: 1_210,
                pixelHeight: 820
            )!
        )

        let receivedResize = try await harness.waitForOutput(
            containing: "WINCH=41 121",
            timeout: .seconds(2)
        )
        XCTAssertTrue(receivedResize)
    }

    func testStopRejectsSubsequentProtocolReplyAndResize()
        async throws {
        let harness = try TerminalPTYIntegrationHarness(
            shell: "/bin/zsh",
            command: "printf 'READY\\n'; /bin/sleep 30"
        )
        defer { harness.forceStopForTestCleanup() }
        try await harness.start()
        let receivedReady = try await harness.waitForOutput(
            containing: "READY",
            timeout: .seconds(2)
        )
        XCTAssertTrue(receivedReady)
        let callbacks = try XCTUnwrap(harness.activeCallbacks)

        let stopResult = await harness.stop()
        XCTAssertTrue(stopResult.isSuccess)
        await harness.waitForTerminalIdle()
        XCTAssertEqual(harness.textOutput, "")
        XCTAssertEqual(
            harness.terminalText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            ""
        )
        callbacks.writeProtocolReply(
            Data("late".utf8),
            harness.generation
        )
        callbacks.resizePTY(
            TerminalSize(
                columns: 100,
                rows: 35,
                pixelWidth: 1_000,
                pixelHeight: 700
            )!,
            harness.generation
        )
        await Task.yield()

        XCTAssertEqual(harness.terminalIOCompletionCount, 0)
        XCTAssertTrue(harness.completedTerminalIOErrors.isEmpty)
        XCTAssertEqual(harness.runtime.process.liveness, .stopped)
        XCTAssertNil(harness.runtime.lastError)
        XCTAssertFalse(try harness.supervisorHasManagedProcess())
    }

    func testRestartPreservesTextAndTerminalHistoryWithOneSeparator()
        async throws {
        let harness = try TerminalPTYIntegrationHarness(
            shell: "/bin/zsh",
            command: "printf 'FIRST\\n'; /bin/sleep 30"
        )
        defer { harness.forceStopForTestCleanup() }
        try await harness.start()
        let receivedFirst = try await harness.waitForOutput(
            containing: "FIRST",
            timeout: .seconds(2)
        )
        XCTAssertTrue(receivedFirst)
        let separatorsBefore = sessionSeparatorCount(
            in: harness.textOutput
        )

        try await harness.restart(
            command: "printf 'SECOND\\n'; /bin/sleep 30"
        )
        let receivedSecond = try await harness.waitForOutput(
            containing: "SECOND",
            timeout: .seconds(2)
        )
        XCTAssertTrue(receivedSecond)

        let text = harness.textOutput
        let terminal = String(
            decoding:
                harness.swiftTermView.terminal.getBufferAsData(),
            as: UTF8.self
        )
        XCTAssertTrue(text.contains("FIRST"))
        XCTAssertTrue(text.contains("SECOND"))
        XCTAssertTrue(terminal.contains("FIRST"))
        XCTAssertTrue(terminal.contains("SECOND"))
        XCTAssertEqual(
            sessionSeparatorCount(in: text),
            separatorsBefore + 1
        )
    }

    func testRestartRestoresLiveViewportAfterScrollingHistory()
        async throws {
        let harness = try TerminalPTYIntegrationHarness(
            shell: "/bin/zsh",
            command: """
            i=0
            while [ "$i" -lt 120 ]; do
                printf 'HISTORY_%s\\n' "$i"
                i=$((i + 1))
            done
            printf 'FIRST\\n'
            /bin/sleep 30
            """
        )
        defer { harness.forceStopForTestCleanup() }
        try await harness.start()
        let receivedFirst = try await harness.waitForOutput(
            containing: "FIRST",
            timeout: .seconds(2)
        )
        XCTAssertTrue(receivedFirst)

        let view = harness.swiftTermView
        view.scroll(toPosition: 0)
        XCTAssertEqual(view.scrollPosition, 0)

        try await harness.restart(
            command: "printf 'SECOND\\n'; /bin/sleep 30"
        )
        let receivedSecond = try await harness.waitForOutput(
            containing: "SECOND",
            timeout: .seconds(2)
        )
        XCTAssertTrue(receivedSecond)

        let terminal = try XCTUnwrap(view.terminal)
        let visibleText = (0..<terminal.rows)
            .compactMap { terminal.getLine(row: $0) }
            .map {
                $0.translateToString(
                    trimRight: true,
                    skipNullCellsFollowingWide: true,
                    characterProvider: terminal.getCharacter(for:)
                )
            }
            .joined(separator: "\n")
        XCTAssertEqual(view.scrollPosition, 1)
        XCTAssertTrue(
            visibleText.contains("SECOND"),
            "Visible terminal text was \(visibleText.debugDescription)"
        )
    }
}

@MainActor
private final class TerminalPTYIntegrationHarness {
    let supervisor: ProcessSupervisor
    let runtimeStore: RuntimeStore
    let runtime: EntryRuntime

    private(set) var entry: CommandEntry
    private let surfaceHolder: TerminalIntegrationSurfaceHolder
    private let processState: TerminalIntegrationProcessState
    private let outputSignal: TerminalOutputProjectionSignal

    init(shell: String, command: String) throws {
        let entry = CommandEntry(
            id: UUID(),
            name: "Terminal PTY Integration",
            cwd: "/tmp",
            command: command,
            shell: shell,
            keywords: [],
            order: 0
        )
        let supervisor = ProcessSupervisor()
        let processState = TerminalIntegrationProcessState()
        let surfaceHolder = TerminalIntegrationSurfaceHolder()
        let processClient = RuntimeProcessClient(
            start: { entry, generation, outputHandler in
                processState.recordGeneration(generation)
                return try await supervisor.start(
                    entry: entry,
                    generation: generation
                ) { data in
                    outputHandler.handler(data)
                }
            },
            write: { entryID, generation, data in
                do {
                    try await supervisor.write(
                        entryID: entryID,
                        generation: generation,
                        data: data
                    )
                    processState.recordTerminalIOCompletion(
                        error: nil
                    )
                } catch {
                    processState.recordTerminalIOCompletion(
                        error: error as? ProcessSupervisorError
                    )
                    throw error
                }
            },
            resize: { entryID, generation, size in
                do {
                    try await supervisor.resize(
                        entryID: entryID,
                        generation: generation,
                        size: size
                    )
                    processState.recordTerminalIOCompletion(
                        error: nil
                    )
                } catch {
                    processState.recordTerminalIOCompletion(
                        error: error as? ProcessSupervisorError
                    )
                    throw error
                }
            },
            stop: { entryID, timeout in
                let result = try await supervisor.stop(
                    entryID: entryID,
                    timeout: timeout
                )
                processState.recordStopResult(result)
                return result
            },
            refresh: { entryID in
                let snapshot = try await supervisor.refresh(
                    entryID: entryID
                )
                processState.recordSnapshot(snapshot)
                return snapshot
            },
            snapshots: {
                let snapshots = try await supervisor.snapshots()
                processState.recordSnapshots(snapshots)
                return snapshots
            }
        )
        let runtimeStore = RuntimeStore(
            supervisor: supervisor,
            processClient: processClient,
            terminalSurfaceFactory: surfaceHolder.factory
        )
        let runtime = runtimeStore.runtime(for: entry.id)

        self.entry = entry
        self.supervisor = supervisor
        self.processState = processState
        self.surfaceHolder = surfaceHolder
        self.runtimeStore = runtimeStore
        self.runtime = runtime
        outputSignal = TerminalOutputProjectionSignal(
            runtime: runtime
        )
    }

    var activeCallbacks: TerminalSurfaceCallbacks? {
        surfaceHolder.callbacks
    }

    var generation: UUID {
        processState.requiredGeneration
    }

    var textOutput: String {
        runtime.output.displayText
    }

    var swiftTermView: ReadOnlySwiftTermView {
        guard let view = surfaceHolder.requiredSurface.nativeView
                as? ReadOnlySwiftTermView else {
            preconditionFailure(
                "The terminal surface did not expose a SwiftTerm view."
            )
        }
        return view
    }

    var completedTerminalIOErrors: [ProcessSupervisorError] {
        processState.completedTerminalIOErrors
    }

    var terminalIOCompletionCount: Int {
        processState.terminalIOCompletionCount
    }

    var terminalText: String {
        String(
            decoding:
                swiftTermView.terminal.getBufferAsData(),
            as: UTF8.self
        )
    }

    func start() async throws {
        let result = await runtimeStore.start(entry)
        try requireSuccess(result)
        await surfaceHolder.requiredSurface.waitUntilIdle()
    }

    func restart(command: String) async throws {
        entry.command = command
        let result = await runtimeStore.restart(
            entry,
            timeout: .seconds(2)
        )
        try requireSuccess(result)
        await surfaceHolder.requiredSurface.waitUntilIdle()
    }

    func stop() async -> EntryActionResult {
        await runtimeStore.stop(entry, timeout: .seconds(2))
    }

    func waitForTerminalIdle() async {
        await surfaceHolder.requiredSurface.waitUntilIdle()
    }

    func resize(_ size: TerminalSize) async throws {
        let completionCount =
            processState.terminalIOCompletionCount
        surfaceHolder.requiredSurface.resize(
            size,
            generation: generation
        )
        let completed = await waitForTerminalIOCompletions(
            completionCount + 1,
            timeout: .seconds(2)
        )
        guard completed else {
            throw TerminalPTYIntegrationError.callbackTimedOut
        }
        if let error = processState.lastTerminalIOError {
            throw error
        }
    }

    func waitForOutput(
        prefix: String,
        timeout: Duration
    ) async throws -> Bool {
        try await waitForOutput(timeout: timeout) {
            $0.split(whereSeparator: \.isNewline).contains {
                $0.hasPrefix(prefix)
            }
        }
    }

    func waitForOutput(
        containing text: String,
        timeout: Duration
    ) async throws -> Bool {
        try await waitForOutput(timeout: timeout) {
            $0.contains(text)
        }
    }

    func waitForTerminalCallbackDrain(
        expectedCount: Int
    ) async {
        let completed = await waitForTerminalIOCompletions(
            expectedCount,
            timeout: .seconds(2)
        )
        XCTAssertTrue(
            completed,
            "Terminal callback operations did not drain."
        )
    }

    func supervisorHasManagedProcess() throws -> Bool {
        processState.hasManagedProcess
    }

    func forceStopForTestCleanup() {
        runtimeStore.disposeAllTerminalSurfaces()
        guard let pid = runtime.process.pid,
              let processGroupID = runtime.process.processGroupID else {
            return
        }

        let killResult = Darwin.killpg(processGroupID, SIGKILL)
        let killError = killResult == -1 ? errno : 0
        XCTAssertTrue(
            killResult == 0
                || (killResult == -1 && killError == ESRCH),
            "cleanup killpg failed with errno \(killError)"
        )

        let deadline = ContinuousClock.now.advanced(
            by: .seconds(2)
        )
        var leaderHandled = false
        while ContinuousClock.now < deadline {
            var status: Int32 = 0
            let result = Darwin.waitpid(pid, &status, WNOHANG)
            if result == pid
                || (result == -1 && errno == ECHILD) {
                leaderHandled = true
                break
            }
            if result == -1 && errno != EINTR {
                XCTFail(
                    "cleanup waitpid failed with errno \(errno)"
                )
                break
            }
            usleep(10_000)
        }
        XCTAssertTrue(
            leaderHandled,
            "cleanup did not reap leader \(pid)"
        )

        var groupGone = false
        while ContinuousClock.now < deadline {
            if Darwin.killpg(processGroupID, 0) == -1
                && errno == ESRCH {
                groupGone = true
                break
            }
            usleep(10_000)
        }
        XCTAssertTrue(
            groupGone,
            "cleanup left process group \(processGroupID)"
        )
    }

    private func waitForOutput(
        timeout: Duration,
        predicate: @MainActor (String) -> Bool
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var revision = outputSignal.revision

        while clock.now < deadline {
            if predicate(textOutput) {
                await surfaceHolder.requiredSurface.waitUntilIdle()
                return true
            }
            let changed = await waitForProjectionOrDeadline(
                after: revision,
                deadline: deadline
            )
            guard changed else {
                break
            }
            revision = outputSignal.revision
        }

        await surfaceHolder.requiredSurface.waitUntilIdle()
        return predicate(textOutput)
    }

    private func waitForProjectionOrDeadline(
        after revision: UInt64,
        deadline: ContinuousClock.Instant
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.outputSignal.wait(after: revision)
                return true
            }
            group.addTask {
                do {
                    try await ContinuousClock().sleep(
                        until: deadline,
                        tolerance: .zero
                    )
                    return false
                } catch {
                    return false
                }
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func waitForTerminalIOCompletions(
        _ expectedCount: Int,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if processState.terminalIOCompletionCount
                >= expectedCount {
                return true
            }
            await Task.yield()
        }
        return processState.terminalIOCompletionCount
            >= expectedCount
    }

    private func requireSuccess(
        _ result: EntryActionResult
    ) throws {
        guard result.isSuccess else {
            throw TerminalPTYIntegrationError.actionFailed(
                result.errorDescription ?? "unknown"
            )
        }
    }
}

@MainActor
private final class TerminalIntegrationSurfaceHolder {
    private(set) var callbacks: TerminalSurfaceCallbacks?
    private(set) var surface: SwiftTermSurface?

    var factory: TerminalSurfaceFactory {
        TerminalSurfaceFactory { [weak self] _, callbacks in
            let surface = SwiftTermSurface(callbacks: callbacks)
            self?.callbacks = callbacks
            self?.surface = surface
            return surface
        }
    }

    var requiredSurface: SwiftTermSurface {
        guard let surface else {
            preconditionFailure(
                "The runtime did not create its terminal surface."
            )
        }
        return surface
    }
}

private final class TerminalIntegrationProcessState:
    @unchecked Sendable {
    private let lock = NSLock()
    private var recordedGeneration: UUID?
    private var recordedSnapshots: [UUID: ProcessSnapshot] = [:]
    private var terminalIOErrors: [ProcessSupervisorError] = []
    private var callbackCompletionCount = 0
    private var latestTerminalIOError: ProcessSupervisorError?

    func recordGeneration(_ generation: UUID) {
        lock.withLock {
            recordedGeneration = generation
        }
    }

    func recordTerminalIOCompletion(
        error: ProcessSupervisorError?
    ) {
        lock.withLock {
            callbackCompletionCount += 1
            latestTerminalIOError = error
            if let error {
                terminalIOErrors.append(error)
            }
        }
    }

    func recordStopResult(_ result: StopResult) {
        guard case .timedOut(let snapshot) = result else {
            return
        }
        recordSnapshot(snapshot)
    }

    func recordSnapshot(_ snapshot: ProcessSnapshot) {
        lock.withLock {
            recordedSnapshots[snapshot.entryID] = snapshot
        }
    }

    func recordSnapshots(
        _ snapshots: [UUID: ProcessSnapshot]
    ) {
        lock.withLock {
            recordedSnapshots = snapshots
        }
    }

    var requiredGeneration: UUID {
        lock.withLock {
            guard let recordedGeneration else {
                preconditionFailure(
                    "The runtime did not start a process generation."
                )
            }
            return recordedGeneration
        }
    }

    var terminalIOCompletionCount: Int {
        lock.withLock { callbackCompletionCount }
    }

    var completedTerminalIOErrors: [ProcessSupervisorError] {
        lock.withLock { terminalIOErrors }
    }

    var lastTerminalIOError: ProcessSupervisorError? {
        lock.withLock { latestTerminalIOError }
    }

    var hasManagedProcess: Bool {
        lock.withLock {
            recordedSnapshots.values.contains {
                $0.liveness == .running
                    && $0.processGroupID != nil
            }
        }
    }
}

@MainActor
private final class TerminalOutputProjectionSignal {
    private let runtime: EntryRuntime
    private var waiters: [
        UUID: CheckedContinuation<Void, Never>
    ] = [:]
    private(set) var revision: UInt64 = 0

    init(runtime: EntryRuntime) {
        self.runtime = runtime
        armObservation()
    }

    func wait(after observedRevision: UInt64) async {
        guard revision <= observedRevision else {
            return
        }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if revision > observedRevision
                    || Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(waiterID)
            }
        }
    }

    private func armObservation() {
        withObservationTracking {
            _ = runtime.output
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.publishChange()
            }
        }
    }

    private func publishChange() {
        revision &+= 1
        let continuations = Array(waiters.values)
        waiters.removeAll()
        armObservation()
        continuations.forEach { $0.resume() }
    }

    private func cancel(_ waiterID: UUID) {
        waiters.removeValue(forKey: waiterID)?.resume()
    }
}

private enum TerminalPTYIntegrationError:
    Error,
    Equatable {
    case actionFailed(String)
    case callbackTimedOut
}

private func sessionSeparatorCount(in text: String) -> Int {
    text.split(whereSeparator: \.isNewline).filter {
        $0.hasPrefix("──── ") && $0.hasSuffix(" ────")
    }.count
}

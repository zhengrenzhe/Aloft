# Aloft v2 Terminal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a read-only, Metal-first SwiftTerm terminal view to every Aloft managed command while retaining the existing Text view, POSIX process ownership, keyword matching, and a backend-neutral path to Ghostty.

**Architecture:** Aloft continues owning the PTY and process group. Each raw PTY chunk fans out to the existing `OutputPipeline` and a generation-scoped `TerminalSurface`; the production surface embeds SwiftTerm 1.15.0, enables Metal after entering an `NSWindow`, and falls back to CoreGraphics or Text without changing process state. PTY protocol replies and window-size changes return through generation-checked `ManagedProcess` operations.

**Tech Stack:** Swift 6, SwiftUI, Observation, AppKit, SwiftPM, XCTest, Darwin POSIX APIs, `AloftProcess` C bridge, SwiftTerm 1.15.0, MetalKit.

**Design:** `docs/superpowers/specs/2026-07-29-aloft-v2-terminal-design.md`

## Global Constraints

- Deployment target remains macOS 14 or newer.
- SwiftTerm is pinned exactly to version 1.15.0.
- SwiftTerm launches no Aloft process; do not use `LocalProcessTerminalView`.
- SwiftTerm types remain inside `Sources/AloftApp/Terminal/SwiftTerm/` and its focused AppKit bridge.
- Aloft remains the owner of PTY descriptors, process groups, kernel liveness, stop, restart, and shutdown.
- Terminal is the default detail-view mode; Text remains available.
- SwiftTerm Metal is enabled after the view enters an `NSWindow`.
- Metal failure falls back to SwiftTerm CoreGraphics; terminal failure selects Text.
- User keyboard, paste, input-method composition, drag input, link activation, OSC 52, and terminal mouse reports remain disabled.
- Mouse selection, Command-C, scrolling, cursor display, and terminal protocol replies remain enabled.
- Terminal and Text scrollback limits are 20,000 lines.
- Every process start, PTY write, resize, terminal feed, and renderer callback is generation-scoped.
- Late work from a replaced generation never mutates current state or a reused descriptor.
- Existing Unicode 17 keyword matching behavior remains unchanged.
- All new user-facing strings exist in ar, de, en, es, fr, ja, ko, pt-BR, ru, zh-Hans, and zh-Hant.
- Production changes follow RED, verify RED, GREEN, verify GREEN, refactor.
- No Ghostty migration begins before the release benchmark and Instruments attribution.

---

## Planned File Map

### Dependency and neutral terminal API

- Modify: `Package.swift` — pin SwiftTerm 1.15.0.
- Create: `docs/licenses/SwiftTerm-MIT.txt` — preserve the exact SwiftTerm 1.15.0 MIT license text.
- Create: `Sources/AloftApp/Terminal/TerminalTypes.swift` — backend-neutral sizes, display mode, renderer state, and callbacks.
- Create: `Sources/AloftApp/Terminal/TerminalSurface.swift` — backend-neutral surface protocol and factory.
- Create: `Sources/AloftApp/Output/SessionSeparator.swift` — shared deterministic session-separator formatting.

### POSIX PTY I/O

- Modify: `Sources/AloftProcess/include/AloftProcess.h` — PTY resize C ABI.
- Modify: `Sources/AloftProcess/AloftProcess.c` — `TIOCSWINSZ` implementation.
- Create: `Sources/AloftApp/Process/PTYWritePump.swift` — partial-write, `EINTR`, and `EAGAIN` loop.
- Modify: `Sources/AloftApp/Process/ManagedProcess.swift` — duplicated write/control descriptor and async write/resize APIs.
- Modify: `Sources/AloftApp/Process/ProcessSupervisor.swift` — generation-checked write and resize operations.
- Modify: `Sources/AloftApp/Stores/RuntimeStore.swift` — process-client write and resize closures.

### SwiftTerm backend

- Create: `Sources/AloftApp/Terminal/SwiftTerm/ReadOnlySwiftTermView.swift` — input suppression and selection/copy behavior.
- Create: `Sources/AloftApp/Terminal/SwiftTerm/SwiftTermSurface.swift` — generation lane, pending feed, terminal lifecycle, delegate bridge, and Metal fallback.
- Create: `Sources/AloftApp/Terminal/SwiftTerm/SwiftTermSurfaceFactory.swift` — production factory.

### Runtime and UI

- Modify: `Sources/AloftApp/Stores/EntryRuntime.swift` — display mode, terminal surface, and renderer projection.
- Modify: `Sources/AloftApp/Stores/RuntimeStore.swift` — raw-byte fan-out, promotion, clear, disposal, and terminal callback errors.
- Modify: `Sources/AloftApp/App/AppModel.swift` — production factory injection and entry/group disposal.
- Modify: `Sources/AloftApp/App/AppDelegate.swift` — dispose all surfaces only on accepted termination.
- Create: `Sources/AloftApp/Views/Output/TerminalOutputView.swift` — stable AppKit host for an existing terminal surface.
- Modify: `Sources/AloftApp/Views/Management/EntryDetailView.swift` — Terminal/Text selector and fallback status.
- Modify: all `Sources/AloftApp/Resources/*.lproj/Localizable.strings` — complete localized key set.

### Tests and performance

- Create: `Tests/AloftAppTests/TerminalTypesTests.swift`.
- Create: `Tests/AloftAppTests/SessionSeparatorTests.swift`.
- Create: `Tests/AloftProcessTests/PTYWritePumpTests.swift`.
- Modify: `Tests/AloftProcessTests/ManagedProcessTests.swift`.
- Modify: `Tests/AloftProcessTests/ProcessSupervisorTests.swift`.
- Modify: `Tests/AloftProcessTests/RuntimeStoreTests.swift`.
- Modify: `Tests/AloftProcessTests/RuntimeStoreConcurrencyTests.swift`.
- Create: `Tests/AloftAppTests/ReadOnlySwiftTermViewTests.swift`.
- Create: `Tests/AloftAppTests/SwiftTermSurfaceTests.swift`.
- Create: `Tests/AloftAppTests/TerminalSurfaceStub.swift`.
- Create: `Tests/AloftAppTests/TerminalOutputViewTests.swift`.
- Modify: `Tests/AloftAppTests/AppModelTests.swift`.
- Modify: `Tests/AloftAppTests/MenuBarProjectionTests.swift`.
- Modify: `Tests/AloftAppTests/LocalizationTests.swift`.
- Modify: `Tests/AloftAppTests/OutputPipelineTests.swift`.
- Create: `Tests/AloftPerformanceTests/TerminalPerformanceTests.swift`.
- Create: `script/run_terminal_benchmarks.sh`.
- Create: `docs/performance/terminal-v2-baseline.md`.

---

### Task 1: Pin SwiftTerm and Define the Backend-Neutral Contract

**Files:**
- Modify: `Package.swift`
- Create: `docs/licenses/SwiftTerm-MIT.txt`
- Create: `Sources/AloftApp/Terminal/TerminalTypes.swift`
- Create: `Sources/AloftApp/Terminal/TerminalSurface.swift`
- Test: `Tests/AloftAppTests/TerminalTypesTests.swift`

**Interfaces:**
- Produces: `TerminalSize.init?(columns:rows:pixelWidth:pixelHeight:)`.
- Produces: `OutputDisplayMode.terminal` and `.text`.
- Produces: `TerminalRendererState.awaitingWindow`, `.metal`, `.coreGraphicsFallback(String)`, and `.unavailable(String)`.
- Produces: `TerminalSurfaceCallbacks`, `TerminalSurface`, and `TerminalSurfaceFactory`.
- `TerminalSurface` accepts generation-scoped prepare, feed, promote, discard, resize, clear, and dispose operations.

- [ ] **Step 1: Write the compile-failing dependency and neutral-type tests**

```swift
// Tests/AloftAppTests/TerminalTypesTests.swift
import AppKit
import SwiftTerm
import XCTest
@testable import AloftApp

final class TerminalTypesTests: XCTestCase {
    func testTerminalSizeRejectsInvalidOrUnrepresentableWinsize() {
        XCTAssertNil(TerminalSize(columns: 0, rows: 24, pixelWidth: 800, pixelHeight: 600))
        XCTAssertNil(TerminalSize(columns: 80, rows: 0, pixelWidth: 800, pixelHeight: 600))
        XCTAssertNil(TerminalSize(columns: 65_536, rows: 24, pixelWidth: 800, pixelHeight: 600))
        XCTAssertNotNil(TerminalSize(columns: 80, rows: 24, pixelWidth: 800, pixelHeight: 600))
    }

    func testDisplayModeDefaultsToTerminal() {
        XCTAssertEqual(OutputDisplayMode.default, .terminal)
    }

    @MainActor
    func testSwiftTermProductIsLinked() {
        let view = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400)
        )
        XCTAssertEqual(view.frame.size, NSSize(width: 800, height: 400))
    }
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter TerminalTypesTests
```

Expected: compilation fails because SwiftTerm is not a package dependency and the Aloft terminal types do not exist.

- [ ] **Step 3: Pin SwiftTerm and implement the neutral types**

Add to `Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://github.com/migueldeicaza/SwiftTerm",
        exact: "1.15.0"
    ),
],
```

Add `.product(name: "SwiftTerm", package: "SwiftTerm")` to the `AloftApp` and
`AloftAppTests` dependencies.

Copy the `LICENSE` file from the resolved SwiftTerm 1.15.0 checkout verbatim to
`docs/licenses/SwiftTerm-MIT.txt`. Verify the first copyright line and the final
`SOFTWARE.` line match the tag before committing; do not paraphrase the license.

Implement:

```swift
// Sources/AloftApp/Terminal/TerminalTypes.swift
import Foundation

struct TerminalSize: Equatable, Sendable {
    let columns: Int
    let rows: Int
    let pixelWidth: Int
    let pixelHeight: Int

    init?(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        guard (1...Int(UInt16.max)).contains(columns),
              (1...Int(UInt16.max)).contains(rows),
              (0...Int(UInt16.max)).contains(pixelWidth),
              (0...Int(UInt16.max)).contains(pixelHeight) else {
            return nil
        }
        self.columns = columns
        self.rows = rows
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

enum OutputDisplayMode: String, Equatable, Sendable {
    case terminal
    case text
    static let `default`: Self = .terminal
}

enum TerminalRendererState: Equatable, Sendable {
    case awaitingWindow
    case metal
    case coreGraphicsFallback(String)
    case unavailable(String)
}

struct TerminalSurfaceCallbacks: Sendable {
    let writeProtocolReply: @Sendable (Data, UUID) -> Void
    let resizePTY: @Sendable (TerminalSize, UUID) -> Void
}
```

Define the exact protocol:

```swift
// Sources/AloftApp/Terminal/TerminalSurface.swift
import AppKit
import Foundation

protocol TerminalSurface: AnyObject, Sendable {
    @MainActor var nativeView: NSView { get }
    @MainActor var rendererState: TerminalRendererState { get }
    @MainActor var onRendererStateChange: ((TerminalRendererState) -> Void)? { get set }

    func prepare(generation: UUID)
    func feed(_ data: Data, generation: UUID)
    func promote(generation: UUID, at timestamp: Date)
    func discard(generation: UUID)
    func resize(_ size: TerminalSize, generation: UUID)
    func clear()
    func dispose()
}

@MainActor
struct TerminalSurfaceFactory {
    let makeSurface: (
        UUID,
        TerminalSurfaceCallbacks
    ) throws -> any TerminalSurface
}
```

- [ ] **Step 4: Resolve the package and verify GREEN**

Run:

```bash
swift package resolve
swift test --filter TerminalTypesTests
```

Expected: SwiftTerm resolves to 1.15.0 and all `TerminalTypesTests` pass.

- [ ] **Step 5: Verify package pin and commit**

Run:

```bash
rg -n '"version" : "1.15.0"' Package.resolved
git diff --check
```

Commit:

```bash
git add Package.swift Package.resolved docs/licenses/SwiftTerm-MIT.txt Sources/AloftApp/Terminal Tests/AloftAppTests/TerminalTypesTests.swift
git commit -m "feat: define terminal surface boundary"
```

---

### Task 2: Add a Tested PTY Write Pump and POSIX Resize

**Files:**
- Modify: `Sources/AloftProcess/include/AloftProcess.h`
- Modify: `Sources/AloftProcess/AloftProcess.c`
- Create: `Sources/AloftApp/Process/PTYWritePump.swift`
- Modify: `Sources/AloftApp/Process/ManagedProcess.swift`
- Create: `Tests/AloftProcessTests/PTYWritePumpTests.swift`
- Modify: `Tests/AloftProcessTests/ManagedProcessTests.swift`

**Interfaces:**
- Produces: `aloft_set_window_size(fd, rows, columns, pixel_width, pixel_height)`.
- Produces: `PTYWritePump.writeAll(_:to:isCancelled:) throws`.
- Produces: `ManagedProcess.write(_:) async throws` and `resize(_:) async throws`.
- `ManagedProcess` duplicates the master FD for writes/control and closes it on its serialized I/O lane.

- [ ] **Step 1: Write failing syscall-loop and real-PTY tests**

```swift
// Tests/AloftProcessTests/PTYWritePumpTests.swift
func testWriteAllRetriesEINTRAndCompletesPartialWrites() throws {
    var results: [Result<Int, PTYSystemCallError>] = [
        .failure(PTYSystemCallError(code: EINTR)),
        .success(2),
        .success(3),
    ]
    var written = Data()
    let pump = PTYWritePump(
        write: { _, bytes in
            let result = results.removeFirst()
            if case .success(let count) = result {
                written.append(bytes.prefix(count))
            }
            return result
        },
        waitWritable: { _ in .success(true) }
    )

    try pump.writeAll(Data("hello".utf8), to: 9, isCancelled: { false })

    XCTAssertEqual(String(decoding: written, as: UTF8.self), "hello")
}

func testWriteAllWaitsAfterEAGAIN() throws {
    var call = 0
    var waitCount = 0
    let pump = PTYWritePump(
        write: { _, bytes in
            call += 1
            if call == 1 {
                return .failure(PTYSystemCallError(code: EAGAIN))
            }
            return .success(bytes.count)
        },
        waitWritable: { _ in
            waitCount += 1
            return .success(true)
        }
    )

    try pump.writeAll(Data([1, 2, 3]), to: 9, isCancelled: { false })

    XCTAssertEqual(waitCount, 1)
}
```

Add real PTY assertions to `ManagedProcessTests`:

```swift
func testWriteReachesSlaveAndResizeChangesKernelWinsize() async throws {
    let pair = try makeRawPTY()
    let process = try ManagedProcess(
        masterFileDescriptor: pair.master,
        onOutput: { _ in }
    )
    defer {
        process.close()
        Darwin.close(pair.slave)
    }

    try await process.write(Data("reply".utf8))
    XCTAssertEqual(try readExactly(fd: pair.slave, count: 5), Data("reply".utf8))

    let size = try XCTUnwrap(
        TerminalSize(columns: 120, rows: 40, pixelWidth: 1200, pixelHeight: 800)
    )
    try await process.resize(size)
    XCTAssertEqual(try readWinsize(fd: pair.slave), size)
}
```

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
swift test --filter PTYWritePumpTests
swift test --filter ManagedProcessTests/testWriteReachesSlaveAndResizeChangesKernelWinsize
```

Expected: compilation fails because `PTYWritePump`, throwing `ManagedProcess.init`, `write`, `resize`, and the C resize function do not exist.

- [ ] **Step 3: Implement the write loop and resize ABI**

Define `PTYWritePump` with deterministic syscall seams:

```swift
struct PTYSystemCallError: Error, Equatable, Sendable {
    let code: Int32
}

struct PTYWritePump: Sendable {
    typealias WriteOperation = @Sendable (
        Int32,
        UnsafeRawBufferPointer
    ) -> Result<Int, PTYSystemCallError>
    typealias WaitWritableOperation = @Sendable (
        Int32
    ) -> Result<Bool, PTYSystemCallError>

    let write: WriteOperation
    let waitWritable: WaitWritableOperation

    static let live = PTYWritePump(
        write: { fileDescriptor, bytes in
            let count = Darwin.write(
                fileDescriptor,
                bytes.baseAddress,
                bytes.count
            )
            return count >= 0
                ? .success(count)
                : .failure(PTYSystemCallError(code: errno))
        },
        waitWritable: { fileDescriptor in
            var descriptor = pollfd(
                fd: fileDescriptor,
                events: Int16(POLLOUT),
                revents: 0
            )
            let result = Darwin.poll(&descriptor, 1, 50)
            if result > 0 {
                let terminalEvents = Int16(POLLERR | POLLHUP | POLLNVAL)
                if descriptor.revents & terminalEvents != 0 {
                    return .failure(PTYSystemCallError(code: EIO))
                }
                return .success(
                    descriptor.revents & Int16(POLLOUT) != 0
                )
            }
            if result == 0 {
                return .success(false)
            }
            return .failure(PTYSystemCallError(code: errno))
        }
    )
}
```

The write loop uses these exact branches:

```swift
while offset < data.count {
    if isCancelled() {
        throw CocoaError(.userCancelled)
    }
    let result = data.withUnsafeBytes { bytes in
        write(
            fileDescriptor,
            UnsafeRawBufferPointer(rebasing: bytes[offset...])
        )
    }
    switch result {
    case .success(let count) where count > 0:
        offset += count
    case .failure(let failure) where failure.code == EINTR:
        continue
    case .failure(let failure)
        where failure.code == EAGAIN || failure.code == EWOULDBLOCK:
        switch waitWritable(fileDescriptor) {
        case .success:
            continue
        case .failure(let waitFailure) where waitFailure.code == EINTR:
            continue
        case .failure(let waitFailure):
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(waitFailure.code)
            )
        }
    case .success:
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
    case .failure(let failure):
        if isCancelled() {
            throw CocoaError(.userCancelled)
        }
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(failure.code)
        )
    }
}
```

Add the C ABI:

```c
int aloft_set_window_size(
    int fd,
    uint16_t rows,
    uint16_t columns,
    uint16_t pixel_width,
    uint16_t pixel_height
);
```

Implement it with `struct winsize` and `ioctl(fd, TIOCSWINSZ, &size)`, returning
`0` on success and `-errno` on failure.

Update `ManagedProcess`:

- make `init` throwing;
- create `controlFileDescriptor` with `fcntl(masterFD, F_DUPFD_CLOEXEC, 0)`;
- retain the read source on the original descriptor;
- execute writes and resizes on `controlQueue`;
- poll `POLLOUT` in 50 ms slices after `EAGAIN`;
- set the cancellation flag before cancelling/closing;
- close `controlFileDescriptor` only on `controlQueue`, after admitted work;
- ensure queued work observes cancellation before any syscall.

- [ ] **Step 4: Verify GREEN and descriptor safety**

Run:

```bash
swift test --filter PTYWritePumpTests
swift test --filter ManagedProcessTests
swift test --filter ProcessSupervisorTests
```

Expected: all focused suites pass with zero failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/AloftProcess Sources/AloftApp/Process Tests/AloftProcessTests
git commit -m "feat: add managed PTY write and resize"
```

---

### Task 3: Make Supervisor I/O Generation-Safe

**Files:**
- Modify: `Sources/AloftApp/Process/ProcessSupervisor.swift`
- Modify: `Sources/AloftApp/Stores/RuntimeStore.swift`
- Modify: `Tests/AloftProcessTests/ProcessSupervisorTests.swift`
- Modify: `Tests/AloftProcessTests/RuntimeStoreConcurrencyTests.swift`

**Interfaces:**
- Changes: `ProcessSupervisor.start(entry:generation:onOutput:)`.
- Produces: `ProcessSupervisor.write(entryID:generation:data:) async throws`.
- Produces: `ProcessSupervisor.resize(entryID:generation:size:) async throws`.
- Changes: `RuntimeProcessClient.StartOperation` accepts the generation UUID.
- Adds: `RuntimeProcessClient.write` and `resize`.
- Produces: `ProcessSupervisorError.staleGeneration`.

- [ ] **Step 1: Write failing supervisor-generation tests**

```swift
func testCurrentGenerationCanWriteAndResizeButOldGenerationCannot() async throws {
    let supervisor = ProcessSupervisor()
    let entry = fixtureEntry(
        command: "trap 'stty size' WINCH; IFS= read -r line; printf 'input=%s\\n' \"$line\"; sleep 30"
    )
    let generation = UUID()
    let output = DataRecorder()
    let started = try await supervisor.start(
        entry: entry,
        generation: generation
    ) { data in
        Task { await output.append(data) }
    }
    defer { cleanup(started) }

    try await supervisor.resize(
        entryID: entry.id,
        generation: generation,
        size: TerminalSize(columns: 120, rows: 40, pixelWidth: 1200, pixelHeight: 800)!
    )
    try await supervisor.write(
        entryID: entry.id,
        generation: generation,
        data: Data("hello\\n".utf8)
    )
    XCTAssertTrue(await output.waitForText("input=hello", timeout: .seconds(2)))

    do {
        try await supervisor.write(
            entryID: entry.id,
            generation: UUID(),
            data: Data("stale\\n".utf8)
        )
        XCTFail("A stale generation write must fail")
    } catch {
        XCTAssertEqual(
            error as? ProcessSupervisorError,
            .staleGeneration
        )
    }
}
```

Add a fake-client concurrency test asserting that an old terminal callback
after restart does not invoke the current generation's write or resize closure.

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
swift test --filter ProcessSupervisorTests/testCurrentGenerationCanWriteAndResizeButOldGenerationCannot
swift test --filter RuntimeStoreConcurrencyTests
```

Expected: compilation fails on the new generation, write, and resize APIs.

- [ ] **Step 3: Implement generation propagation**

Use the RuntimeStore generation as the supervisor record generation:

```swift
func start(
    entry: CommandEntry,
    generation: UUID,
    onOutput: @escaping OutputHandler
) throws -> ProcessSnapshot
```

Both I/O methods guard:

```swift
guard let record = records[entryID] else {
    throw ProcessSupervisorError.unknownEntry
}
guard record.generation == generation else {
    throw ProcessSupervisorError.staleGeneration
}
guard record.liveness == .running,
      let managedProcess = record.managedProcess else {
    throw ProcessSupervisorError.unknownEntry
}
```

Then delegate to `managedProcess.write` or `managedProcess.resize`.

Update every production and test `RuntimeProcessClient` initializer with
generation-aware closures. Change `RuntimeStore.startLocked` to pass
`nextGeneration` into `processClient.start`.

- [ ] **Step 4: Verify GREEN and full concurrency regression**

Run:

```bash
swift test --filter ProcessSupervisorTests
swift test --filter RuntimeStoreConcurrencyTests
```

Expected: all tests pass with zero failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/AloftApp/Process/ProcessSupervisor.swift Sources/AloftApp/Stores/RuntimeStore.swift Tests/AloftProcessTests
git commit -m "feat: scope terminal IO to process generations"
```

---

### Task 4: Build the Generation-Scoped Terminal Session Contract

**Files:**
- Modify: `Sources/AloftApp/Terminal/TerminalSurface.swift`
- Modify: `Sources/AloftApp/Stores/EntryRuntime.swift`
- Modify: `Sources/AloftApp/Stores/RuntimeStore.swift`
- Create: `Tests/AloftProcessTests/TerminalSurfaceRecorder.swift`
- Modify: `Tests/AloftProcessTests/RuntimeStoreTests.swift`
- Modify: `Tests/AloftProcessTests/RuntimeStoreConcurrencyTests.swift`

**Interfaces:**
- `EntryRuntime` gains `terminalSurface`, `terminalRendererState`, and `outputDisplayMode`.
- `RuntimeStore` accepts `TerminalSurfaceFactory?`; `nil` keeps existing headless tests unchanged.
- A pending generation buffers terminal bytes until start success.
- Start failure and supersession discard pending bytes without mutating the retained surface.

- [ ] **Step 1: Write failing fake-surface lifecycle tests**

Create a thread-safe recorder conforming to `TerminalSurface`. Add tests:

```swift
func testStartPromotesPendingTerminalBytesOnlyAfterLaunchSuccess() async {
    let fakeProcess = ControlledProcessSupervisor()
    let fakeSurface = TerminalSurfaceRecorder()
    let runtime = makeRuntimeStore(
        fakeProcess,
        terminalFactory: .recording(fakeSurface)
    )
    let entry = fixtureEntry(command: "unused")

    await fakeProcess.emitDuringStart(Data("early".utf8), entryID: entry.id)
    let result = await runtime.start(entry)

    XCTAssertTrue(result.isSuccess)
    XCTAssertEqual(fakeSurface.events, [
        .prepare(fakeProcess.startedGeneration),
        .promote(fakeProcess.startedGeneration),
        .feed("early", fakeProcess.startedGeneration),
    ])
}

func testFailedStartDiscardsPendingBytesAndPreservesRetainedSurface() async {
    let fixture = await makeTerminalRuntimeFixture(
        startPlans: [
            .success(outputBeforeReturn: Data("old".utf8)),
            .failure(
                TestProcessError.launchFailed,
                outputBeforeReturn: Data("new".utf8)
            ),
        ]
    )

    XCTAssertTrue((await fixture.runtime.start(fixture.entry)).isSuccess)
    XCTAssertFalse((await fixture.runtime.start(fixture.entry)).isSuccess)

    let generations = await fixture.process.startedGenerations
    XCTAssertEqual(generations.count, 2)
    XCTAssertEqual(fixture.surface.visibleText, "old")
    XCTAssertTrue(
        fixture.surface.events.contains(.discard(generations[1]))
    )
    XCTAssertFalse(
        fixture.surface.events.contains(.feed("new", generations[1]))
    )
}

func testLateOldGenerationCannotFeedResizeOrWriteAfterRestart() async {
    let fixture = await makeTerminalRuntimeFixture(
        startPlans: [
            .success(outputBeforeReturn: Data("first".utf8)),
            .success(outputBeforeReturn: Data("second".utf8)),
        ]
    )
    XCTAssertTrue((await fixture.runtime.start(fixture.entry)).isSuccess)
    let oldGeneration = await fixture.process.startedGenerations[0]
    let oldCallbacks = try! XCTUnwrap(
        fixture.surface.callbacks(for: oldGeneration)
    )

    XCTAssertTrue((await fixture.runtime.restart(fixture.entry)).isSuccess)
    oldCallbacks.writeProtocolReply(
        Data("stale-reply".utf8),
        oldGeneration
    )
    oldCallbacks.resizePTY(
        TerminalSize(
            columns: 90,
            rows: 30,
            pixelWidth: 900,
            pixelHeight: 600
        )!,
        oldGeneration
    )
    fixture.surface.feed(
        Data("stale-output".utf8),
        generation: oldGeneration
    )
    await fixture.process.waitForCallbackTasks()

    XCTAssertFalse(fixture.surface.visibleText.contains("stale-output"))
    XCTAssertTrue(await fixture.process.writes.isEmpty)
    XCTAssertTrue(await fixture.process.resizes.isEmpty)
}
```

Implement `ScriptedTerminalProcessClient` and
`makeTerminalRuntimeFixture(startPlans:)` in the test target. A start plan
invokes its output handler before returning or throwing; the helper records
every supplied generation, write, and resize. `TerminalSurfaceRecorder` stores
the callbacks for each prepared generation and exposes synchronized snapshots
for `events`, `visibleText`, and `disposeCount`. Do not use time delays in these
helpers; `waitForCallbackTasks()` uses continuations completed by the recorded
write/resize operations.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
swift test --filter RuntimeStoreTests
swift test --filter RuntimeStoreConcurrencyTests
```

Expected: compilation fails because runtime terminal state and factory injection do not exist.

- [ ] **Step 3: Implement runtime surface creation and callback wiring**

Add to `EntryRuntime`:

```swift
var outputDisplayMode: OutputDisplayMode = .default
var terminalSurface: (any TerminalSurface)?
var terminalRendererState: TerminalRendererState = .awaitingWindow
```

Add an optional factory to `RuntimeStore`. When `startLocked` prepares
`nextGeneration`:

1. reuse `entryRuntime.terminalSurface`, or create one from the factory;
2. create callbacks capturing `entry.id`, `nextGeneration`, and
   `RuntimeProcessClient`;
3. call `surface.prepare(generation:)`;
4. call `surface.feed` directly from the PTY output callback;
5. keep the existing main-actor `OutputPipeline.consume`;
6. call `surface.promote` only after start succeeds;
7. call `surface.discard` on failure or supersession.

The surface implementation, not RuntimeStore, owns the ordered pending byte
queue. RuntimeStore only invokes lifecycle methods in generation order.

- [ ] **Step 4: Verify GREEN**

Run:

```bash
swift test --filter RuntimeStoreTests
swift test --filter RuntimeStoreConcurrencyTests
```

Expected: all runtime suites pass, including pre-existing stale-probe and delayed-output tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AloftApp/Terminal Sources/AloftApp/Stores Tests/AloftProcessTests
git commit -m "feat: add generation scoped terminal sessions"
```

---

### Task 5: Implement the Read-Only SwiftTerm Metal Surface

**Files:**
- Create: `Sources/AloftApp/Terminal/SwiftTerm/ReadOnlySwiftTermView.swift`
- Create: `Sources/AloftApp/Terminal/SwiftTerm/SwiftTermSurface.swift`
- Create: `Sources/AloftApp/Terminal/SwiftTerm/SwiftTermSurfaceFactory.swift`
- Create: `Tests/AloftAppTests/ReadOnlySwiftTermViewTests.swift`
- Create: `Tests/AloftAppTests/SwiftTermSurfaceTests.swift`

**Interfaces:**
- Produces: `ReadOnlySwiftTermView`.
- Produces: `SwiftTermSurface(callbacks:)`.
- Produces: `TerminalSurfaceFactory.swiftTerm`.
- The surface serializes state on one utility queue and updates AppKit renderer state on `MainActor`.

- [ ] **Step 1: Write failing read-only and parser tests**

```swift
@MainActor
func testReadOnlyViewBlocksUserInputButAllowsCopy() {
    let delegate = TerminalDelegateRecorder()
    let view = ReadOnlySwiftTermView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    view.terminalDelegate = delegate
    view.allowMouseReporting = false

    view.insertText("blocked", replacementRange: NSRange(location: 0, length: 0))
    view.paste(self)
    view.doCommand(by: #selector(NSResponder.insertNewline(_:)))

    XCTAssertTrue(delegate.sentData.isEmpty)
    XCTAssertFalse(view.validateUserInterfaceItem(MenuItem(action: #selector(view.paste(_:)))))
}

func testTerminalProtocolReplyUsesDelegateWhileUserInputRemainsBlocked() async {
    let callbacks = TerminalCallbackRecorder()
    let surface = await SwiftTermSurface(callbacks: callbacks.callbacks)
    let generation = UUID()
    surface.prepare(generation: generation)
    surface.promote(generation: generation, at: fixedDate)
    surface.feed(Data("\u{1b}[6n".utf8), generation: generation)

    XCTAssertEqual(
        await callbacks.firstReplyGeneration,
        generation
    )
    XCTAssertTrue(await callbacks.firstReply.starts(with: Data("\u{1b}[".utf8)))
}
```

Add tests for ANSI cell state, split UTF-8, 20,000-line scrollback, clear, session
separator, generation discard, renderer-state mapping, and disposal with queued
feed/reply/resize work. The disposal test blocks the serial lane with a test
gate, queues all three operation types, disposes the surface, opens the gate,
and asserts that none reaches the view or process callbacks.

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
swift test --filter ReadOnlySwiftTermViewTests
swift test --filter SwiftTermSurfaceTests
```

Expected: compilation fails because the SwiftTerm adapter does not exist.

- [ ] **Step 3: Implement read-only event suppression**

`ReadOnlySwiftTermView`:

- sets `allowMouseReporting = false`;
- sets `linkReporting = .none`;
- overrides `keyDown`, `keyUp`, and `doCommand` without forwarding input;
- overrides `insertText` and `setMarkedText` without forwarding or retaining composition;
- overrides `paste` as a no-op;
- returns `false` for paste validation and preserves copy/select-all validation;
- preserves inherited mouse selection, drag selection, scrolling, and `copy`;
- invokes an `onWindowAttachment` closure after `super.viewDidMoveToWindow()`.

Do not override `send(source: Terminal, data:)`; that inherited method carries
terminal protocol replies to `TerminalViewDelegate`.

- [ ] **Step 4: Implement the serialized SwiftTerm surface**

`SwiftTermSurface`:

- is `@unchecked Sendable`;
- constructs `ReadOnlySwiftTermView` on `MainActor`;
- calls `changeScrollback(20_000)`;
- owns `pendingGeneration`, `pendingChunks`, `activeGeneration`, and `disposed`
  exclusively on one serial queue;
- captures callback owners weakly and closes callback admission before releasing
  the view during `dispose`;
- `prepare` creates an empty pending queue;
- `feed` appends for pending or feeds SwiftTerm for active;
- `promote` emits `ESC[?1049l`, `ESC[!p`, CRLF, and the timestamped separator
  before flushing pending chunks;
- `discard` removes only the matching pending generation;
- `clear` feeds `ESC c` on the serial lane;
- delegate `send` invokes `writeProtocolReply(data, activeGeneration)`;
- delegate `sizeChanged` constructs `TerminalSize` from rows, columns, and
  backing-pixel dimensions, then invokes `resizePTY`;
- denies both OSC 52 delegate methods;
- performs one initial `setUseMetal(true)` after window attachment;
- publishes `.metal` only when `isUsingMetalRenderer == true`;
- publishes `.coreGraphicsFallback(error.localizedDescription)` after activation
  failure or SwiftTerm rebind fallback;
- never feeds fallback text into the PTY.

Do not schedule an additional main-thread draw for each chunk. SwiftTerm 1.15.0
already coalesces CoreGraphics work with `pendingDisplay` and Metal work with
`pendingMetalDisplay`; Aloft feeds every ordered byte on the serial lane and
lets those renderer coalescers submit the view updates.

- [ ] **Step 5: Verify GREEN**

Run:

```bash
swift test --filter ReadOnlySwiftTermViewTests
swift test --filter SwiftTermSurfaceTests
```

Expected: both suites pass with zero failures.

- [ ] **Step 6: Commit**

```bash
git add Sources/AloftApp/Terminal/SwiftTerm Tests/AloftAppTests/ReadOnlySwiftTermViewTests.swift Tests/AloftAppTests/SwiftTermSurfaceTests.swift
git commit -m "feat: add read only SwiftTerm Metal surface"
```

---

### Task 6: Integrate Restart, Clear, Protocol Replies, and Renderer Errors

**Files:**
- Create: `Sources/AloftApp/Output/SessionSeparator.swift`
- Modify: `Sources/AloftApp/Output/OutputPipeline.swift`
- Modify: `Sources/AloftApp/Stores/RuntimeStore.swift`
- Create: `Tests/AloftAppTests/SessionSeparatorTests.swift`
- Modify: `Tests/AloftAppTests/OutputPipelineTests.swift`
- Modify: `Tests/AloftProcessTests/RuntimeStoreTests.swift`
- Modify: `Tests/AloftProcessTests/RuntimeStoreConcurrencyTests.swift`

**Interfaces:**
- Produces: `SessionSeparator.line(at:)`.
- `OutputPipeline` and `SwiftTermSurface` use the same formatted line.
- `RuntimeStore.clearOutput` clears Text and Terminal.
- Current-generation terminal callback errors project to `EntryRuntime.lastError`.

- [ ] **Step 1: Write failing shared-separator and runtime tests**

```swift
func testSessionSeparatorUsesStableUTCFormat() {
    let date = Date(timeIntervalSince1970: 0)
    XCTAssertEqual(
        SessionSeparator.line(at: date),
        "──── Session started 1970-01-01 00:00:00 ────"
    )
}

@MainActor
func testClearOutputClearsBothBranchesWithoutStoppingProcess() async {
    let fixture = await runningRuntimeWithRecordingSurface()
    fixture.runtime.clearOutput(entryID: fixture.entry.id)

    XCTAssertEqual(fixture.runtime.runtime(for: fixture.entry.id).output.displayText, "")
    XCTAssertEqual(fixture.surface.clearCount, 1)
    XCTAssertEqual(
        fixture.runtime.runtime(for: fixture.entry.id).process.liveness,
        .running
    )
}
```

Add tests that:

- restart promotes exactly one terminal separator and preserves previous normal history;
- stale write/resize errors do not replace the current runtime error;
- current-generation Metal-unavailable state selects Text but leaves liveness running.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
swift test --filter SessionSeparatorTests
swift test --filter RuntimeStoreTests
swift test --filter RuntimeStoreConcurrencyTests
```

Expected: failures show the missing shared formatter and missing terminal clear/error behavior.

- [ ] **Step 3: Implement shared formatting and runtime behavior**

Move the current POSIX UTC formatter from `OutputPipeline.insertSessionSeparator`
into:

```swift
enum SessionSeparator {
    static func line(at timestamp: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return L10n.format(
            "──── Session started %@ ────",
            formatter.string(from: timestamp)
        )
    }
}
```

Update `clearOutput` to invoke `terminalSurface?.clear()`. Add
generation-checked callbacks in RuntimeStore:

```swift
TerminalSurfaceCallbacks(
    writeProtocolReply: { [processClient] data, generation in
        Task {
            try await processClient.write(entry.id, generation, data)
        }
    },
    resizePTY: { [processClient] size, generation in
        Task {
            try await processClient.resize(entry.id, generation, size)
        }
    }
)
```

Catch errors and project them on `MainActor` only when
`runtimeGenerations[entry.id] == generation`. Treat `.staleGeneration` and a
closed stopped process as expected no-ops.

- [ ] **Step 4: Verify GREEN**

Run:

```bash
swift test --filter SessionSeparatorTests
swift test --filter OutputPipelineTests
swift test --filter RuntimeStoreTests
swift test --filter RuntimeStoreConcurrencyTests
```

Expected: all focused suites pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AloftApp/Output Sources/AloftApp/Stores Tests/AloftAppTests Tests/AloftProcessTests
git commit -m "feat: integrate terminal session lifecycle"
```

---

### Task 7: Add the Terminal/Text Detail Interface

**Files:**
- Create: `Sources/AloftApp/Views/Output/TerminalOutputView.swift`
- Modify: `Sources/AloftApp/Views/Management/EntryDetailView.swift`
- Create: `Tests/AloftAppTests/TerminalSurfaceStub.swift`
- Create: `Tests/AloftAppTests/TerminalOutputViewTests.swift`
- Modify: `Tests/AloftAppTests/AppModelTests.swift`

**Interfaces:**
- Produces: `TerminalOutputView(surface:)`.
- `EntryDetailView` binds its segmented picker to `EntryRuntime.outputDisplayMode`.
- Terminal is default; surface-unavailable state selects Text.

- [ ] **Step 1: Write failing host-view and mode tests**

```swift
@MainActor
func testHostInstallsOneStableSurfaceViewAndResizesIt() {
    let native = NSView(frame: .zero)
    let surface = TerminalSurfaceStub(nativeView: native)
    let host = TerminalHostView(surface: surface)

    host.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
    host.layoutSubtreeIfNeeded()

    XCTAssertEqual(host.subviews, [native])
    XCTAssertEqual(native.frame, host.bounds)
}

@MainActor
func testNewEntryRuntimeDefaultsToTerminalMode() {
    XCTAssertEqual(EntryRuntime(entryID: UUID()).outputDisplayMode, .terminal)
}
```

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
swift test --filter TerminalOutputViewTests
swift test --filter AppModelTests/testNewEntryRuntimeDefaultsToTerminalMode
```

Expected: compilation fails because the host and UI mode behavior do not exist.

- [ ] **Step 3: Implement the stable AppKit host**

`TerminalHostView` owns one surface view and:

- removes it from an earlier superview before installation;
- pins it to all four bounds with autoresizing;
- does not recreate it during SwiftUI updates;
- leaves terminal row/column calculation to SwiftTerm's `setFrameSize`;
- reports no keyboard input itself.

`TerminalOutputView` is an `NSViewRepresentable` that creates the host once and
replaces the installed surface only when entry identity changes.

`Tests/AloftAppTests/TerminalSurfaceStub.swift` defines the App-test-only stub
used by `TerminalOutputViewTests` and `AppModelTests`. Do not import the
process-test target or reuse its `TerminalSurfaceRecorder`.

- [ ] **Step 4: Add the segmented selector and fallback status**

Replace the single `ReadOnlyOutputView` block with:

```swift
Picker(
    L10n.string("Output View"),
    selection: Binding(
        get: { entryRuntime.outputDisplayMode },
        set: { entryRuntime.outputDisplayMode = $0 }
    )
) {
    Text(L10n.string("Terminal")).tag(OutputDisplayMode.terminal)
    Text(L10n.string("Text")).tag(OutputDisplayMode.text)
}
.pickerStyle(.segmented)
```

Render `TerminalOutputView` when mode is Terminal and a surface exists.
Render `ReadOnlyOutputView` when mode is Text or no surface exists. Show a
nonmodal localized fallback label for `.coreGraphicsFallback` and
`.unavailable`.

Keep latest match, PID/PGID, action buttons, Clear Output, and Open in Ghostty
outside the mode switch.

- [ ] **Step 5: Verify GREEN**

Run:

```bash
swift test --filter TerminalOutputViewTests
swift test --filter AppModelTests
swift build
```

Expected: focused tests and the app build pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/AloftApp/Views Sources/AloftApp/Stores/EntryRuntime.swift Tests/AloftAppTests
git commit -m "feat: add terminal and text output modes"
```

---

### Task 8: Complete Lifecycle Disposal, Localization, and Accessibility

**Files:**
- Modify: `Sources/AloftApp/App/AppModel.swift`
- Modify: `Sources/AloftApp/App/AppDelegate.swift`
- Modify: `Sources/AloftApp/Stores/RuntimeStore.swift`
- Modify: `Sources/AloftApp/Views/Management/EntryDetailView.swift`
- Modify: all `Sources/AloftApp/Resources/*.lproj/Localizable.strings`
- Modify: `Tests/AloftAppTests/AppModelTests.swift`
- Modify: `Tests/AloftAppTests/MenuBarProjectionTests.swift`
- Modify: `Tests/AloftAppTests/LocalizationTests.swift`

**Interfaces:**
- Produces: `RuntimeStore.removeEntry(entryID:)`.
- Produces: `RuntimeStore.disposeAllTerminalSurfaces()`.
- Production bootstrap injects `.swiftTerm`; test RuntimeStore instances remain headless unless a factory is provided.
- Entry and group deletion dispose surfaces after persistence succeeds.
- Immediate or successfully deferred app termination disposes every surface;
  cancelled or rejected termination preserves every surface.

- [ ] **Step 1: Write failing lifecycle and localization tests**

```swift
@MainActor
func testDeletingEntryDisposesItsTerminalAfterWorkspaceDeletion() throws {
    let fixture = try makeModelWithRecordingTerminal()
    try fixture.model.deleteEntry(
        id: fixture.entry.id,
        in: fixture.group.id
    )
    XCTAssertEqual(fixture.surface.disposeCount, 1)
}

@MainActor
func testFailedWorkspaceDeletionDoesNotDisposeTerminal() throws {
    let fixture = try makeModelWithRecordingTerminal()
    let repositoryDirectory = fixture.configurationURL
        .deletingLastPathComponent()
    try FileManager.default.removeItem(at: repositoryDirectory)
    try Data("not-a-directory".utf8).write(to: repositoryDirectory)

    XCTAssertThrowsError(
        try fixture.model.deleteEntry(
            id: fixture.entry.id,
            in: fixture.group.id
        )
    )
    XCTAssertEqual(fixture.surface.disposeCount, 0)
    XCTAssertNotNil(fixture.model.entry(id: fixture.entry.id))
}

@MainActor
func testCancelledTerminationPreservesTerminalSurfaces() async {
    let fixture = try! makeModelWithRecordingTerminal()
    let replies = TerminationReplyRecorder()
    let delegate = AppDelegate(
        model: fixture.model,
        stopAllForTermination: { .cancelled },
        replyToTermination: replies.record
    )

    XCTAssertEqual(
        delegate.applicationShouldTerminate(.shared),
        .terminateLater
    )
    await replies.waitForReply()

    XCTAssertEqual(replies.values, [false])
    XCTAssertEqual(fixture.surface.disposeCount, 0)
}
```

Extend localization assertions with the exact English keys:

```swift
let v2Keys: Set<String> = [
    "Output View",
    "Terminal",
    "Text",
    "Metal rendering is unavailable. Using compatible rendering.",
    "Terminal rendering is unavailable. Showing text output.",
]
XCTAssertTrue(Set(try localization("en").keys).isSuperset(of: v2Keys))
```

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
swift test --filter AppModelTests/testDeletingEntryDisposesItsTerminalAfterWorkspaceDeletion
swift test --filter LocalizationTests
```

Expected: lifecycle API and localization-key failures.

- [ ] **Step 3: Implement disposal and production injection**

Add `RuntimeStore.removeEntry(entryID:)`:

- reject removal when the entry remains live or protected;
- dispose the terminal surface;
- remove output sessions, runtime generation, projection revision, operation
  lane, known entry, and observable runtime;
- clear the global match when it belongs to the removed entry.

Add `RuntimeStore.disposeAllTerminalSurfaces()` that calls `dispose()` once on
every retained surface and then clears the surface references. Make the method
idempotent.

In `AppModel.deleteEntry`, call `runtime.removeEntry` only after workspace
deletion succeeds. In `deleteGroup`, capture its entry IDs before persistence
and remove each runtime only after group deletion succeeds.

Change production bootstrap calls to:

```swift
RuntimeStore(
    supervisor: ProcessSupervisor(),
    terminalSurfaceFactory: .swiftTerm
)
```

Keep the default factory `nil` in test-oriented initializers.

In `AppDelegate.applicationShouldTerminate`, call
`disposeAllTerminalSurfaces()` before returning `.terminateNow`. In
`finishDeferredTermination`, call it only when
`completion.shouldTerminate == true`, immediately before replying to AppKit.
The `.cancelled` and `.remaining` branches retain every surface.

- [ ] **Step 4: Add every translation and accessibility label**

Add the complete English key set to all 11 `.lproj` files. Add accessibility
labels identifying:

- output mode selector;
- Metal renderer;
- compatible-renderer fallback;
- Text fallback;
- read-only terminal output.

Do not add a language preference.

- [ ] **Step 5: Verify GREEN**

Run:

```bash
swift test --filter AppModelTests
swift test --filter MenuBarProjectionTests
swift test --filter LocalizationTests
```

Expected: all lifecycle and localization tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/AloftApp/App Sources/AloftApp/Stores Sources/AloftApp/Views Sources/AloftApp/Resources Tests/AloftAppTests
git commit -m "feat: finish terminal lifecycle and localization"
```

---

### Task 9: Add Real PTY Terminal Integration Regressions

**Files:**
- Modify: `Tests/AloftProcessTests/ProcessSupervisorTests.swift`
- Modify: `Tests/AloftProcessTests/RuntimeStoreTests.swift`
- Create: `Tests/AloftProcessTests/TerminalPTYIntegrationTests.swift`

**Interfaces:**
- Exercises the production PTY, supervisor generation, SwiftTerm protocol reply,
  resize, stop, restart, and output fan-out together.

- [ ] **Step 1: Write the real integration tests**

Add tests that run actual shell commands:

```swift
@MainActor
func testCursorPositionQueryReceivesSwiftTermProtocolReply() async throws {
    let harness = try TerminalPTYIntegrationHarness(
        shell: "/bin/zsh",
        command: """
        printf '\\033[6n'
        IFS= read -r -d R reply
        printf 'ALOFT_DSR='
        printf '%sR' "$reply" | /usr/bin/od -An -tx1 | /usr/bin/tr -d ' \\n'
        printf '\\n'
        /bin/sleep 30
        """
    )
    defer { harness.forceStopForTestCleanup() }

    try await harness.start()

    XCTAssertTrue(
        try await harness.waitForOutput(
            prefix: "ALOFT_DSR=1b5b",
            timeout: .seconds(2)
        )
    )
}

@MainActor
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
    XCTAssertTrue(
        try await harness.waitForOutput(
            containing: "READY",
            timeout: .seconds(2)
        )
    )

    try await harness.resize(
        TerminalSize(
            columns: 121,
            rows: 41,
            pixelWidth: 1210,
            pixelHeight: 820
        )!
    )

    XCTAssertTrue(
        try await harness.waitForOutput(
            containing: "WINCH=41 121",
            timeout: .seconds(2)
        )
    )
}

@MainActor
func testStopRejectsSubsequentProtocolReplyAndResize() async throws {
    let harness = try TerminalPTYIntegrationHarness(
        shell: "/bin/zsh",
        command: "printf 'READY\\n'; /bin/sleep 30"
    )
    defer { harness.forceStopForTestCleanup() }
    try await harness.start()
    XCTAssertTrue(
        try await harness.waitForOutput(
            containing: "READY",
            timeout: .seconds(2)
        )
    )
    let callbacks = try XCTUnwrap(harness.activeCallbacks)

    XCTAssertTrue((await harness.stop()).isSuccess)
    callbacks.writeProtocolReply(Data("late".utf8), harness.generation)
    callbacks.resizePTY(
        TerminalSize(
            columns: 100,
            rows: 35,
            pixelWidth: 1000,
            pixelHeight: 700
        )!,
        harness.generation
    )
    await harness.waitForTerminalCallbackDrain(expectedCount: 2)

    XCTAssertEqual(
        harness.completedTerminalIOErrors,
        [.unknownEntry, .unknownEntry]
    )
    XCTAssertEqual(harness.runtime.process.liveness, .stopped)
    XCTAssertNil(harness.runtime.lastError)
    XCTAssertFalse(try harness.supervisorHasManagedProcess())
}

@MainActor
func testRestartPreservesTextAndTerminalHistoryWithOneSeparator() async throws {
    let harness = try TerminalPTYIntegrationHarness(
        shell: "/bin/zsh",
        command: "printf 'FIRST\\n'; /bin/sleep 30"
    )
    defer { harness.forceStopForTestCleanup() }
    try await harness.start()
    XCTAssertTrue(
        try await harness.waitForOutput(
            containing: "FIRST",
            timeout: .seconds(2)
        )
    )
    let separatorsBefore = harness.textOutput
        .components(separatedBy: "──── Session started ")
        .count - 1

    try await harness.restart(
        command: "printf 'SECOND\\n'; /bin/sleep 30"
    )
    XCTAssertTrue(
        try await harness.waitForOutput(
            containing: "SECOND",
            timeout: .seconds(2)
        )
    )

    let text = harness.textOutput
    let terminal = String(
        decoding: harness.swiftTermView.terminal.getBufferAsData(),
        as: UTF8.self
    )
    XCTAssertTrue(text.contains("FIRST"))
    XCTAssertTrue(text.contains("SECOND"))
    XCTAssertTrue(terminal.contains("FIRST"))
    XCTAssertTrue(terminal.contains("SECOND"))
    XCTAssertEqual(
        text.components(separatedBy: "──── Session started ").count - 1,
        separatorsBefore + 1
    )
}
```

Implement `TerminalPTYIntegrationHarness` in the same test file with these exact
properties and operations:

- a real `ProcessSupervisor`, `RuntimeStore`, `SwiftTermSurface`, and
  same-ID `CommandEntry`;
- `activeCallbacks`, `generation`, `runtime`, `textOutput`, and
  `swiftTermView`;
- `start()`, `restart(command:)`, `stop()`, and `resize(_:)`;
- readiness polling driven by output notifications and a `ContinuousClock`
  deadline, never by fixed sleeps;
- a `RuntimeProcessClient` wrapper that forwards to the real supervisor and
  records completion of terminal write/resize calls so
  `waitForTerminalCallbackDrain(expectedCount:)` is deterministic;
- `forceStopForTestCleanup()` as the only path permitted to send `SIGKILL`.

`waitForOutput(prefix:timeout:)` and `waitForOutput(containing:timeout:)` inspect
the existing Text projection. `swiftTermView` is obtained by casting the
surface's `nativeView` to `ReadOnlySwiftTermView`; terminal history is read with
SwiftTerm's public `terminal.getBufferAsData()` API.

- [ ] **Step 2: Run each test separately and verify RED**

Run:

```bash
swift test --filter TerminalPTYIntegrationTests/testCursorPositionQueryReceivesSwiftTermProtocolReply
swift test --filter TerminalPTYIntegrationTests/testResizeUpdatesSttyAndDeliversWINCH
swift test --filter TerminalPTYIntegrationTests/testStopRejectsSubsequentProtocolReplyAndResize
swift test --filter TerminalPTYIntegrationTests/testRestartPreservesTextAndTerminalHistoryWithOneSeparator
```

Expected: each test fails on the precise missing or incorrect integration behavior, not on fixture setup.

- [ ] **Step 3: Apply minimal integration corrections**

For each RED result:

- change only the production boundary named by the failure;
- retain generation checks;
- retain PTY ownership;
- do not add sleep-based correctness logic;
- use readiness markers and deadline polling in tests;
- keep `SIGKILL` confined to test cleanup.

- [ ] **Step 4: Verify GREEN and process regression**

Run:

```bash
swift test --filter TerminalPTYIntegrationTests
swift test --filter AloftProcessTests
swift test --filter ProcessLauncherTests
swift test --filter ProcessSupervisorTests
```

Expected: all real PTY and process tests pass with zero failures.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests/AloftProcessTests
git commit -m "test: cover terminal PTY integration"
```

---

### Task 10: Build the Release Performance Harness and Record the Baseline

**Files:**
- Modify: `Package.swift`
- Create: `Tests/AloftPerformanceTests/TerminalPerformanceTests.swift`
- Create: `script/run_terminal_benchmarks.sh`
- Create: `docs/performance/terminal-v2-baseline.md`

**Interfaces:**
- Produces: `ALOFT_RUN_PERFORMANCE_TESTS=1 swift test -c release --filter TerminalPerformanceTests`.
- Produces: JSON measurements and a committed Markdown baseline.
- Normal `swift test` skips performance cases with an explicit `XCTSkip`.

- [ ] **Step 1: Write the skipped-by-default benchmark tests**

Create a dedicated test target depending on `AloftApp` and SwiftTerm. The test
setup executes:

```swift
try XCTSkipUnless(
    ProcessInfo.processInfo.environment["ALOFT_RUN_PERFORMANCE_TESTS"] == "1",
    "Run through script/run_terminal_benchmarks.sh"
)
```

Implement deterministic payloads with SHA-256 digests:

- 100 MB plain UTF-8 lines;
- 100 MB ANSI colors and carriage-return progress;
- cursor-addressing screen updates;
- Unicode combining marks and emoji;
- continuous output while scrolling, resizing, switching Terminal/Text, and
  invoking start, stop, and restart controls.

For each payload, measure five release-mode repetitions of:

- `OutputPipeline.consume`;
- SwiftTerm CoreGraphics feed;
- SwiftTerm Metal feed in an attached `NSWindow`.

Record wall time, bytes per second, process CPU time, peak resident memory, and
worst main-thread stall. The end-to-end cases also record raw PTY drain
throughput, PTY-read-to-display-submission latency, frame pacing, and
scroll-response latency at the 20,000-line limit. Store all five values, median,
and worst value in JSON.

- [ ] **Step 2: Run default tests and verify the benchmark is skipped**

Run:

```bash
swift test --filter TerminalPerformanceTests
```

Expected: test suite succeeds with every performance case explicitly skipped.

- [ ] **Step 3: Implement the benchmark runner**

`script/run_terminal_benchmarks.sh`:

- requires a clean release build;
- exports `ALOFT_RUN_PERFORMANCE_TESTS=1`;
- sets an explicit output path under `artifacts/performance/`;
- runs the focused test target in release mode;
- records `system_profiler SPHardwareDataType` and `sw_vers`;
- records Xcode and SwiftTerm versions;
- leaves raw JSON and logs intact;
- never edits `config.json`.

- [ ] **Step 4: Run the release benchmark**

Run:

```bash
./script/run_terminal_benchmarks.sh
```

Expected: five measurements for every workload/backend combination, with a
nonempty raw JSON report and no test failure.

- [ ] **Step 5: Profile the measured slow path**

Run Time Profiler and Core Animation Instruments against the release app while
the benchmark fixture emits continuously. Record:

- top CPU consumers;
- main-thread blocking stacks;
- frame pacing;
- whether the limiting stack belongs to SwiftTerm, Aloft output processing, or
  PTY I/O.

Write the actual machine metadata, raw-report digest, median/worst table, and
Instruments attribution into
`docs/performance/terminal-v2-baseline.md`. State one evidence-backed decision:

- keep SwiftTerm;
- optimize a named Aloft component and rerun;
- start a separately scoped Ghostty spike.

- [ ] **Step 6: Commit the harness and measured report**

```bash
git add Package.swift Tests/AloftPerformanceTests script/run_terminal_benchmarks.sh docs/performance/terminal-v2-baseline.md
git commit -m "perf: add terminal release baseline"
```

---

### Task 11: Full Verification, Release Installation, and Acceptance

**Files:**
- Modify only files required by failures reproduced in this task.
- Verify: all source, tests, scripts, localization resources, and documentation.

**Interfaces:**
- Produces a release bundle that passes automated and manual V2 acceptance.

- [ ] **Step 1: Run formatting and complete automated tests**

Run:

```bash
git diff --check
swift test
```

Expected: zero diff errors and all non-performance tests pass; performance
tests report only their intentional default skips.

- [ ] **Step 2: Build and verify the release bundle**

Run:

```bash
swift build -c release
./script/build_and_run.sh --verify
```

Expected: release build and bundle verification exit zero.

- [ ] **Step 3: Exercise the required real commands**

From Finder-installed Aloft, verify:

- `pnpm start` uses the configured interactive login shell environment;
- ANSI colors and carriage-return progress render in Terminal;
- Text remains clean and searchable;
- selection and Command-C work in both modes;
- key input, paste, IME, link activation, OSC 52, and mouse reporting produce
  no PTY input;
- resize-aware output reports current rows and columns;
- stop and restart retain kernel-backed semantics;
- restart retains both histories with one separator;
- Clear Output clears both branches while the process remains live;
- simultaneous group output keeps the menu bar responsive;
- Metal activation is reported;
- forced Metal activation failure uses CoreGraphics;
- forced surface failure selects Text without stopping the process;
- all 11 system locales display the new labels.

- [ ] **Step 4: Re-run complete verification after acceptance fixes**

Every acceptance defect receives a failing automated regression before its
production fix. Then rerun:

```bash
git diff --check
swift test
swift build -c release
./script/build_and_run.sh --verify
```

Expected: every command exits zero.

- [ ] **Step 5: Review scope and commit final acceptance fixes**

Run:

```bash
git status --short
git diff --stat
git log --oneline --decorate -12
```

Confirm that every changed file maps to this plan and no generated performance
artifact or installed bundle is staged.

Write each acceptance regression in the nearest existing test file so this task
creates no new files. Commit only when acceptance produced tracked source
changes:

```bash
git add -u -- Sources Tests script docs
git diff --cached --name-only
git commit -m "fix: complete terminal v2 acceptance"
```

The branch is ready for final review only after fresh output proves all four
verification commands exit zero and the measured performance report contains a
backend decision.

# Process Termination Alerts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Report unexpected command exits and stop failures through persistent menu-bar attention items, command details, and native macOS notifications without misclassifying intentional termination.

**Architecture:** `RuntimeStore` owns termination records and a bounded attention queue. `AppModel` aggregates explicit action failures, while a protocol-backed UserNotifications service handles native delivery and routes notification clicks through a SwiftUI `openWindow` bridge. Only the monitoring path classifies a stopped generation as unexpected.

**Tech Stack:** Swift 6, SwiftUI, Observation, AppKit, UserNotifications, SwiftTerm, XCTest, Swift Package Manager, macOS 14+

## Global Constraints

- Do not launch, replace, terminate, or send signals to `/Applications/Aloft.app`.
- Preserve all pre-existing dirty-worktree changes. Implementation files overlap those changes, so do not stage or commit implementation work unless the user explicitly requests it.
- Keep the in-memory attention queue newest-first with a maximum of 50 items.
- Explicit Stop, Restart, Stop All, Restart All, and application termination never produce unexpected-exit notifications.
- Denied notification authorization never removes menu-bar or detail reporting.
- Do not add automatic `SIGKILL` escalation, notification settings, disk persistence, or keyword-match alerts.
- Add every new localization key to all eleven existing `.lproj` tables.

---

## File Structure

- Create `Sources/AloftApp/Models/ProcessTerminationNotice.swift` for termination records and attention values.
- Create `Sources/AloftApp/Services/UserNotificationService.swift` for the protocol-backed native notification adapter.
- Create `Sources/AloftApp/App/ManagementNotificationRouteBridge.swift` for notification click navigation.
- Modify `EntryRuntime.swift` and `RuntimeStore.swift` for retained termination state, classification, acknowledgement, and queue bounds.
- Modify `AppModel.swift`, `AppDelegate.swift`, and `AloftApp.swift` for failure aggregation, delivery wiring, and window routing.
- Modify `MenuBarContent.swift` and `EntryDetailView.swift` for persistent presentation.
- Modify all eleven localization tables.
- Extend `RuntimeStoreTests.swift`, `RuntimeStoreConcurrencyTests.swift`, `AppModelTests.swift`, `MenuBarProjectionTests.swift`, and `LocalizationTests.swift`.
- Create `UserNotificationServiceTests.swift` for Aloft's native-notification boundary.

---

### Task 1: Termination and Attention Domain Model

**Files:**
- Create: `Sources/AloftApp/Models/ProcessTerminationNotice.swift`
- Modify: `Sources/AloftApp/Stores/EntryRuntime.swift`
- Test: `Tests/AloftProcessTests/RuntimeStoreTests.swift`

**Interfaces:**
- Produces: `ProcessTerminationKind`, `ProcessTerminationRecord`, `RuntimeAttentionKind`, `RuntimeAttentionItem`, and `RuntimeOperationName`.
- Produces: `EntryRuntime.lastTermination: ProcessTerminationRecord?`.
- Consumes: existing `ChildWaitResult` and entry UUIDs.

- [ ] **Step 1: Write the failing retention test**

```swift
func testClearOutputRetainsLastTermination() {
    let runtime = RuntimeStore(supervisor: ProcessSupervisor())
    let entryID = UUID()
    let record = ProcessTerminationRecord(
        endedAt: Date(timeIntervalSince1970: 123),
        result: .exited(code: 17),
        kind: .unexpected,
        detail: "Exited with status 17."
    )
    runtime.runtime(for: entryID).lastTermination = record

    runtime.clearOutput(entryID: entryID)

    XCTAssertEqual(runtime.runtime(for: entryID).lastTermination, record)
}
```

This catches a production change that clears termination details together with terminal output.

- [ ] **Step 2: Run the test and verify RED**

```bash
swift test --filter RuntimeStoreTests/testClearOutputRetainsLastTermination
```

Expected: compilation fails because the record and property do not exist.

- [ ] **Step 3: Add the minimal model**

```swift
enum ProcessTerminationKind: Equatable, Sendable {
    case normal
    case unexpected
    case intentional
    case unavailable
}

struct ProcessTerminationRecord: Equatable, Sendable {
    let endedAt: Date
    let result: ChildWaitResult?
    let kind: ProcessTerminationKind
    let detail: String
}

enum RuntimeAttentionKind: Equatable, Sendable {
    case unexpectedTermination
    case operationFailure
}

struct RuntimeAttentionItem: Equatable, Identifiable, Sendable {
    let id: UUID
    let entryID: UUID?
    let kind: RuntimeAttentionKind
    let title: String
    let detail: String
    let createdAt: Date
    var isAcknowledged: Bool
}

enum RuntimeOperationName: Equatable, Sendable {
    case stop
    case restart
}
```

Add `var lastTermination: ProcessTerminationRecord?` to `EntryRuntime`. Leave `clearOutput` independent.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the Step 2 command. Expected: PASS.

- [ ] **Step 5: Prove a new start retains the prior termination**

Add a test that assigns a literal termination record, starts the entry with the
existing scripted client, and asserts the same record remains while the new
snapshot is running. Run:

```bash
swift test --filter RuntimeStoreTests/testNewStartRetainsPreviousTerminationUntilCurrentGenerationEnds
```

Expected RED: the test fails if start clears the new property. Expected GREEN:
the test passes without adding any clear in `startLocked`.

- [ ] **Step 6: Inspect only Task 1 files**

```bash
git diff -- Sources/AloftApp/Models/ProcessTerminationNotice.swift Sources/AloftApp/Stores/EntryRuntime.swift Tests/AloftProcessTests/RuntimeStoreTests.swift
```

Confirm the diff contains only model and retention behavior.

---

### Task 2: Classify Monitored Exits and Preserve Intentional Stops

**Files:**
- Modify: `Sources/AloftApp/Stores/RuntimeStore.swift`
- Modify: `Tests/AloftProcessTests/RuntimeStoreTests.swift`
- Modify: `Tests/AloftProcessTests/RuntimeStoreConcurrencyTests.swift`

**Interfaces:**
- Consumes: Task 1 models.
- Produces: `attentionItems`, `unacknowledgedAttentionItems`, `onAttention`, `acknowledgeAttention(id:)`, `acknowledgeAllAttention()`, and `recordOperationFailure(...)` on `RuntimeStore`.
- Produces: spontaneous-stop classification in `refreshAll()` only.

- [ ] **Step 1: Write failing monitored-exit tests**

Use the existing scripted client to start a generation, then return literal stopped snapshots:

```swift
func testMonitoredNonzeroExitRecordsAndPublishesOneAttention() async {
    let fixture = await makeTerminalRuntimeFixture()
    var delivered: [RuntimeAttentionItem] = []
    fixture.runtime.onAttention = { delivered.append($0) }
    XCTAssertTrue((await fixture.runtime.start(fixture.entry)).isSuccess)
    await fixture.process.setRefreshSnapshot(
        ProcessSnapshot(
            entryID: fixture.entry.id,
            pid: nil,
            processGroupID: nil,
            liveness: .stopped,
            launchedAt: .distantPast,
            exitResult: .exited(code: 17)
        )
    )

    await fixture.runtime.refreshAll()

    XCTAssertEqual(
        fixture.runtime.runtime(for: fixture.entry.id)
            .lastTermination?.result,
        .exited(code: 17)
    )
    XCTAssertEqual(fixture.runtime.unacknowledgedAttentionItems.count, 1)
    XCTAssertEqual(delivered.count, 1)
}
```

Add separate tests for `.exited(code: 0)`, `.signaled(signal: SIGABRT)`, and `nil`. Status `0` records a normal termination with no attention. These tests catch classifying all exits as failures, dropping signal results, and silently losing unavailable results.

- [ ] **Step 2: Run monitored tests and verify RED**

```bash
swift test --filter RuntimeStoreTests/testMonitored
```

Expected: compilation fails because the attention API does not exist.

- [ ] **Step 3: Implement queue and monitored classification**

```swift
private(set) var attentionItems: [RuntimeAttentionItem] = []
@ObservationIgnored
var onAttention: (@MainActor (RuntimeAttentionItem) -> Void)?

var unacknowledgedAttentionItems: [RuntimeAttentionItem] {
    attentionItems.filter { !$0.isAcknowledged }
}
```

`appendAttention` inserts at index zero, truncates to 50, and invokes `onAttention` exactly once. In `refreshAll`, classify and store the stopped snapshot before `finishStoppedOutput`. Use localized formatter helpers and never inspect terminal text.

For signal records, resolve a display name with Darwin `strsignal` when it
returns a non-null pointer, while always retaining the numeric signal. A null
pointer produces the numeric-only localized format.

- [ ] **Step 4: Run monitored tests and verify GREEN**

Run the Step 2 command. Expected: all four tests PASS.

- [ ] **Step 5: Write failing intentional-stop tests**

Configure Stop success followed by refresh `.signaled(signal: SIGTERM)`. Assert `lastTermination.kind == .intentional`, attention is empty, and the sink is not called. Add the same assertion around `stopManagedRecords`, which the application termination coordinator uses.

- [ ] **Step 6: Run intentional-stop tests and verify RED**

```bash
swift test --filter RuntimeStoreTests/testSuccessfulStopRecordsIntentionalTerminationWithoutAttention
swift test --filter RuntimeStoreTests/testStopManagedRecordsDoesNotPublishUnexpectedTermination
```

Expected: assertions fail because successful stop does not record intentional termination.

- [ ] **Step 7: Record intentional termination inside successful stop paths**

In `stopLocked`, after the verified stopped refresh, assign an intentional record before clearing output. Never call `appendAttention`. Keep `adoptManagedSnapshot` free of unexpected-exit reporting so application-termination enumeration stays silent.

- [ ] **Step 8: Run Task 2 suites**

```bash
swift test --filter RuntimeStoreTests
swift test --filter RuntimeStoreConcurrencyTests
```

Expected: both suites PASS.

- [ ] **Step 9: Prove queue bounds, acknowledgement, and deletion cleanup**

Append 51 literal items, assert only the newest 50 remain, acknowledge one and
all, and assert unacknowledged counts change without deleting history. Create an
item for a stopped entry, call `removeEntry(entryID:)`, and assert every item for
that entry is removed. Run:

```bash
swift test --filter RuntimeStoreTests/testAttention
swift test --filter RuntimeStoreTests/testRemovingEntryRemovesItsAttentionItems
```

Expected RED before cleanup logic: the queue exceeds 50 or deleted-entry items
remain. Expected GREEN after minimal queue and removal logic: all tests PASS.

---

### Task 3: Aggregate Stop and Restart Failures

**Files:**
- Modify: `Sources/AloftApp/App/AppModel.swift`
- Modify: `Sources/AloftApp/Stores/RuntimeStore.swift`
- Modify: `Tests/AloftAppTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `recordOperationFailure(operation:entries:results:)` from Task 2.
- Produces: unchanged task-returning AppModel APIs whose bodies publish one item after awaiting failures.

- [ ] **Step 1: Write failing single and group failure tests**

Extend `ModelProcessClient` with literal stop results. For two failures:

```swift
let task = try XCTUnwrap(model.stopGroup(id: group.id))
let results = await task.value

XCTAssertEqual(results.filter { !$0.isSuccess }.count, 2)
XCTAssertEqual(model.runtime.unacknowledgedAttentionItems.count, 1)
let detail = try XCTUnwrap(
    model.runtime.unacknowledgedAttentionItems.first?.detail
)
XCTAssertTrue(detail.contains("Frontend"))
XCTAssertTrue(detail.contains("API"))
```

Add single Stop and Restart failure cases. These catch discarded task results, per-entry notification spam, and omitted restart failures.

- [ ] **Step 2: Run focused AppModel tests and verify RED**

```bash
swift test --filter AppModelTests/testFailed
swift test --filter AppModelTests/testGroupStopPublishesOneAggregatedAttention
```

Expected: attention assertions fail.

- [ ] **Step 3: Implement operation-failure aggregation**

The RuntimeStore method filters failed results, renders details in entry order, appends exactly one `.operationFailure` item, and returns without mutation for an empty failure list. Wrap `stopEntry`, `restartEntry`, `stopGroup`, and `restartGroup` task bodies:

```swift
return Task { @MainActor in
    let results = await runtime.stopAll(entries, reservation: reservation)
    runtime.recordOperationFailure(
        operation: .stop,
        entries: entries,
        results: results
    )
    return results
}
```

Do not call this method from `TerminationCoordinator`.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the Step 2 commands. Expected: PASS.

- [ ] **Step 5: Run AppModelTests**

```bash
swift test --filter AppModelTests
```

Expected: PASS with reservation behavior unchanged.

---

### Task 4: Menu-Bar Attention and Command Detail

**Files:**
- Modify: `Sources/AloftApp/App/AloftApp.swift`
- Modify: `Sources/AloftApp/Views/MenuBar/MenuBarContent.swift`
- Modify: `Sources/AloftApp/Views/Management/EntryDetailView.swift`
- Modify: `Tests/AloftAppTests/MenuBarProjectionTests.swift`

**Interfaces:**
- Consumes: unacknowledged items, acknowledgement methods, and `lastTermination`.
- Produces: `MenuBarAttentionProjection`, projected items, and observable `attentionCount`.

- [ ] **Step 1: Write failing projection and observation tests**

Use literal items to assert newest-first order, configured-entry filtering, 30-character titles, and status-label invalidation when acknowledgement changes. These catch a stale count, deleted entries remaining actionable, and acknowledgement leaving the indicator visible.

- [ ] **Step 2: Run projection tests and verify RED**

```bash
swift test --filter MenuBarProjectionTests
```

Expected: compilation fails because attention projections do not exist.

- [ ] **Step 3: Implement projection and menu rendering**

Update the status label to render an attention indicator and count while preserving the running count. Add above keyword matches:

```swift
if !projection.attentionItems.isEmpty {
    Divider()
    Text(L10n.string("Needs Attention"))
    ForEach(projection.attentionItems) { item in
        Button(item.title) {
            model.runtime.acknowledgeAttention(id: item.id)
            openManagement(entryID: item.entryID)
        }
    }
    Button(L10n.string("Clear All")) {
        model.runtime.acknowledgeAllAttention()
    }
}
```

An aggregate item has no entry ID and opens management without changing selection.

- [ ] **Step 4: Add the retained termination card**

Render a neutral card for normal/intentional and an error-toned card for unexpected/unavailable. Read only `lastTermination`, never terminal output or `lastError`.

- [ ] **Step 5: Run menu tests and verify GREEN**

```bash
swift test --filter MenuBarProjectionTests
```

Expected: PASS.

---

### Task 5: Native Notification Delivery and Click Routing

**Files:**
- Create: `Sources/AloftApp/Services/UserNotificationService.swift`
- Create: `Sources/AloftApp/App/ManagementNotificationRouteBridge.swift`
- Modify: `Sources/AloftApp/App/AppDelegate.swift`
- Modify: `Sources/AloftApp/App/AppModel.swift`
- Modify: `Sources/AloftApp/App/AloftApp.swift`
- Create: `Tests/AloftAppTests/UserNotificationServiceTests.swift`

**Interfaces:**
- Produces: `UserNotificationDelivering` with `requestAuthorization()`, `deliver(_:)`, and `onOpenEntry`.
- Produces: `ManagementRouteRequest` and consume-once AppModel routing.
- Consumes: RuntimeStore `onAttention`.

- [ ] **Step 1: Write failing notification adapter tests**

Inject a center recorder, deliver one literal item, and assert Aloft generates localized title/body plus `entryID.uuidString` in `userInfo`. Feed a response and assert `onOpenEntry` receives the UUID once. This tests Aloft's boundary, not Apple's framework.

- [ ] **Step 2: Run adapter tests and verify RED**

```bash
swift test --filter UserNotificationServiceTests
```

Expected: compilation fails because the service does not exist.

- [ ] **Step 3: Implement the native adapter**

Use `UNUserNotificationCenter`, request `[.alert, .sound]`, and return `[.banner, .sound]` from foreground presentation. Decode response routing through `Task { @MainActor in ... }` to preserve Swift 6 actor isolation. Delivery failures leave persistent attention untouched.

- [ ] **Step 4: Run adapter tests and verify GREEN**

Run the Step 2 command. Expected: PASS without real permission prompts.

- [ ] **Step 5: Write failing AppDelegate and route tests**

Inject a notification recorder into AppDelegate. Assert normal launch requests authorization once, runtime attention delivers once, and response creates one route. Test route consumption selects the entry and invokes a captured open action exactly once.

- [ ] **Step 6: Run route tests and verify RED**

```bash
swift test --filter AppDelegateNotificationTests
swift test --filter ManagementNotificationRouteTests
```

Expected: compilation or assertions fail because wiring does not exist.

- [ ] **Step 7: Wire launch, delivery, and SwiftUI navigation**

Inject the production service by default. During non-benchmark launch request authorization. Forward `runtime.onAttention` to delivery and `onOpenEntry` to a model route. Attach the bridge to the continuously realized menu-bar label; it consumes a route, selects the entry, opens `management`, and uses `ManagementWindowPresenter` for activation.

- [ ] **Step 8: Run notification and window suites**

```bash
swift test --filter UserNotificationServiceTests
swift test --filter AppDelegateNotificationTests
swift test --filter ManagementNotificationRouteTests
swift test --filter ManagementWindowPresenterTests
```

Expected: PASS.

---

### Task 6: Localization and Full Verification

**Files:**
- Modify: all eleven `Sources/AloftApp/Resources/*.lproj/Localizable.strings` files
- Modify: `Tests/AloftAppTests/LocalizationTests.swift`

**Interfaces:**
- Consumes: display strings from Tasks 2-5.
- Produces: identical nonempty key sets across all localization tables.

- [ ] **Step 1: Write the failing English-key coverage test**

Add a literal set containing `Needs Attention`, `Clear All`, normal/nonzero/signal/unavailable exit formats, Stop/Restart failure summaries, and notification titles. Assert English contains the entire set.

- [ ] **Step 2: Run localization tests and verify RED**

```bash
swift test --filter LocalizationTests
```

Expected: the new-key assertion fails.

- [ ] **Step 3: Add all eleven translations**

Keep format placeholders identical to English. Pass dynamic names, codes, PGIDs, and signal values as format arguments.

- [ ] **Step 4: Run localization tests and verify GREEN**

Run the Step 2 command. Expected: all localization tests PASS, including key parity and nonempty values.

- [ ] **Step 5: Run fresh complete verification**

```bash
swift test
swift build -c release
git diff --check
```

Required evidence: every command exits `0`; report exact test count, skipped count, build result, and diff-check result.

- [ ] **Step 6: Audit installed-app isolation and worktree scope**

```bash
ps -axo pid,lstart,command | rg '/Applications/Aloft\.app/Contents/MacOS/Aloft|PID'
git status --short
```

Confirm the installed app was not signaled or replaced. List implementation files separately from pre-existing dirty-worktree files. Do not install the Release build.

# Aloft v2 Terminal Design

Date: 2026-07-29

Status: approved in conversation; pending document review

This specification supersedes the dependency and renderer proposal in
section 13 of the Aloft v1 design. The v1 process ownership, kernel-backed
liveness, grouping, shell launch, persistence, localization, keyword matching,
and Ghostty companion-shell behavior remain unchanged unless this document
explicitly replaces them.

## 1. Goal

Aloft v2 adds terminal-grade rendering to each managed command while retaining
the existing plain-text output view.

The first v2 milestone delivers:

- SwiftTerm 1.15.0 as the terminal engine and native AppKit terminal view;
- SwiftTerm's Metal renderer enabled by default;
- ANSI colors, terminal cells, cursor, scrollback, selection, copy, and
  resizing;
- a Terminal/Text display switch, defaulting to Terminal;
- existing plain-text search and keyword matching without behavior changes;
- read-only user interaction in Terminal mode;
- standards-based PTY writes for terminal protocol replies;
- explicit fallback from Metal to CoreGraphics and then to the existing Text
  view;
- a backend-neutral boundary that supports a later Ghostty implementation;
- an end-to-end performance benchmark after functional development.

The technology decision is based on delivery scope, not a claim that SwiftTerm
matches Ghostty's performance. No published, like-for-like SwiftTerm Metal
versus Ghostty macOS benchmark exists as of this design date.

## 2. Dependency Decision

### 2.1 Selected dependency

The package uses:

```swift
.package(
    url: "https://github.com/migueldeicaza/SwiftTerm",
    exact: "1.15.0"
)
```

The `AloftApp` executable target depends on the `SwiftTerm` library product.
The exact version prevents an upstream update from changing terminal behavior
or rendering during an Aloft build.

SwiftTerm 1.15.0 is the latest tagged stable release on the design date. It is
MIT licensed. Aloft includes the required SwiftTerm license notice in its
distribution.

### 2.2 Metal definition

SwiftTerm 1.15.0 uses the existing Metal/MetalKit API:

- `MTKView`;
- `MTLCreateSystemDefaultDevice`;
- `MTLCommandQueue`;
- a CoreText glyph atlas;
- Metal quads;
- dirty-row caching;
- per-row persistent GPU buffers by default.

It does not use the Metal 4 `MTL4*` command API. Aloft does not fork SwiftTerm
to replace this renderer with Metal 4.

SwiftTerm labels its macOS Metal path as experimental and disables it by
default. Aloft calls `setUseMetal(true)` after the terminal view enters an
`NSWindow`, verifies `isUsingMetalRenderer`, and exposes a fallback when Metal
initialization or window rebinding fails.

### 2.3 Why Ghostty is deferred

Ghostty's embeddable `libghostty-vt` supplies terminal parsing and state. It
does not supply Ghostty's macOS Metal view as a drop-in component. Selecting it
for this milestone would require Aloft to own:

- a pinned Zig/C build;
- a Swift/C bridge;
- a complete AppKit terminal surface;
- selection and copy behavior;
- a CoreText renderer or an immediate custom Metal renderer;
- renderer correctness and performance maintenance.

Ghostty remains the replacement candidate when Aloft profiling identifies
SwiftTerm parsing or rendering as the limiting component.

## 3. Architecture

The existing POSIX process path remains authoritative:

```text
CommandEntry
    |
    v
ProcessSupervisor
    |
    v
ManagedProcess <------ resize / protocol replies
    |
    +------ raw PTY bytes ------> OutputPipeline
    |                            |-- clean text
    |                            |-- keyword matching
    |                            `-- Text view
    |
    `------ raw PTY bytes ------> TerminalSurface
                                 |-- SwiftTerm state
                                 |-- Metal view
                                 `-- CoreGraphics fallback
```

Raw PTY bytes fan out without mutation. `OutputPipeline` continues to strip
terminal control sequences for plain text and matching. `TerminalSurface`
receives the original bytes, including split UTF-8 and terminal escape
sequences.

`AloftProcess`, `ProcessSupervisor`, and `ManagedProcess` retain ownership of
launching, file descriptors, process groups, liveness, signals, and shutdown.
SwiftTerm never launches or owns an Aloft command. Aloft does not use
SwiftTerm's `LocalProcessTerminalView`.

## 4. Terminal Compatibility Boundary

Aloft defines a backend-neutral terminal boundary. SwiftTerm types stay inside
the SwiftTerm adapter and AppKit bridge.

The conceptual interface is:

```swift
protocol TerminalSurface: AnyObject {
    var nativeView: NSView { get }
    var rendererState: TerminalRendererState { get }

    func feed(_ data: Data, generation: UUID)
    func resize(_ size: TerminalSize, generation: UUID)
    func beginSession(at timestamp: Date, generation: UUID)
    func clear()
    func dispose()
}
```

Supporting types contain no SwiftTerm symbols:

```text
TerminalSize
├── columns
├── rows
├── pixelWidth
└── pixelHeight

TerminalRendererState
├── metal
├── coreGraphicsFallback(reason)
└── unavailable(reason)
```

The production implementation is `SwiftTermSurface`. A
`TerminalSurfaceFactory` constructs it and owns fallback decisions. Tests use a
fake surface without importing SwiftTerm.

No SwiftTerm type appears in:

- `CommandEntry`;
- persisted configuration;
- `ManagedProcess`;
- `ProcessSupervisor`;
- `RuntimeProcessClient`;
- `EntryRuntime`;
- keyword matching;
- menu-bar projections.

A later Ghostty implementation replaces the surface factory and terminal
adapter. It does not replace the POSIX process layer or output pipeline.

## 5. Session and Generation Ownership

Each entry has at most one retained terminal surface. The surface is created
when the entry first starts and remains available after the process stops so
the user can inspect its scrollback.

Every process start receives a new generation UUID. The generation is attached
to:

- raw PTY output;
- PTY writes;
- terminal resize requests;
- the terminal surface session;
- the existing plain-text output session.

Output, writes, resize callbacks, and renderer updates from a superseded
generation are discarded. This extends the existing RuntimeStore generation
rule to the terminal branch.

Raw terminal bytes that arrive before a start operation returns are held by an
ordered, generation-scoped pending sink. They do not mutate the retained
surface. After a successful start, Aloft binds the retained surface to the new
generation, applies the session boundary, and flushes the pending chunks in
order. A failed or superseded launch discards its pending sink and leaves the
currently displayed completed session unchanged.

Deleting an entry disposes its terminal surface. Quitting Aloft disposes all
surfaces only after managed-process termination completes and Aloft has accepted
termination. If termination is cancelled or live processes remain, the surfaces
stay attached to their entries. Terminal history is memory-only and is not
restored after Aloft relaunches.

## 6. PTY Read, Write, and Resize

### 6.1 Reading

`ManagedProcess` continues draining the nonblocking PTY master on its dedicated
dispatch source. Terminal rendering never performs PTY reads and never blocks
the read source.

The same immutable `Data` chunk is delivered to:

1. the generation-scoped `OutputPipeline`;
2. the generation-scoped `TerminalSurface`.

Terminal feed work is serialized per surface. It does not run synchronously on
the SwiftUI main actor. SwiftTerm documents its `feed` entrypoint as callable
from a background thread and schedules display work onto the main thread.

### 6.2 Writing

`ManagedProcess` gains a serialized nonblocking write path for the PTY master.
It uses POSIX `write` and handles:

- partial writes;
- `EINTR` by retrying;
- `EAGAIN` by waiting for writable readiness;
- close/write races without writing to a reused descriptor;
- stale generations by rejection.

SwiftTerm's `TerminalViewDelegate.send(source:data:)` handles terminal protocol
replies such as device-status and cursor-position responses. Aloft writes
these bytes to the managed PTY through the generation-scoped write path.

User keyboard input, paste, mouse reporting, and drag-and-drop input are
disabled in this milestone. Protocol replies remain enabled because a
read-only terminal emulator must still complete terminal protocol exchanges.

### 6.3 Resizing

The AppKit bridge derives rows and columns from the terminal view's content
size and cell geometry. A changed size performs both operations:

1. resize SwiftTerm's terminal state;
2. call `ioctl(masterFD, TIOCSWINSZ, &winsize)` with rows, columns, pixel
   width, and pixel height.

The terminal driver delivers `SIGWINCH` to the foreground process group. Aloft
does not synthesize a resize by printing commands or injecting shell text.

Duplicate size notifications are coalesced. A resize callback from an old
generation is ignored.

## 7. Read-Only Terminal Interaction

`ReadOnlySwiftTermView` subclasses SwiftTerm's macOS `TerminalView`.

It allows:

- mouse selection;
- Command-C and the Copy menu item;
- scrolling and scrollbar interaction;
- focus for accessibility and copy;
- text cursor rendering;
- terminal protocol replies.

It blocks:

- character and key-sequence input;
- Command-V and paste menu actions;
- input-method composition;
- drag-and-drop text input;
- terminal mouse protocol reports.

When an application enables terminal mouse tracking, Aloft retains local
selection behavior instead of forwarding mouse events to the managed process.

OSC 52 clipboard reads and writes are denied. User-initiated copying of a
selection remains enabled. Implicit link activation is disabled in the first
milestone.

Interactive keyboard, paste, and terminal mouse protocols belong to the next
terminal milestone and reuse the PTY write path established here.

## 8. Terminal State Behavior

### 8.1 Scrollback

SwiftTerm scrollback is set to 20,000 lines to match the existing
`OutputPipeline` line limit. Terminal and Text buffers are independent views of
the same original PTY stream.

When the user is at the bottom, new output follows the process. When the user
scrolls upward, new output does not change the visible viewport. Returning to
the bottom resumes following.

### 8.2 Restart

Restart retains normal-buffer terminal history.

Before bytes from the replacement process are accepted, the surface:

1. leaves the alternate screen;
2. performs a terminal soft reset;
3. inserts a timestamped session separator;
4. binds the surface to the new generation.

The Text branch retains its existing separator and prior lines. Synthetic
terminal reset and separator bytes are not sent to `OutputPipeline` and cannot
create keyword matches.

### 8.3 Clear

Clear Output performs one logical action:

- reset SwiftTerm to an empty initial terminal state;
- clear terminal scrollback, selection, images, cursor modes, and search state;
- clear the existing plain-text output and keyword marker for the entry;
- clear the latest global match when it belongs to the entry;
- leave the managed process running.

New process output continues in both views after the clear.

### 8.4 Stopped entries

A stopped entry retains both Terminal and Text history. Device replies and
resizes are rejected after its managed PTY closes.

## 9. User Interface

The entry detail view adds a segmented display selector:

```text
[ Terminal | Text ]
```

- Terminal is selected by default.
- The choice is retained per entry for the current Aloft process.
- It is not persisted to `config.json`.
- Switching views does not recreate process or output state.

All new labels, fallback messages, errors, accessibility descriptions, and
benchmark-facing UI strings are added to every existing Aloft localization.
Aloft continues selecting language exclusively from the macOS locale and adds
no in-app language selector.

Terminal mode displays:

- terminal colors and attributes;
- cursor and cell grid;
- selection and copy;
- scrollback;
- Metal/CoreGraphics renderer status when a fallback occurred.

Text mode retains:

- cleaned output;
- existing AppKit find bar;
- text selection and copy;
- current auto-scroll behavior;
- existing keyword-match presentation.

The latest keyword match remains above the output surface in both modes.
Process controls, PID/PGID, errors, editing, Clear Output, and Open in Ghostty
remain in their existing locations.

If Metal falls back to CoreGraphics, the terminal remains usable and an
inline, nonmodal status identifies the fallback. If the terminal surface is
unavailable, Aloft selects Text and shows the terminal error without stopping
the command.

## 10. Renderer Fallback

Renderer selection follows:

```text
construct SwiftTerm TerminalView
    |
attach to NSWindow
    |
setUseMetal(true)
    | success and isUsingMetalRenderer
    v
Metal
    |
    | initialization or window-rebind failure
    v
SwiftTerm CoreGraphics
    |
    | terminal view construction/feed failure
    v
existing Text view
```

Metal remains the default for every newly created surface. A failure is scoped
to the affected surface and does not disable Metal globally.

Fallback never:

- stops or restarts the process;
- clears terminal or Text output;
- changes kernel-backed liveness;
- changes keyword matching;
- writes fallback messages into the PTY.

## 11. Threading and Backpressure

The PTY read source, terminal feed lane, PTY write lane, and main-thread draw
work have separate responsibilities:

- the read source drains bytes;
- the terminal feed lane mutates terminal state in order;
- the write lane serializes protocol replies;
- the main thread presents AppKit and Metal updates;
- `RuntimeStore` projects Text snapshots and match events.

No terminal draw waits on keyword matching. No keyword match waits on a Metal
frame. Slow UI presentation does not stop PTY draining.

The implementation coalesces main-thread view updates while retaining every
ordered byte for terminal parsing and every logical-line revision for keyword
matching.

Terminal surface callbacks capture weak owners. Disposal closes callback
admission before releasing the view, preventing queued feed, write, and resize
work from acting on a deleted entry or reused file descriptor.

## 12. Performance Validation

SwiftTerm is selected for integration speed and native functionality. Aloft
makes no Ghostty-equivalent performance claim without measurements.

After functional completion, a release-mode benchmark records:

- raw PTY drain throughput;
- terminal parser/feed throughput;
- time from PTY read to submitted display update;
- main-thread CPU time;
- total process CPU;
- peak resident memory;
- frame pacing and main-thread stalls;
- scroll responsiveness at the 20,000-line limit.

The deterministic workloads are:

1. 100 MB of plain UTF-8 log lines;
2. 100 MB of ANSI color and carriage-return progress updates;
3. full-screen cursor-addressing updates;
4. Unicode, combining-mark, and emoji-heavy output;
5. continuous output while scrolling, resizing, switching Terminal/Text, and
   invoking process controls.

Each workload runs against:

- existing Text;
- SwiftTerm CoreGraphics;
- SwiftTerm Metal.

The report includes the machine, macOS, Xcode, build configuration, SwiftTerm
version, workload digest, repetitions, and raw measurements. Median and worst
observed results are reported; a single best run is not used.

The benchmark does not automatically trigger a dependency change. A Ghostty
spike begins only when Instruments attributes the unacceptable CPU, memory,
latency, or frame behavior to SwiftTerm parsing or rendering. If profiling
attributes the bottleneck to Aloft's PTY drain, output copying, keyword
matching, or main-actor projection, Aloft fixes that component instead.

The user reviews the first measured report and sets the release budget from
observed behavior on the target Mac. Subsequent releases use that budget as a
regression gate.

## 13. Testing Strategy

Development follows red-green-refactor.

### 13.1 Dependency and adapter tests

- the package resolves exactly SwiftTerm 1.15.0;
- no SwiftTerm symbol escapes the adapter/UI files;
- the factory selects Metal after successful activation;
- failed Metal activation selects CoreGraphics;
- unavailable terminal construction selects Text;
- fallback preserves process and output state.

### 13.2 Terminal surface tests

- raw bytes reach the terminal unchanged and in order;
- ANSI colors and cursor addressing produce expected terminal cells;
- split UTF-8 and escape sequences remain correct;
- scrollback is limited to 20,000 lines;
- restart leaves the alternate buffer, soft-resets modes, preserves normal
  history, and inserts one separator;
- Clear Output removes terminal and Text history while the process continues;
- a stale generation cannot feed, resize, write, or replace the current
  surface;
- Terminal/Text switching preserves both buffers.

### 13.3 Read-only interaction tests

- mouse selection and Command-C work;
- key input and paste produce no PTY write;
- input-method and drag input produce no PTY write;
- terminal mouse tracking produces no PTY mouse report;
- a terminal device query produces the required PTY protocol reply;
- OSC 52 cannot read or write the system clipboard.

### 13.4 POSIX integration tests

- partial PTY writes complete in order;
- `EINTR` retries;
- `EAGAIN` resumes on writable readiness;
- close/write races do not touch a reused descriptor;
- `TIOCSWINSZ` updates `stty size`;
- the foreground process observes resize through `SIGWINCH`;
- stopped and superseded generations reject writes and resizes;
- stop and restart preserve existing process-group guarantees.

### 13.5 Manual verification

Release-mode verification covers:

- `pnpm start` launched from Finder-installed Aloft;
- ANSI build output;
- carriage-return progress output;
- a resize-aware command;
- selection and copy in Terminal and Text;
- search in Text;
- terminal history across stop and restart;
- Clear Output while running;
- Metal activation and renderer-state display;
- forced Metal failure and CoreGraphics fallback;
- terminal-surface failure and Text fallback;
- simultaneous output from multiple entries;
- group Start All, Stop All, and Restart All;
- menu-bar liveness and latest keyword match during terminal output.

Fresh verification commands remain:

```text
swift test
swift build
./script/build_and_run.sh --verify
```

The performance harness runs from a separate documented release-mode command
and stores its report outside the application configuration.

## 14. Security and Privacy

- SwiftTerm receives only bytes already read from Aloft's managed PTY.
- Aloft does not send terminal history to a network service.
- OSC 52 clipboard access is denied.
- Implicit link opening is disabled.
- Protocol replies write only to the owning generation's PTY.
- Terminal history remains in memory and follows the existing process lifetime.
- No additional sandbox entitlement or Automation permission is introduced.
- Open in Ghostty remains the separate, existing AppleScript companion action.

## 15. Explicit Exclusions

The first v2 terminal milestone excludes:

- user keyboard input;
- paste and input-method composition;
- terminal mouse reporting;
- drag-and-drop input;
- exact Ghostty behavior or performance parity;
- Ghostty's Metal renderer;
- a custom Metal 4 renderer;
- terminal output persistence across Aloft launches;
- reattachment to processes after Aloft crashes;
- multiple terminal panes or tabs per entry;
- attaching an external Ghostty window to Aloft's PTY;
- a performance claim before the benchmark report;
- terminal graphics protocols as an acceptance requirement.

## 16. Delivery Sequence

Implementation follows this order:

1. pin SwiftTerm and add the backend-neutral surface types;
2. add generation-safe PTY write and resize operations;
3. add SwiftTerm feed integration and lifecycle ownership;
4. add read-only AppKit behavior;
5. enable Metal and implement fallback reporting;
6. add Terminal/Text UI switching;
7. implement restart, clear, and scrollback semantics;
8. complete unit and POSIX integration tests;
9. perform release-mode manual verification;
10. run and publish the performance report;
11. decide from profiling evidence whether SwiftTerm remains the production
    backend or a Ghostty spike starts.

No Ghostty migration work starts before step 10 produces measurements and
Instruments identifies SwiftTerm as the bottleneck.

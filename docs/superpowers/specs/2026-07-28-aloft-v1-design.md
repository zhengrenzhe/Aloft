# Aloft v1 Design

Date: 2026-07-28

## 1. Goal

Aloft v1 is a native macOS menu bar application for defining, grouping,
starting, monitoring, stopping, and restarting long-running local commands
such as `npm run dev`.

The first release prioritizes immediate daily use:

- native menu bar controls;
- multiple groups and multiple command entries per group;
- configurable name, working directory, command, and keywords;
- standards-based POSIX process and process-group control;
- kernel-backed liveness checks;
- live plain-text output;
- keyword matches surfaced in the menu bar;
- optional Ghostty companion shells.

Full terminal rendering with `libghostty-vt` is reserved for v2. The v1
architecture keeps the process, output, and matching layers independent from
the renderer so v2 can replace the plain-text renderer without changing
process ownership.

## 2. Supported Platform and Distribution Shape

- Deployment target: macOS 14 or newer.
- UI stack: SwiftUI with focused AppKit bridges.
- Package shape: SwiftPM executable packaged as `Aloft.app`.
- Application mode: menu-bar-only accessory app with `LSUIElement = true`.
- Dock behavior: no Dock icon.
- Sandbox: disabled because Aloft executes user-authored commands in
  user-selected directories.
- Signing, notarization, automatic updates, and App Store distribution are
  outside v1.

The repository contains a single project-local run entrypoint at
`script/build_and_run.sh`. It builds the SwiftPM product, stages
`dist/Aloft.app`, and launches that bundle. The Codex Run action calls the same
script through `.codex/environments/environment.toml`.

## 3. User Experience

### 3.1 Menu bar

The menu bar item is always present while Aloft is running. Its label shows the
number of live entries when the count is nonzero. The menu contains:

- the current live-entry count;
- live groups and entries;
- the latest keyword match, truncated to 30 visible characters;
- group-level Start All, Stop All, and Restart All actions;
- Open Aloft;
- Quit Aloft.

Selecting a live entry or keyword match opens the management window and selects
the corresponding entry. The full matched line is displayed in the detail
view.

All menu labels remain short and scannable. Full commands, paths, output, and
match text stay in the management window.

### 3.2 Management window

The management window uses a three-column native macOS layout:

1. Group sidebar
   - group name;
   - live-entry count;
   - add, rename, delete, and reorder groups;
   - group Start All, Stop All, and Restart All actions.
2. Entry list
   - entry name;
   - concise live state;
   - add, edit, delete, and reorder entries;
   - entry Start, Stop, and Restart actions.
3. Entry detail
   - name, cwd, and command summary;
   - kernel-backed process status;
   - Start, Stop, Restart, Edit, Clear Output, and Open in Ghostty;
   - latest keyword match;
   - read-only live output.

The output view uses an AppKit `NSTextView` bridge for efficient incremental
append, selection, copy, search, and automatic scrolling. It uses the system
monospaced font and adaptive system colors.

### 3.3 Entry editor

The entry editor is a sheet with:

- required name;
- required cwd text field;
- native `NSOpenPanel` folder picker;
- required command;
- zero or more literal keywords.

Saving validates that the name and command are nonempty and that cwd exists and
is a directory. Launch repeats cwd validation so a directory removed after
editing produces a launch error instead of undefined behavior.

## 4. Persisted Model

The durable model is:

```text
WorkspaceConfiguration
└── groups: [CommandGroup]
    ├── id: UUID
    ├── name: String
    ├── order: Int
    └── entries: [CommandEntry]
        ├── id: UUID
        ├── name: String
        ├── cwd: String
        ├── command: String
        ├── keywords: [String]
        └── order: Int
```

Runtime state, output, PIDs, process-group IDs, and match events are never
encoded into the configuration file.

Configuration is stored at:

```text
~/Library/Application Support/Aloft/config.json
```

Writes use an encoded temporary file followed by an atomic rename in the same
directory. A missing file loads an empty configuration. A malformed file is
preserved, reported to the user, and never overwritten until the user
explicitly saves a valid configuration.

## 5. Process Architecture

### 5.1 POSIX launch path

A small C target owns the child-side launch sequence. Swift prepares all C
strings and environment data before calling into the launcher. The child calls
only async-signal-safe or direct POSIX/Darwin system functions between `fork`
and `exec`.

Each launch follows:

```text
openpty
→ fork
→ child: setsid
→ child: ioctl(TIOCSCTTY)
→ child: dup2(slave, STDIN/STDOUT/STDERR)
→ child: chdir(cwd)
→ child: execve("/bin/zsh", ["zsh", "-l", "-c", command], environment)
→ parent: close(slave) and read(master)
```

The noninteractive login shell supplies normal login PATH initialization while
keeping shell job control disabled. The session leader PID is also the initial
process-group ID. Descendants launched by the noninteractive shell remain in
that group unless the command explicitly creates another session or process
group.

A close-on-exec error pipe reports `setsid`, controlling-terminal, `dup2`,
`chdir`, and `execve` failures to the parent with the original `errno`.

### 5.2 Runtime ownership

`ProcessSupervisor` owns one `ManagedProcess` per entry. Each entry serializes
its start, stop, and restart operations so two launches for the same entry
cannot overlap.

Runtime identity includes:

- direct child PID;
- process-group ID;
- PTY master file descriptor;
- launch timestamp;
- last direct-child exit result.

### 5.3 Real liveness monitoring

Displayed liveness comes from the operating system:

- `waitpid(pid, ..., WNOHANG)` reports the direct child exit result;
- `killpg(pgid, 0)` probes whether the managed process group still exists;
- return value `0` or `EPERM` means the group exists;
- `ESRCH` means the group no longer exists.

The supervisor probes on demand before every action and on a one-second timer
while any entry has a known process-group ID. UI state is a projection of the
latest kernel probe, not a transition-only state machine.

If the shell leader exits while another member of the managed group remains,
the entry stays live until `killpg(pgid, 0)` returns `ESRCH`.

### 5.4 Stop

Stop performs:

1. refresh kernel liveness;
2. send `SIGTERM` with `killpg`;
3. wait for group disappearance for up to five seconds;
4. close the PTY after the group exits;
5. report success only after `killpg(pgid, 0)` returns `ESRCH`.

A group that remains live after five seconds is reported as “Did not stop.”
Aloft never sends `SIGKILL` in production.

### 5.5 Restart

Restart performs Stop and then Start. If Stop times out, restart is aborted and
the existing process group remains the active instance.

### 5.6 Group operations

Group Start All, Stop All, and Restart All invoke the corresponding serialized
operation on every entry in the group concurrently. Results are collected per
entry and failures do not prevent other entries from completing their action.

### 5.7 Application termination

Normal Quit initiates Stop for every live entry concurrently and returns
`.terminateLater` from the application delegate.

- If every process group disappears within five seconds, Aloft completes
  termination.
- If any process group remains, Aloft cancels termination and displays the
  names and PGIDs of all remaining groups.
- No `SIGKILL` fallback is provided.

v1 has no helper daemon and no process reattachment. An abnormal Aloft crash
does not provide a cleanup guarantee. On the next launch, Aloft has no output
channel or ownership record for processes left by an abnormal crash.

## 6. Output Pipeline

The PTY combines standard output and standard error exactly as a terminal does.
The parent reads the PTY master on a dedicated dispatch source.

Each byte passes through one streaming pipeline:

```text
PTY bytes
→ incremental UTF-8 decoding
→ stateful ANSI/OSC filtering
→ logical-line assembly
├── keyword matching and match events
└── in-memory line buffer and NSTextView updates
```

The filter handles sequences split across read boundaries:

- CSI sequences;
- OSC sequences terminated by BEL or ST;
- single-character escape sequences;
- UTF-8 code points split across chunks.

Carriage return replaces the current unfinished logical line. Newline commits
the current logical line. Keyword matching observes every cleaned logical-line
revision before a later carriage return replaces it, so transient terminal
text remains matchable even though the plain-text display shows only the latest
revision.

Each entry retains the latest 20,000 committed lines plus its current
unfinished line in memory. When the limit is exceeded, complete oldest lines
are discarded. Output is not written to disk in v1.

Restart inserts a timestamped session separator and retains the prior in-memory
lines. Clear Output removes the in-memory lines and match markers for that
entry without affecting the process.

## 7. Keyword Matching

- An entry supports multiple keywords.
- Empty keywords are rejected.
- Matching is a case-sensitive literal substring search.
- Regular expressions are outside v1.
- A match event contains entry ID, keyword, complete cleaned logical line, and
  timestamp.
- Each entry retains its latest match event.
- The app retains one latest global match event for the menu bar.

The menu bar never executes an action based on a match. Matching only changes
displayed attention information in v1.

## 8. Ghostty Companion Integration

Ghostty integration is optional and never participates in managed-process
ownership.

Open in Ghostty:

1. checks for `/Applications/Ghostty.app`;
2. reads and validates that the installed version is at least 1.3;
3. uses Ghostty's native AppleScript dictionary to create a new terminal
   window with the entry cwd;
4. leaves the new terminal at an interactive shell prompt.

The first invocation triggers the standard macOS Automation permission flow.
Missing Ghostty, an unsupported version, denied Automation permission, and
AppleScript errors are presented in the entry detail view.

The Ghostty terminal is a separate shell. It never attaches to, mirrors,
signals, or monitors the process managed by Aloft.

## 9. Error Handling

Launch errors are structured by phase:

- validation;
- PTY creation;
- fork;
- session creation;
- controlling-terminal setup;
- file-descriptor setup;
- cwd change;
- shell exec.

The entry detail shows the phase and system error text. Failed launches do not
create a live runtime record.

Other error rules:

- Start on a live entry is rejected.
- Stop on a dead entry refreshes state and returns success without signaling an
  unrelated reused PID.
- Restart never launches a replacement until the old process group is proven
  absent.
- Deleting a live entry is blocked until Stop succeeds.
- Deleting a group containing live entries is blocked until every Stop
  succeeds.
- Persistence errors keep the last in-memory configuration and display an
  actionable error.

## 10. File and Module Boundaries

```text
Package.swift
Sources/
├── AloftApp/
│   ├── App/
│   │   ├── AloftApp.swift
│   │   └── AppDelegate.swift
│   ├── Models/
│   │   ├── CommandEntry.swift
│   │   ├── CommandGroup.swift
│   │   └── WorkspaceConfiguration.swift
│   ├── Stores/
│   │   ├── WorkspaceStore.swift
│   │   └── RuntimeStore.swift
│   ├── Services/
│   │   ├── ConfigurationRepository.swift
│   │   ├── ProcessSupervisor.swift
│   │   ├── ManagedProcess.swift
│   │   ├── OutputPipeline.swift
│   │   ├── ANSITextFilter.swift
│   │   ├── KeywordMatcher.swift
│   │   └── GhosttyService.swift
│   ├── Views/
│   │   ├── MenuBar/
│   │   ├── Management/
│   │   ├── EntryEditor/
│   │   └── Output/
│   └── Support/
│       └── AppPaths.swift
└── AloftProcess/
    ├── include/AloftProcess.h
    └── AloftProcess.c
Tests/
├── AloftAppTests/
└── AloftProcessTests/
script/build_and_run.sh
.codex/environments/environment.toml
```

The process launcher is the only C module. Swift owns models, orchestration,
output processing, persistence, and UI.

## 11. Test Strategy

Development follows red-green-refactor. Tests are added before production
behavior.

### 11.1 Unit tests

- model JSON round-trip;
- malformed configuration preservation;
- atomic repository replacement;
- ANSI CSI sequences split at every byte boundary;
- OSC BEL and ST termination split across chunks;
- UTF-8 scalars split across chunks;
- carriage-return line replacement;
- 20,000-line truncation;
- case-sensitive keyword behavior;
- keyword match across read boundaries;
- match before carriage-return replacement.

### 11.2 POSIX integration tests

Tests launch real subprocesses:

- cwd is applied;
- stdout and stderr arrive through one PTY;
- direct-child PID and PGID are reported;
- `killpg(pgid, 0)` detects a live group;
- natural exit is observed by `waitpid`;
- `SIGTERM` stops a shell and descendant;
- restart creates a new PID and PGID;
- a process that traps `SIGTERM` reaches the five-second timeout;
- test-only cleanup removes intentionally resistant test processes after the
  timeout assertion.

### 11.3 Store and group tests

- duplicate start rejection;
- stop on an already-dead group;
- restart abort after stop timeout;
- concurrent group actions collect all results;
- quit completes only after all groups disappear;
- quit cancellation reports every remaining entry.

### 11.4 Build and manual verification

Release claims require fresh successful runs of:

```text
swift test
swift build
./script/build_and_run.sh --verify
```

Manual verification covers:

- menu bar status and controls;
- group and entry creation;
- folder picker;
- live output and autoscroll;
- menu keyword match navigation;
- management-window restoration;
- Ghostty Automation permission and companion-shell creation;
- quitting with responsive and SIGTERM-resistant commands.

## 12. Explicit v1 Exclusions

- `libghostty` and `libghostty-vt`;
- interactive terminal input;
- terminal cell rendering;
- ANSI colors in the output view;
- output persistence across app launches;
- regular-expression match rules;
- automatic actions triggered by matches;
- environment-variable editor;
- shell selection;
- login-item installation;
- helper daemon;
- process reattachment after Aloft exits or crashes;
- remote commands;
- app sandboxing;
- signing, notarization, and automatic updates.

## 13. v2 Compatibility

v2 adds a `TerminalRenderer` backed by a pinned `libghostty-vt` XCFramework.
The existing PTY byte stream continues to feed output persistence and keyword
matching before also feeding the terminal parser.

The following v1 boundaries remain unchanged:

- `AloftProcess` owns PTY and process creation;
- `ProcessSupervisor` owns signals and liveness;
- `OutputPipeline` owns the original byte stream;
- persisted groups and entries keep the same identifiers;
- Ghostty companion shells remain separate processes.

This preserves exact process ownership and keyword matching while upgrading the
detail view from cleaned plain text to terminal-grade rendering.

# Process Termination Alerts Design

Date: 2026-08-03

## Goal

Aloft reports process termination failures and unexpected command exits without
forcing its management window to the foreground. The report remains available
in the menu bar and command detail after terminal output is cleared.

## User-visible behavior

### Exit classification

- A command that exits on its own with status `0` records “Exited normally
  (0)” in its detail. It does not create an attention item or system
  notification.
- A command that exits on its own with a nonzero status creates an attention
  item containing the command name and exit status.
- A command that exits on its own because of a signal creates an attention item
  containing the command name, signal number, and signal name when Darwin can
  resolve one.
- A process group that disappears without a wait status records an unavailable
  exit reason and creates an attention item.
- A successful explicit Stop, Restart, Stop All, Restart All, or application
  termination is intentional. Its `SIGTERM` result does not create an
  unexpected-exit attention item.

### Presentation

- Every unexpected exit is stored as an unacknowledged attention item.
- The menu-bar label includes an attention indicator while any item is
  unacknowledged.
- The menu contains a “Needs Attention” section. Selecting an item opens the
  matching command detail and acknowledges that item. A “Clear All” action
  acknowledges every item.
- The command detail keeps a separate last-termination card. Clearing terminal
  output does not clear this card.
- Aloft requests macOS notification authorization once during normal app
  startup. Each unexpected exit is sent through UserNotifications. Denied or
  disabled authorization does not remove the persistent menu/detail report.
- Selecting a delivered system notification routes to the matching command and
  opens the management window. Foreground delivery uses a banner instead of a
  modal alert.

### Stop failures

- A single Stop or Restart failure keeps the existing per-command red error
  card and adds one attention item.
- A group Stop All or Restart All operation aggregates all failed entries into
  one attention item. It does not emit one system notification per entry.
- The aggregated item contains every failed command name and error text.
- Application quit retains its existing modal warning and refuses termination
  while managed process groups remain. This flow does not also emit a system
  notification.

## Architecture

### Runtime data

`EntryRuntime` gains an optional last-termination record containing the end
time, raw `ChildWaitResult`, classification, and localized display text.
`RuntimeStore` owns a bounded collection of attention items with stable IDs and
acknowledgement state. Removing a command also removes its attention items.

The monitoring path is the only path that classifies a newly observed stopped
snapshot as an unexpected exit. Explicit stop/restart and termination
coordinator paths write intentional termination records without passing through
unexpected-exit reporting. This boundary prevents a requested `SIGTERM` from
being reported as a crash.

### Notification delivery

A small protocol-backed notification service wraps
`UNUserNotificationCenter`. `AppDelegate` configures authorization and forwards
new unexpected-exit attention items to the service. Tests inject a recorder;
production code uses the native center.

Notification response routing uses an in-process route containing the command
UUID. A SwiftUI bridge owns `openWindow`, selects the command in `AppModel`, and
then uses `ManagementWindowPresenter` so the existing reliable foreground
activation behavior is preserved.

### Group action reporting

`AppModel` awaits the existing `EntryActionResult` values and creates one
aggregate attention item when a group action has failures. The RuntimeStore
continues to own the per-entry error strings. Callers still receive the original
task result, so existing control flow remains compatible.

## Data retention

- Keep at most 50 attention items, newest first.
- Acknowledgement removes an item from the active attention count while the
  command detail retains its last termination record.
- Starting a new generation clears the command’s previous transient
  `lastError`; it does not erase the last-termination record until the new
  generation ends.
- Deleting a command or group removes its termination record and associated
  attention items.

## Localization

All new user-facing strings are added to the existing eleven localization
tables. Dynamic command names, exit codes, PGIDs, and signal numbers are passed
through format placeholders rather than translated.

## Tests

Tests are written before production changes and must demonstrate these paths:

1. Monitoring a spontaneous status `0` stores a normal termination and creates
   no attention item.
2. Monitoring a spontaneous nonzero status creates one persistent attention
   item and calls the notification sink once.
3. Monitoring a spontaneous signal exit records the signal and notifies once.
4. Explicit Stop, Restart, and application termination never classify their
   resulting `SIGTERM` as unexpected.
5. Stop timeout creates a persistent failure item and retains process output.
6. Group stop failures create one aggregate item containing every failed entry.
7. Menu projection exposes attention count/items and acknowledgement updates
   the projection.
8. Notification response routing selects the matching command and invokes the
   management-window open action.
9. Last-termination detail survives terminal clearing and a new process start.
10. Localization key parity remains green for every supported language.

Final verification consists of the focused red-green test runs, full
`swift test`, `swift build -c release`, and `git diff --check`. Verification
does not launch, replace, or terminate `/Applications/Aloft.app`.

## Out of scope

- Automatic `SIGKILL` escalation.
- A notification preferences screen.
- Persisting attention history across Aloft launches.
- Treating keyword matches as termination alerts.

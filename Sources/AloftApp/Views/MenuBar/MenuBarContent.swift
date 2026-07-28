import AppKit
import Foundation
import SwiftUI

struct MenuBarEntryProjection: Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
}

struct MenuBarGroupProjection: Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let liveEntries: [MenuBarEntryProjection]
}

struct MenuBarMatchProjection: Equatable, Identifiable, Sendable {
    var id: UUID {
        entryID
    }

    let entryID: UUID
    let title: String
}

struct MenuBarProjection: Equatable, Sendable {
    static let maximumTitleLength = 30

    let runningCount: Int
    let groupMenus: [MenuBarGroupProjection]
    let latestMatch: MenuBarMatchProjection?

    init(
        groups: [CommandGroup],
        liveEntryIDs: Set<UUID>,
        latestMatch: KeywordMatchEvent?
    ) {
        runningCount = liveEntryIDs.count
        groupMenus = groups
            .sorted(by: Self.groupPrecedes)
            .map { group in
                let liveEntries = group.entries
                    .filter { liveEntryIDs.contains($0.id) }
                    .sorted(by: Self.entryPrecedes)
                    .map {
                        MenuBarEntryProjection(
                            id: $0.id,
                            title: Self.truncated($0.name)
                        )
                    }
                let suffix = " (\(liveEntries.count))"
                return MenuBarGroupProjection(
                    id: group.id,
                    title: Self.truncated(
                        group.name,
                        reservingSpaceFor: suffix
                    ) + suffix,
                    liveEntries: liveEntries
                )
            }
        self.latestMatch = latestMatch.map {
            MenuBarMatchProjection(
                entryID: $0.entryID,
                title: Self.truncated($0.line)
            )
        }
    }

    private static func truncated(
        _ source: String,
        reservingSpaceFor suffix: String = ""
    ) -> String {
        let availableCount = max(
            0,
            maximumTitleLength - suffix.count
        )
        return String(source.prefix(availableCount))
    }

    private static func groupPrecedes(
        _ lhs: CommandGroup,
        _ rhs: CommandGroup
    ) -> Bool {
        if lhs.order != rhs.order {
            return lhs.order < rhs.order
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func entryPrecedes(
        _ lhs: CommandEntry,
        _ rhs: CommandEntry
    ) -> Bool {
        if lhs.order != rhs.order {
            return lhs.order < rhs.order
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

@MainActor
struct MenuBarContent: View {
    @Bindable var model: AppModel

    @Environment(\.openWindow) private var openWindow

    private var projection: MenuBarProjection {
        MenuBarProjection(
            groups: model.orderedGroups,
            liveEntryIDs: model.runtime.liveEntryIDs,
            latestMatch: model.runtime.latestGlobalMatch
        )
    }

    var body: some View {
        Text("Running: \(projection.runningCount)")

        Divider()

        ForEach(projection.groupMenus) { group in
            Menu(group.title) {
                if group.liveEntries.isEmpty {
                    Text("No Running Commands")
                } else {
                    ForEach(group.liveEntries) { entry in
                        Button(entry.title) {
                            openManagement(entryID: entry.id)
                        }
                    }
                }

                Divider()

                Button("Start All") {
                    _ = model.startGroup(id: group.id)
                }
                Button("Stop All") {
                    _ = model.stopGroup(id: group.id)
                }
                .disabled(group.liveEntries.isEmpty)
                Button("Restart All") {
                    _ = model.restartGroup(id: group.id)
                }
                .disabled(group.liveEntries.isEmpty)
            }
        }

        if let latestMatch = projection.latestMatch {
            Divider()

            Text("Latest Match")
            Button(latestMatch.title) {
                openManagement(entryID: latestMatch.entryID)
            }
        }

        Divider()

        Button("Open Aloft") {
            openManagement(entryID: nil)
        }
        Button("Quit Aloft") {
            NSApplication.shared.terminate(nil)
        }
    }

    private func openManagement(entryID: UUID?) {
        if let entryID {
            model.selectEntry(entryID)
        }
        openWindow(id: "management")
        NSApp.activate(ignoringOtherApps: true)
    }
}

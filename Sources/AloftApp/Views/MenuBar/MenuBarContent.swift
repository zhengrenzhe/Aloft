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

struct MenuBarAttentionProjection: Equatable, Identifiable, Sendable {
    let id: UUID
    let entryID: UUID?
    let title: String
}

struct MenuBarProjection: Equatable, Sendable {
    static let maximumTitleLength = 30

    let runningCount: Int
    let groupMenus: [MenuBarGroupProjection]
    let latestMatch: MenuBarMatchProjection?
    let attentionItems: [MenuBarAttentionProjection]

    init(
        groups: [CommandGroup],
        liveEntryIDs: Set<UUID>,
        latestMatch: KeywordMatchEvent?,
        attentionItems: [RuntimeAttentionItem] = []
    ) {
        let configuredEntryIDs = Set(
            groups.flatMap(\.entries).map(\.id)
        )
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
        self.latestMatch = latestMatch.flatMap {
            guard configuredEntryIDs.contains($0.entryID) else {
                return nil
            }
            return MenuBarMatchProjection(
                entryID: $0.entryID,
                title: Self.truncated($0.line)
            )
        }
        self.attentionItems = attentionItems
            .filter { item in
                guard !item.isAcknowledged else {
                    return false
                }
                guard let entryID = item.entryID else {
                    return true
                }
                return configuredEntryIDs.contains(entryID)
            }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .map {
                MenuBarAttentionProjection(
                    id: $0.id,
                    entryID: $0.entryID,
                    title: Self.truncated($0.title)
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
            latestMatch: model.runtime.latestGlobalMatch,
            attentionItems: model.runtime.attentionItems
        )
    }

    var body: some View {
        Text(
            L10n.format(
                "Running: %lld",
                projection.runningCount
            )
        )

        Divider()

        ForEach(projection.groupMenus) { group in
            Menu(group.title) {
                if group.liveEntries.isEmpty {
                    Text(L10n.string("No Running Commands"))
                } else {
                    ForEach(group.liveEntries) { entry in
                        Button(entry.title) {
                            openManagement(entryID: entry.id)
                        }
                    }
                }

                Divider()

                Button(L10n.string("Start All")) {
                    _ = model.startGroup(id: group.id)
                }
                Button(L10n.string("Stop All")) {
                    _ = model.stopGroup(id: group.id)
                }
                .disabled(group.liveEntries.isEmpty)
                Button(L10n.string("Restart All")) {
                    _ = model.restartGroup(id: group.id)
                }
                .disabled(group.liveEntries.isEmpty)
            }
        }

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

        if let latestMatch = projection.latestMatch {
            Divider()

            Text(L10n.string("Latest Match"))
            Button(latestMatch.title) {
                openManagement(entryID: latestMatch.entryID)
            }
        }

        Divider()

        Button(L10n.string("Open Aloft")) {
            openManagement(entryID: nil)
        }
        SettingsLink()
        Button(L10n.string("Quit Aloft")) {
            NSApplication.shared.terminate(nil)
        }
    }

    private func openManagement(entryID: UUID?) {
        if let entryID {
            model.selectEntry(entryID)
        }
        ManagementWindowPresenter().present {
            openWindow(id: "management")
        }
    }
}

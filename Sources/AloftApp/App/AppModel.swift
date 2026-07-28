import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let workspace: WorkspaceStore
    let runtime: RuntimeStore
    let ghostty: GhosttyService

    var selectedGroupID: UUID?
    var selectedEntryID: UUID?
    var presentedError: String?

    var orderedGroups: [CommandGroup] {
        workspace.configuration.groups.sorted {
            if $0.order != $1.order {
                return $0.order < $1.order
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    var selectedGroup: CommandGroup? {
        orderedGroups.first { $0.id == selectedGroupID }
    }

    var selectedEntry: CommandEntry? {
        selectedGroup?.entries.first { $0.id == selectedEntryID }
    }

    init(
        workspace: WorkspaceStore,
        runtime: RuntimeStore,
        ghostty: GhosttyService
    ) {
        self.workspace = workspace
        self.runtime = runtime
        self.ghostty = ghostty
        repairSelection()
    }

    static func bootstrap() -> AppModel {
        do {
            return bootstrap(
                configurationURL: try AppPaths.configurationURL()
            )
        } catch {
            return fallbackModel(loadError: error)
        }
    }

    static func bootstrap(configurationURL: URL) -> AppModel {
        let repository = ConfigurationRepository(
            fileURL: configurationURL
        )
        do {
            return AppModel(
                workspace: try WorkspaceStore(repository: repository),
                runtime: RuntimeStore(
                    supervisor: ProcessSupervisor()
                ),
                ghostty: GhosttyService()
            )
        } catch {
            let model = AppModel(
                workspace: WorkspaceStore(
                    repository: repository,
                    initialConfiguration: .empty
                ),
                runtime: RuntimeStore(
                    supervisor: ProcessSupervisor()
                ),
                ghostty: GhosttyService()
            )
            model.presentedError = error.localizedDescription
            return model
        }
    }

    func selectGroup(_ groupID: UUID?) {
        selectedGroupID = groupID
        selectedEntryID = nil
        repairSelection()
    }

    func selectEntry(_ entryID: UUID) {
        for group in orderedGroups {
            guard group.entries.contains(
                where: { $0.id == entryID }
            ) else {
                continue
            }
            selectedGroupID = group.id
            selectedEntryID = entryID
            return
        }
        repairSelection()
    }

    @discardableResult
    func addGroup(name: String) throws -> UUID {
        let id = try workspace.addGroup(name: name)
        selectedGroupID = id
        selectedEntryID = nil
        repairSelection()
        return id
    }

    func updateGroup(id: UUID, name: String) throws {
        try workspace.updateGroup(id: id, name: name)
        repairSelection()
    }

    func deleteGroup(id: UUID) throws {
        let groupsBeforeDeletion = orderedGroups
        let deletedIndex = groupsBeforeDeletion.firstIndex {
            $0.id == id
        }
        let deletingSelection = selectedGroupID == id

        try workspace.deleteGroup(
            id: id,
            liveEntryIDs: runtime.liveEntryIDs
        )

        if deletingSelection {
            let groups = orderedGroups
            if let deletedIndex, !groups.isEmpty {
                selectedGroupID = groups[
                    min(deletedIndex, groups.count - 1)
                ].id
            } else {
                selectedGroupID = nil
            }
            selectedEntryID = nil
        }
        repairSelection()
    }

    func moveGroups(
        fromOffsets: IndexSet,
        toOffset: Int
    ) throws {
        try workspace.moveGroups(
            fromOffsets: fromOffsets,
            toOffset: toOffset
        )
        repairSelection()
    }

    @discardableResult
    func addEntry(
        to groupID: UUID,
        name: String,
        cwd: String,
        command: String,
        keywords: [String]
    ) throws -> UUID {
        let id = try workspace.addEntry(
            to: groupID,
            name: name,
            cwd: cwd,
            command: command,
            keywords: keywords
        )
        selectedGroupID = groupID
        selectedEntryID = id
        repairSelection()
        return id
    }

    func updateEntry(
        id: UUID,
        in groupID: UUID,
        name: String,
        cwd: String,
        command: String,
        keywords: [String]
    ) throws {
        try workspace.updateEntry(
            id: id,
            in: groupID,
            name: name,
            cwd: cwd,
            command: command,
            keywords: keywords
        )
        repairSelection()
    }

    func deleteEntry(id: UUID, in groupID: UUID) throws {
        let entriesBeforeDeletion = orderedEntries(in: groupID)
        let deletedIndex = entriesBeforeDeletion.firstIndex {
            $0.id == id
        }
        let deletingSelection = selectedEntryID == id

        try workspace.deleteEntry(
            id: id,
            in: groupID,
            isLive: runtime.liveEntryIDs.contains(id)
        )

        if deletingSelection, selectedGroupID == groupID {
            let entries = orderedEntries(in: groupID)
            if let deletedIndex, !entries.isEmpty {
                selectedEntryID = entries[
                    min(deletedIndex, entries.count - 1)
                ].id
            } else {
                selectedEntryID = nil
            }
        }
        repairSelection()
    }

    func moveEntries(
        in groupID: UUID,
        fromOffsets: IndexSet,
        toOffset: Int
    ) throws {
        try workspace.moveEntries(
            in: groupID,
            fromOffsets: fromOffsets,
            toOffset: toOffset
        )
        repairSelection()
    }

    func repairSelection() {
        let groups = orderedGroups
        guard !groups.isEmpty else {
            selectedGroupID = nil
            selectedEntryID = nil
            return
        }

        if !groups.contains(where: { $0.id == selectedGroupID }) {
            selectedGroupID = groups[0].id
        }
        guard let group = groups.first(
            where: { $0.id == selectedGroupID }
        ) else {
            selectedGroupID = nil
            selectedEntryID = nil
            return
        }
        let entries = orderedEntries(in: group)
        if !entries.contains(where: { $0.id == selectedEntryID }) {
            selectedEntryID = entries.first?.id
        }
    }

    func orderedEntries(in groupID: UUID) -> [CommandEntry] {
        guard let group = orderedGroups.first(
            where: { $0.id == groupID }
        ) else {
            return []
        }
        return orderedEntries(in: group)
    }

    func openSelectedEntryInGhostty() {
        guard let selectedEntry else { return }
        do {
            try ghostty.openShell(cwd: selectedEntry.cwd)
        } catch {
            presentedError = error.localizedDescription
        }
    }

    private func orderedEntries(
        in group: CommandGroup
    ) -> [CommandEntry] {
        group.entries.sorted {
            if $0.order != $1.order {
                return $0.order < $1.order
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func fallbackModel(loadError: Error) -> AppModel {
        let repository = ConfigurationRepository(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("Aloft-\(UUID().uuidString)")
                .appendingPathComponent("config.json")
        )
        let model = AppModel(
            workspace: WorkspaceStore(
                repository: repository,
                initialConfiguration: .empty
            ),
            runtime: RuntimeStore(supervisor: ProcessSupervisor()),
            ghostty: GhosttyService()
        )
        model.presentedError = loadError.localizedDescription
        return model
    }
}

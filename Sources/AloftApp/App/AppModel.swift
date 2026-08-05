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
    var pendingManagementRoute: ManagementRouteRequest?

    var orderedGroups: [CommandGroup] {
        workspace.configuration.groups
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
                    supervisor: ProcessSupervisor(),
                    terminalSurfaceFactory: .swiftTerm
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
                    supervisor: ProcessSupervisor(),
                    terminalSurfaceFactory: .swiftTerm
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

    func requestManagementRoute(entryID: UUID) {
        pendingManagementRoute = ManagementRouteRequest(
            entryID: entryID
        )
    }

    func consumePendingManagementRoute() -> ManagementRouteRequest? {
        defer { pendingManagementRoute = nil }
        return pendingManagementRoute
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
        let deletedEntryIDs = groupsBeforeDeletion.first {
            $0.id == id
        }?.entries.map(\.id) ?? []
        let deletedIndex = groupsBeforeDeletion.firstIndex {
            $0.id == id
        }
        let deletingSelection = selectedGroupID == id

        try workspace.deleteGroup(
            id: id,
            liveEntryIDs: runtime.deletionProtectedEntryIDs
        )
        for entryID in deletedEntryIDs {
            try runtime.removeEntry(entryID: entryID)
        }

        let selectedEntryStillExists = selectedEntryID.flatMap {
            entry(id: $0)
        } != nil
        if deletingSelection, !selectedEntryStillExists {
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
        shell: String = ShellCatalog.systemDefaultShell,
        keywords: [String]
    ) throws -> UUID {
        let id = try workspace.addEntry(
            to: groupID,
            name: name,
            cwd: cwd,
            command: command,
            shell: shell,
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
        shell: String = ShellCatalog.systemDefaultShell,
        keywords: [String]
    ) throws {
        try workspace.updateEntry(
            id: id,
            in: groupID,
            name: name,
            cwd: cwd,
            command: command,
            shell: shell,
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
            isLive: runtime.deletionProtectedEntryIDs.contains(id)
        )
        try runtime.removeEntry(entryID: id)

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

        if let selectedEntryID,
           let containingGroup = groups.first(
            where: {
                $0.entries.contains {
                    $0.id == selectedEntryID
                }
            }
           ) {
            selectedGroupID = containingGroup.id
            return
        }

        let group: CommandGroup
        if let selectedGroup = groups.first(
            where: { $0.id == selectedGroupID }
        ) {
            group = selectedGroup
        } else {
            group = groups[0]
            selectedGroupID = group.id
        }
        let entries = orderedEntries(in: group)
        selectedEntryID = entries.first?.id
    }

    func orderedEntries(in groupID: UUID) -> [CommandEntry] {
        guard let group = orderedGroups.first(
            where: { $0.id == groupID }
        ) else {
            return []
        }
        return orderedEntries(in: group)
    }

    func group(id: UUID) -> CommandGroup? {
        orderedGroups.first { $0.id == id }
    }

    func entry(id: UUID) -> CommandEntry? {
        orderedGroups.lazy
            .flatMap(\.entries)
            .first { $0.id == id }
    }

    func entry(id: UUID, in groupID: UUID) -> CommandEntry? {
        group(id: groupID)?.entries.first { $0.id == id }
    }

    func entryDeletionIsBlocked(_ entryID: UUID) -> Bool {
        runtime.deletionProtectedEntryIDs.contains(entryID)
    }

    func groupDeletionIsBlocked(_ groupID: UUID) -> Bool {
        guard let group = group(id: groupID) else {
            return false
        }
        return group.entries.contains {
            runtime.deletionProtectedEntryIDs.contains($0.id)
        }
    }

    @discardableResult
    func startEntry(
        id entryID: UUID
    ) -> Task<EntryActionResult, Never>? {
        guard let entry = entry(id: entryID) else {
            return nil
        }
        let reservation = runtime.reserveOperations(
            entryIDs: [entryID]
        )
        let runtime = runtime
        return Task { @MainActor in
            await runtime.start(
                entry,
                reservation: reservation
            )
        }
    }

    @discardableResult
    func stopEntry(
        id entryID: UUID
    ) -> Task<EntryActionResult, Never>? {
        guard let entry = entry(id: entryID) else {
            return nil
        }
        let reservation = runtime.reserveOperations(
            entryIDs: [entryID]
        )
        let runtime = runtime
        return Task { @MainActor in
            let result = await runtime.stop(
                entry,
                reservation: reservation
            )
            runtime.recordOperationFailure(
                operation: .stop,
                entries: [entry],
                results: [result]
            )
            return result
        }
    }

    @discardableResult
    func restartEntry(
        id entryID: UUID
    ) -> Task<EntryActionResult, Never>? {
        guard let entry = entry(id: entryID) else {
            return nil
        }
        let reservation = runtime.reserveOperations(
            entryIDs: [entryID]
        )
        let runtime = runtime
        return Task { @MainActor in
            let result = await runtime.restart(
                entry,
                reservation: reservation
            )
            runtime.recordOperationFailure(
                operation: .restart,
                entries: [entry],
                results: [result]
            )
            return result
        }
    }

    @discardableResult
    func startGroup(
        id groupID: UUID
    ) -> Task<[EntryActionResult], Never>? {
        guard let group = group(id: groupID) else {
            return nil
        }
        let excludedEntryIDs = runtime.liveEntryIDs
            .union(runtime.protectedEntryIDs)
        let entries = group.entries.filter {
            !excludedEntryIDs.contains($0.id)
        }
        let reservation = runtime.reserveOperations(
            entryIDs: entries.map(\.id)
        )
        let runtime = runtime
        return Task { @MainActor in
            await runtime.startAll(
                entries,
                reservation: reservation
            )
        }
    }

    @discardableResult
    func stopGroup(
        id groupID: UUID
    ) -> Task<[EntryActionResult], Never>? {
        guard let group = group(id: groupID) else {
            return nil
        }
        let entries = group.entries
        let reservation = runtime.reserveOperations(
            entryIDs: entries.map(\.id)
        )
        let runtime = runtime
        return Task { @MainActor in
            let results = await runtime.stopAll(
                entries,
                reservation: reservation
            )
            runtime.recordOperationFailure(
                operation: .stop,
                entries: entries,
                results: results
            )
            return results
        }
    }

    @discardableResult
    func restartGroup(
        id groupID: UUID
    ) -> Task<[EntryActionResult], Never>? {
        guard let group = group(id: groupID) else {
            return nil
        }
        let entries = group.entries
        let reservation = runtime.reserveOperations(
            entryIDs: entries.map(\.id)
        )
        let runtime = runtime
        return Task { @MainActor in
            let results = await runtime.restartAll(
                entries,
                reservation: reservation
            )
            runtime.recordOperationFailure(
                operation: .restart,
                entries: entries,
                results: results
            )
            return results
        }
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
        group.entries
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

import Foundation
import Observation

enum WorkspaceStoreError: Error, Equatable, LocalizedError {
    case emptyName
    case emptyCommand
    case emptyKeyword
    case unsupportedShell(String)
    case cwdIsNotDirectory(String)
    case groupNotFound(UUID)
    case entryNotFound(UUID)
    case invalidMove
    case liveEntryCannotBeDeleted(UUID)
    case liveGroupCannotBeDeleted(UUID)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return L10n.string("Name cannot be empty.")
        case .emptyCommand:
            return L10n.string("Command cannot be empty.")
        case .emptyKeyword:
            return L10n.string("Keywords cannot be empty.")
        case .unsupportedShell(let path):
            return L10n.format(
                "The selected shell is unavailable or unsupported: %@",
                path
            )
        case .cwdIsNotDirectory(let path):
            return L10n.format(
                "The working directory does not exist or is not a directory: %@",
                path
            )
        case .groupNotFound(let id):
            return L10n.format(
                "Group not found: %@",
                id.uuidString
            )
        case .entryNotFound(let id):
            return L10n.format(
                "Entry not found: %@",
                id.uuidString
            )
        case .invalidMove:
            return L10n.string(
                "The requested move is outside the collection."
            )
        case .liveEntryCannotBeDeleted(let id):
            return L10n.format(
                "Stop the live entry before deleting it: %@",
                id.uuidString
            )
        case .liveGroupCannotBeDeleted(let id):
            return L10n.format(
                "Stop every live entry before deleting group: %@",
                id.uuidString
            )
        }
    }
}

@MainActor
@Observable
final class WorkspaceStore {
    private(set) var configuration: WorkspaceConfiguration
    private(set) var persistenceError: String?

    private let repository: ConfigurationRepository

    init(repository: ConfigurationRepository) throws {
        self.repository = repository
        configuration = canonicalized(
            try repository.load()
        )
    }

    init(
        repository: ConfigurationRepository,
        initialConfiguration: WorkspaceConfiguration
    ) {
        self.repository = repository
        configuration = canonicalized(initialConfiguration)
    }

    func addGroup(name: String) throws -> UUID {
        let normalizedName = try validateName(name)
        let id = UUID()
        try persistMutation { configuration in
            configuration.groups.append(
                CommandGroup(
                    id: id,
                    name: normalizedName,
                    order: configuration.groups.count,
                    entries: []
                )
            )
            normalizeGroupOrders(&configuration.groups)
        }
        return id
    }

    func updateGroup(id: UUID, name: String) throws {
        let normalizedName = try validateName(name)
        try persistMutation { configuration in
            guard let index = configuration.groups.firstIndex(where: { $0.id == id }) else {
                throw WorkspaceStoreError.groupNotFound(id)
            }
            configuration.groups[index].name = normalizedName
        }
    }

    func deleteGroup(id: UUID, liveEntryIDs: Set<UUID>) throws {
        try persistMutation { configuration in
            guard let index = configuration.groups.firstIndex(where: { $0.id == id }) else {
                throw WorkspaceStoreError.groupNotFound(id)
            }
            let group = configuration.groups[index]
            guard group.entries.allSatisfy({ !liveEntryIDs.contains($0.id) }) else {
                throw WorkspaceStoreError.liveGroupCannotBeDeleted(id)
            }
            configuration.groups.remove(at: index)
            normalizeGroupOrders(&configuration.groups)
        }
    }

    func moveGroups(fromOffsets: IndexSet, toOffset: Int) throws {
        try persistMutation { configuration in
            try move(
                &configuration.groups,
                fromOffsets: fromOffsets,
                toOffset: toOffset
            )
            normalizeGroupOrders(&configuration.groups)
        }
    }

    func addEntry(
        to groupID: UUID,
        name: String,
        cwd: String,
        command: String,
        shell: String = ShellCatalog.systemDefaultShell,
        keywords: [String]
    ) throws -> UUID {
        let values = try validateEntry(
            name: name,
            cwd: cwd,
            command: command,
            shell: shell,
            keywords: keywords
        )
        let id = UUID()
        try persistMutation { configuration in
            guard let groupIndex = configuration.groups.firstIndex(
                where: { $0.id == groupID }
            ) else {
                throw WorkspaceStoreError.groupNotFound(groupID)
            }
            configuration.groups[groupIndex].entries.append(
                CommandEntry(
                    id: id,
                    name: values.name,
                    cwd: values.cwd,
                    command: values.command,
                    shell: values.shell,
                    keywords: values.keywords,
                    order: configuration.groups[groupIndex].entries.count
                )
            )
            normalizeEntryOrders(
                &configuration.groups[groupIndex].entries
            )
        }
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
        let values = try validateEntry(
            name: name,
            cwd: cwd,
            command: command,
            shell: shell,
            keywords: keywords
        )
        try persistMutation { configuration in
            guard let groupIndex = configuration.groups.firstIndex(
                where: { $0.id == groupID }
            ) else {
                throw WorkspaceStoreError.groupNotFound(groupID)
            }
            guard let entryIndex = configuration.groups[groupIndex].entries
                .firstIndex(where: { $0.id == id }) else {
                throw WorkspaceStoreError.entryNotFound(id)
            }
            configuration.groups[groupIndex].entries[entryIndex].name = values.name
            configuration.groups[groupIndex].entries[entryIndex].cwd = values.cwd
            configuration.groups[groupIndex].entries[entryIndex].command = values.command
            configuration.groups[groupIndex].entries[entryIndex].shell = values.shell
            configuration.groups[groupIndex].entries[entryIndex].keywords = values.keywords
        }
    }

    func deleteEntry(id: UUID, in groupID: UUID, isLive: Bool) throws {
        guard !isLive else {
            throw WorkspaceStoreError.liveEntryCannotBeDeleted(id)
        }
        try persistMutation { configuration in
            guard let groupIndex = configuration.groups.firstIndex(
                where: { $0.id == groupID }
            ) else {
                throw WorkspaceStoreError.groupNotFound(groupID)
            }
            guard let entryIndex = configuration.groups[groupIndex].entries
                .firstIndex(where: { $0.id == id }) else {
                throw WorkspaceStoreError.entryNotFound(id)
            }
            configuration.groups[groupIndex].entries.remove(at: entryIndex)
            normalizeEntryOrders(
                &configuration.groups[groupIndex].entries
            )
        }
    }

    func moveEntries(
        in groupID: UUID,
        fromOffsets: IndexSet,
        toOffset: Int
    ) throws {
        try persistMutation { configuration in
            guard let groupIndex = configuration.groups.firstIndex(
                where: { $0.id == groupID }
            ) else {
                throw WorkspaceStoreError.groupNotFound(groupID)
            }
            try move(
                &configuration.groups[groupIndex].entries,
                fromOffsets: fromOffsets,
                toOffset: toOffset
            )
            normalizeEntryOrders(
                &configuration.groups[groupIndex].entries
            )
        }
    }

    private func persistMutation(
        _ mutation: (inout WorkspaceConfiguration) throws -> Void
    ) throws {
        var candidate = configuration
        try mutation(&candidate)

        do {
            try repository.save(candidate)
            configuration = candidate
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
            throw error
        }
    }

    private func validateName(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw WorkspaceStoreError.emptyName
        }
        return normalized
    }

    private func validateEntry(
        name: String,
        cwd: String,
        command: String,
        shell: String,
        keywords: [String]
    ) throws -> (
        name: String,
        cwd: String,
        command: String,
        shell: String,
        keywords: [String]
    ) {
        let normalizedName = try validateName(name)
        let normalizedCWD = WorkingDirectoryPath.normalize(cwd)
        let trimmedCommand = command.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalizedKeywords = keywords.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !trimmedCommand.isEmpty else {
            throw WorkspaceStoreError.emptyCommand
        }
        guard ShellCatalog.isAvailableAndSupported(shell) else {
            throw WorkspaceStoreError.unsupportedShell(shell)
        }
        guard normalizedKeywords.allSatisfy({ !$0.isEmpty }) else {
            throw WorkspaceStoreError.emptyKeyword
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: normalizedCWD,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw WorkspaceStoreError.cwdIsNotDirectory(normalizedCWD)
        }

        return (
            normalizedName,
            normalizedCWD,
            command,
            shell,
            normalizedKeywords
        )
    }
}

private func normalizeGroupOrders(_ groups: inout [CommandGroup]) {
    for index in groups.indices {
        groups[index].order = index
    }
}

private func normalizeEntryOrders(_ entries: inout [CommandEntry]) {
    for index in entries.indices {
        entries[index].order = index
    }
}

private func canonicalized(
    _ configuration: WorkspaceConfiguration
) -> WorkspaceConfiguration {
    var result = configuration
    result.groups.sort {
        if $0.order != $1.order {
            return $0.order < $1.order
        }
        return $0.id.uuidString < $1.id.uuidString
    }
    for groupIndex in result.groups.indices {
        result.groups[groupIndex].entries.sort {
            if $0.order != $1.order {
                return $0.order < $1.order
            }
            return $0.id.uuidString < $1.id.uuidString
        }
        for entryIndex in result.groups[groupIndex].entries.indices {
            result.groups[groupIndex].entries[entryIndex].cwd =
                WorkingDirectoryPath.normalize(
                    result.groups[groupIndex].entries[entryIndex].cwd
                )
            result.groups[groupIndex].entries[entryIndex].shell =
                ShellCatalog.normalizedSelection(
                    result.groups[groupIndex].entries[entryIndex].shell
                )
        }
        normalizeEntryOrders(
            &result.groups[groupIndex].entries
        )
    }
    normalizeGroupOrders(&result.groups)
    return result
}

private func move<Element>(
    _ elements: inout [Element],
    fromOffsets: IndexSet,
    toOffset: Int
) throws {
    guard toOffset >= 0,
          toOffset <= elements.count,
          fromOffsets.allSatisfy(elements.indices.contains) else {
        throw WorkspaceStoreError.invalidMove
    }
    guard !fromOffsets.isEmpty else { return }

    let moved = fromOffsets.map { elements[$0] }
    for index in fromOffsets.sorted(by: >) {
        elements.remove(at: index)
    }
    let removedBeforeDestination = fromOffsets.filter { $0 < toOffset }.count
    let insertionIndex = toOffset - removedBeforeDestination
    elements.insert(contentsOf: moved, at: insertionIndex)
}

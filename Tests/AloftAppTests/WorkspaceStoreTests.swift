import Foundation
import XCTest
@testable import AloftApp

@MainActor
final class WorkspaceStoreTests: XCTestCase {
    func testCreateEditReorderAndDeletePersistsConfiguration() throws {
        let location = temporaryConfigurationLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }

        let repository = ConfigurationRepository(fileURL: location.file)
        let store = try WorkspaceStore(repository: repository)
        let backendID = try store.addGroup(name: " Backend ")
        XCTAssertEqual(try repository.load(), store.configuration)
        let frontendID = try store.addGroup(name: " Frontend ")
        XCTAssertEqual(try repository.load(), store.configuration)
        try store.updateGroup(id: backendID, name: " API ")
        XCTAssertEqual(try repository.load(), store.configuration)

        let firstID = try store.addEntry(
            to: frontendID,
            name: " Web ",
            cwd: " /tmp ",
            command: "npm run dev",
            shell: "/bin/sh",
            keywords: [" ready ", " error "]
        )
        XCTAssertEqual(try repository.load(), store.configuration)
        let secondID = try store.addEntry(
            to: frontendID,
            name: " Storybook ",
            cwd: "/tmp",
            command: "npm run storybook",
            keywords: []
        )
        XCTAssertEqual(try repository.load(), store.configuration)

        try store.updateEntry(
            id: firstID,
            in: frontendID,
            name: " Web dev ",
            cwd: " /tmp ",
            command: "npm run dev",
            shell: "/bin/zsh",
            keywords: [" ready ", " error "]
        )
        try store.moveEntries(
            in: frontendID,
            fromOffsets: IndexSet(integer: 1),
            toOffset: 0
        )
        try store.moveGroups(
            fromOffsets: IndexSet(integer: 1),
            toOffset: 0
        )

        XCTAssertEqual(
            store.configuration.groups.map(\.id),
            [frontendID, backendID]
        )
        XCTAssertEqual(
            store.configuration.groups.map(\.name),
            ["Frontend", "API"]
        )
        XCTAssertEqual(store.configuration.groups.map(\.order), [0, 1])
        XCTAssertEqual(
            store.configuration.groups[0].entries.map(\.id),
            [secondID, firstID]
        )
        XCTAssertEqual(
            store.configuration.groups[0].entries.map(\.order),
            [0, 1]
        )
        XCTAssertEqual(
            store.configuration.groups[0].entries[1],
            CommandEntry(
                id: firstID,
                name: "Web dev",
                cwd: "/tmp",
                command: "npm run dev",
                shell: "/bin/zsh",
                keywords: ["ready", "error"],
                order: 1
            )
        )
        XCTAssertEqual(try repository.load(), store.configuration)

        try store.deleteEntry(
            id: secondID,
            in: frontendID,
            isLive: false
        )
        try store.deleteGroup(id: backendID, liveEntryIDs: [])

        XCTAssertEqual(store.configuration.groups.map(\.id), [frontendID])
        XCTAssertEqual(store.configuration.groups.map(\.order), [0])
        XCTAssertEqual(
            store.configuration.groups[0].entries.map(\.id),
            [firstID]
        )
        XCTAssertEqual(
            store.configuration.groups[0].entries.map(\.order),
            [0]
        )
        XCTAssertEqual(try repository.load(), store.configuration)
        XCTAssertNil(store.persistenceError)
    }

    func testEntryExpandsTildeInWorkingDirectory() throws {
        let location = temporaryConfigurationLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }

        let repository = ConfigurationRepository(fileURL: location.file)
        let store = try WorkspaceStore(repository: repository)
        let groupID = try store.addGroup(name: "Frontend")
        let entryID = try store.addEntry(
            to: groupID,
            name: "Web",
            cwd: "~",
            command: "npm run dev",
            keywords: []
        )

        let entry = try XCTUnwrap(
            store.configuration.groups[0].entries.first {
                $0.id == entryID
            }
        )
        XCTAssertEqual(
            entry.cwd,
            FileManager.default.homeDirectoryForCurrentUser.path
        )
        XCTAssertEqual(try repository.load(), store.configuration)
    }

    func testEntryPreservesCommandWhitespace() throws {
        let location = temporaryConfigurationLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }

        let repository = ConfigurationRepository(fileURL: location.file)
        let store = try WorkspaceStore(repository: repository)
        let groupID = try store.addGroup(name: "Frontend")
        let command = "  printf 'left  middle  right'  \n"
        let entryID = try store.addEntry(
            to: groupID,
            name: "Whitespace",
            cwd: "/tmp",
            command: command,
            keywords: []
        )

        let entry = try XCTUnwrap(
            store.configuration.groups[0].entries.first {
                $0.id == entryID
            }
        )
        XCTAssertEqual(entry.command, command)
        XCTAssertEqual(try repository.load(), store.configuration)
    }

    func testEntryValidationRejectsInvalidFieldsAndNonDirectoryPaths() throws {
        let location = temporaryConfigurationLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        try FileManager.default.createDirectory(
            at: location.root,
            withIntermediateDirectories: true
        )
        let regularFile = location.root.appendingPathComponent("regular")
        try Data("file".utf8).write(to: regularFile)

        let repository = ConfigurationRepository(fileURL: location.file)
        let store = try WorkspaceStore(repository: repository)
        let groupID = try store.addGroup(name: "Frontend")

        XCTAssertThrowsError(
            try store.addEntry(
                to: groupID,
                name: " ",
                cwd: "/tmp",
                command: "npm run dev",
                keywords: []
            )
        )
        XCTAssertThrowsError(
            try store.addEntry(
                to: groupID,
                name: "Web",
                cwd: "/tmp",
                command: "\n",
                keywords: []
            )
        )
        XCTAssertThrowsError(
            try store.addEntry(
                to: groupID,
                name: "Web",
                cwd: "/tmp",
                command: "npm run dev",
                shell: "/bin/tcsh",
                keywords: []
            )
        )
        XCTAssertThrowsError(
            try store.addEntry(
                to: groupID,
                name: "Web",
                cwd: "/tmp",
                command: "npm run dev",
                keywords: ["ready", " "]
            )
        )
        XCTAssertThrowsError(
            try store.addEntry(
                to: groupID,
                name: "Web",
                cwd: "/path/that/does/not/exist",
                command: "npm run dev",
                keywords: []
            )
        )
        XCTAssertThrowsError(
            try store.addEntry(
                to: groupID,
                name: "Web",
                cwd: regularFile.path,
                command: "npm run dev",
                keywords: []
            )
        )

        XCTAssertTrue(store.configuration.groups[0].entries.isEmpty)
        XCTAssertEqual(try repository.load(), store.configuration)
    }

    func testGroupValidationAndLiveDeletionGuardsPreserveConfiguration() throws {
        let location = temporaryConfigurationLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }

        let repository = ConfigurationRepository(fileURL: location.file)
        let store = try WorkspaceStore(repository: repository)
        XCTAssertThrowsError(try store.addGroup(name: " \n "))

        let groupID = try store.addGroup(name: "Frontend")
        let entryID = try store.addEntry(
            to: groupID,
            name: "Web",
            cwd: "/tmp",
            command: "npm run dev",
            keywords: []
        )
        let before = store.configuration

        XCTAssertThrowsError(
            try store.deleteEntry(
                id: entryID,
                in: groupID,
                isLive: true
            )
        )
        XCTAssertThrowsError(
            try store.deleteGroup(
                id: groupID,
                liveEntryIDs: [entryID]
            )
        )

        XCTAssertEqual(store.configuration, before)
        XCTAssertEqual(try repository.load(), before)
    }

    func testPersistenceFailureRollsBackMemoryAndSurfacesError() throws {
        let location = temporaryConfigurationLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        try FileManager.default.createDirectory(
            at: location.root,
            withIntermediateDirectories: true
        )
        let blockingFile = location.root.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blockingFile)
        let repository = ConfigurationRepository(
            fileURL: blockingFile.appendingPathComponent("config.json")
        )
        let store = WorkspaceStore(
            repository: repository,
            initialConfiguration: .empty
        )

        XCTAssertThrowsError(try store.addGroup(name: "Frontend"))

        XCTAssertEqual(store.configuration, .empty)
        XCTAssertNotNil(store.persistenceError)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: repository.fileURL.path)
        )
    }

    func testInitialConfigurationInitializerDoesNotPersistUntilMutation() throws {
        let location = temporaryConfigurationLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let repository = ConfigurationRepository(fileURL: location.file)
        let initial = WorkspaceConfiguration(
            groups: [
                CommandGroup(
                    id: UUID(),
                    name: "Recovered",
                    order: 0,
                    entries: []
                )
            ]
        )

        let store = WorkspaceStore(
            repository: repository,
            initialConfiguration: initial
        )

        XCTAssertEqual(store.configuration, initial)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: location.file.path)
        )
    }

    func testRepositoryLoadCanonicalizesPhysicalOrderWithoutWriting() throws {
        let location = temporaryConfigurationLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let fixture = unorderedConfigurationFixture()
        let repository = ConfigurationRepository(fileURL: location.file)
        try repository.save(fixture.configuration)
        let bytesBeforeLoad = try Data(contentsOf: location.file)

        let store = try WorkspaceStore(repository: repository)

        XCTAssertEqual(
            store.configuration.groups.map(\.id),
            [fixture.groupB, fixture.groupC, fixture.groupA]
        )
        XCTAssertEqual(
            store.configuration.groups.map(\.order),
            [0, 1, 2]
        )
        XCTAssertEqual(
            store.configuration.groups[2].entries.map(\.id),
            [fixture.entryB, fixture.entryC, fixture.entryA]
        )
        XCTAssertEqual(
            store.configuration.groups[2].entries.map(\.order),
            [0, 1, 2]
        )
        XCTAssertEqual(try Data(contentsOf: location.file), bytesBeforeLoad)
    }

    func testInitialConfigurationCanonicalizesOrderAndMoveOffsets() throws {
        let location = temporaryConfigurationLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }
        let fixture = unorderedConfigurationFixture()
        let repository = ConfigurationRepository(fileURL: location.file)
        let store = WorkspaceStore(
            repository: repository,
            initialConfiguration: fixture.configuration
        )

        XCTAssertEqual(
            store.configuration.groups.map(\.id),
            [fixture.groupB, fixture.groupC, fixture.groupA]
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: location.file.path)
        )

        try store.moveGroups(
            fromOffsets: IndexSet(integer: 0),
            toOffset: 3
        )
        try store.moveEntries(
            in: fixture.groupA,
            fromOffsets: IndexSet(integer: 0),
            toOffset: 3
        )

        XCTAssertEqual(
            store.configuration.groups.map(\.id),
            [fixture.groupC, fixture.groupA, fixture.groupB]
        )
        let groupA = try XCTUnwrap(
            store.configuration.groups.first {
                $0.id == fixture.groupA
            }
        )
        XCTAssertEqual(
            groupA.entries.map(\.id),
            [fixture.entryC, fixture.entryA, fixture.entryB]
        )
        XCTAssertEqual(
            try repository.load(),
            store.configuration
        )
    }
}

private func temporaryConfigurationLocation() -> (root: URL, file: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("Aloft-WorkspaceStoreTests-\(UUID().uuidString)")
    return (root, root.appendingPathComponent("config.json"))
}

private func unorderedConfigurationFixture() -> (
    configuration: WorkspaceConfiguration,
    groupA: UUID,
    groupB: UUID,
    groupC: UUID,
    entryA: UUID,
    entryB: UUID,
    entryC: UUID
) {
    let groupA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    let groupB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    let groupC = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
    let entryA = UUID(uuidString: "00000000-0000-0000-0000-00000000001A")!
    let entryB = UUID(uuidString: "00000000-0000-0000-0000-00000000001B")!
    let entryC = UUID(uuidString: "00000000-0000-0000-0000-00000000001C")!
    let entries = [
        CommandEntry(
            id: entryA,
            name: "A",
            cwd: "/tmp",
            command: "echo A",
            keywords: [],
            order: 2
        ),
        CommandEntry(
            id: entryB,
            name: "B",
            cwd: "/tmp",
            command: "echo B",
            keywords: [],
            order: 0
        ),
        CommandEntry(
            id: entryC,
            name: "C",
            cwd: "/tmp",
            command: "echo C",
            keywords: [],
            order: 1
        ),
    ]
    return (
        WorkspaceConfiguration(
            groups: [
                CommandGroup(
                    id: groupA,
                    name: "A",
                    order: 2,
                    entries: entries
                ),
                CommandGroup(
                    id: groupB,
                    name: "B",
                    order: 0,
                    entries: []
                ),
                CommandGroup(
                    id: groupC,
                    name: "C",
                    order: 1,
                    entries: []
                ),
            ]
        ),
        groupA,
        groupB,
        groupC,
        entryA,
        entryB,
        entryC
    )
}

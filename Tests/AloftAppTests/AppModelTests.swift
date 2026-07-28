import Foundation
import XCTest
@testable import AloftApp

@MainActor
final class AppModelTests: XCTestCase {
    func testInitialSelectionUsesFirstOrderedGroupAndEntry() throws {
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [
                ("Frontend", ["One", "Two"]),
                ("Backend", ["API"]),
            ]
        )

        XCTAssertEqual(
            fixture.model.selectedGroupID,
            fixture.model.workspace.configuration.groups[0].id
        )
        XCTAssertEqual(
            fixture.model.selectedEntryID,
            fixture.model.workspace.configuration.groups[0].entries[0].id
        )
    }

    func testDeletingSelectedEntrySelectsNextEntryInSameGroup() throws {
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [("Frontend", ["One", "Two"])]
        )
        let group = try XCTUnwrap(
            fixture.model.workspace.configuration.groups.first
        )
        let firstID = group.entries[0].id
        let secondID = group.entries[1].id
        fixture.model.selectedGroupID = group.id
        fixture.model.selectedEntryID = firstID

        try fixture.model.deleteEntry(id: firstID, in: group.id)

        XCTAssertEqual(fixture.model.selectedGroupID, group.id)
        XCTAssertEqual(fixture.model.selectedEntryID, secondID)
    }

    func testDeletingLastSelectedEntrySelectsPreviousEntry() throws {
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [("Frontend", ["One", "Two"])]
        )
        let group = try XCTUnwrap(
            fixture.model.workspace.configuration.groups.first
        )
        fixture.model.selectedGroupID = group.id
        fixture.model.selectedEntryID = group.entries[1].id

        try fixture.model.deleteEntry(
            id: group.entries[1].id,
            in: group.id
        )

        XCTAssertEqual(
            fixture.model.selectedEntryID,
            group.entries[0].id
        )
    }

    func testDeletingSelectedGroupSelectsNextGroupAndItsFirstEntry() throws {
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [
                ("Frontend", ["Web"]),
                ("Backend", ["API"]),
            ]
        )
        let groups = fixture.model.workspace.configuration.groups
        fixture.model.selectedGroupID = groups[0].id
        fixture.model.selectedEntryID = groups[0].entries[0].id

        try fixture.model.deleteGroup(id: groups[0].id)

        XCTAssertEqual(fixture.model.selectedGroupID, groups[1].id)
        XCTAssertEqual(
            fixture.model.selectedEntryID,
            groups[1].entries[0].id
        )
    }

    func testReorderingPreservesStableIDSelection() throws {
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [
                ("Frontend", ["One", "Two"]),
                ("Backend", ["API"]),
            ]
        )
        let groups = fixture.model.workspace.configuration.groups
        let selectedEntryID = groups[0].entries[1].id
        fixture.model.selectEntry(selectedEntryID)

        try fixture.model.moveEntries(
            in: groups[0].id,
            fromOffsets: IndexSet(integer: 1),
            toOffset: 0
        )
        try fixture.model.moveGroups(
            fromOffsets: IndexSet(integer: 0),
            toOffset: 2
        )

        XCTAssertEqual(fixture.model.selectedGroupID, groups[0].id)
        XCTAssertEqual(fixture.model.selectedEntryID, selectedEntryID)
    }

    func testLatestMatchSelectionTargetsItsEntryAndGroup() throws {
        let fixture = try makeAppModel(
            groupNamesAndEntryNames: [("Frontend", ["One", "Two"])]
        )
        let group = try XCTUnwrap(
            fixture.model.workspace.configuration.groups.first
        )
        let target = group.entries[1]

        fixture.model.selectEntry(target.id)

        XCTAssertEqual(fixture.model.selectedGroupID, group.id)
        XCTAssertEqual(fixture.model.selectedEntryID, target.id)
    }

    func testMalformedBootstrapDoesNotOverwriteConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let malformed = Data("{ not-json".utf8)
        try malformed.write(to: url)

        let model = AppModel.bootstrap(configurationURL: url)

        XCTAssertEqual(model.workspace.configuration, .empty)
        XCTAssertNotNil(model.presentedError)
        XCTAssertEqual(try Data(contentsOf: url), malformed)
    }

    func testOutputMutationChoosesAppendOnlyForStrictPrefixGrowth() {
        XCTAssertEqual(
            OutputTextMutation(oldText: "one", newText: "one\ntwo"),
            .append("\ntwo")
        )
        XCTAssertEqual(
            OutputTextMutation(oldText: "one\ntwo", newText: "two"),
            .replace("two")
        )
        XCTAssertEqual(
            OutputTextMutation(oldText: "one", newText: ""),
            .replace("")
        )
        XCTAssertEqual(
            OutputTextMutation(oldText: "one", newText: "one"),
            .none
        )
    }

    func testOutputBottomGeometryUsesPreUpdateViewport() {
        XCTAssertTrue(
            OutputScrollGeometry.isAtBottom(
                visibleMaxY: 100,
                documentMaxY: 100
            )
        )
        XCTAssertTrue(
            OutputScrollGeometry.isAtBottom(
                visibleMaxY: 99.5,
                documentMaxY: 100
            )
        )
        XCTAssertFalse(
            OutputScrollGeometry.isAtBottom(
                visibleMaxY: 95,
                documentMaxY: 100
            )
        )
    }
}

@MainActor
private func makeAppModel(
    groupNamesAndEntryNames: [(String, [String])]
) throws -> (model: AppModel, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let url = directory.appendingPathComponent("config.json")
    let workspace = try WorkspaceStore(
        repository: ConfigurationRepository(fileURL: url)
    )
    for (groupName, entryNames) in groupNamesAndEntryNames {
        let groupID = try workspace.addGroup(name: groupName)
        for entryName in entryNames {
            _ = try workspace.addEntry(
                to: groupID,
                name: entryName,
                cwd: "/tmp",
                command: "echo \(entryName)",
                keywords: []
            )
        }
    }
    return (
        AppModel(
            workspace: workspace,
            runtime: RuntimeStore(supervisor: ProcessSupervisor()),
            ghostty: GhosttyService()
        ),
        directory
    )
}

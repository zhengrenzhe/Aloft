import XCTest
@testable import AloftApp

final class WorkspaceConfigurationTests: XCTestCase {
    func testJSONRoundTripPreservesGroupEntryOrderAndKeywords() throws {
        let entry = CommandEntry(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Web",
            cwd: "/tmp/project",
            command: "npm run dev",
            keywords: ["ready", "error"],
            order: 4
        )
        let source = WorkspaceConfiguration(groups: [
            CommandGroup(
                id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                name: "Frontend",
                order: 2,
                entries: [entry]
            )
        ])

        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(WorkspaceConfiguration.self, from: data)

        XCTAssertEqual(decoded, source)
    }

    func testLegacyJSONWithoutShellUsesSystemDefaultShell() throws {
        let data = Data(
            """
            {
              "id": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
              "name": "Web",
              "cwd": "/tmp/project",
              "command": "npm run dev",
              "keywords": [],
              "order": 0
            }
            """.utf8
        )

        let entry = try JSONDecoder().decode(
            CommandEntry.self,
            from: data
        )

        XCTAssertEqual(entry.shell, ShellCatalog.systemDefaultShell)
    }
}

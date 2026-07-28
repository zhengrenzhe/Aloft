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
}

import Foundation
import XCTest
@testable import AloftApp

final class ConfigurationRepositoryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testMissingFileLoadsEmptyConfiguration() throws {
        let repository = ConfigurationRepository(
            fileURL: directory.appendingPathComponent("config.json")
        )
        XCTAssertEqual(try repository.load(), .empty)
    }

    func testSaveThenLoadRoundTripsAndLeavesNoTemporaryFile() throws {
        let url = directory.appendingPathComponent("config.json")
        let repository = ConfigurationRepository(fileURL: url)
        let source = WorkspaceConfiguration(groups: [
            CommandGroup(id: UUID(), name: "Dev", order: 0, entries: [])
        ])

        try repository.save(source)

        XCTAssertEqual(try repository.load(), source)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            ["config.json"]
        )
    }

    func testMalformedFileThrowsWithoutChangingBytes() throws {
        let url = directory.appendingPathComponent("config.json")
        let invalid = Data("{broken".utf8)
        try invalid.write(to: url)
        let repository = ConfigurationRepository(fileURL: url)

        XCTAssertThrowsError(try repository.load())
        XCTAssertEqual(try Data(contentsOf: url), invalid)
    }
}

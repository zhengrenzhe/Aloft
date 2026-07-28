import AppKit
import Foundation
import XCTest
@testable import AloftApp

@MainActor
final class GhosttyServiceTests: XCTestCase {
    nonisolated(unsafe) private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in temporaryRoots {
            try FileManager.default.removeItem(at: root)
        }
        temporaryRoots.removeAll()
    }

    func testVersionComparisonRequiresAtLeastOnePointThree() {
        XCTAssertFalse(GhosttyVersion("1.2.9")!.supportsAppleScript)
        XCTAssertTrue(GhosttyVersion("1.3.0")!.supportsAppleScript)
        XCTAssertTrue(GhosttyVersion("2.0.0")!.supportsAppleScript)
        XCTAssertLessThan(
            GhosttyVersion("1.9.9")!,
            GhosttyVersion("2.0.0")!
        )
    }

    func testVersionParserNormalizesMissingMinorAndPatchComponents() {
        XCTAssertEqual(
            GhosttyVersion("1"),
            GhosttyVersion(major: 1, minor: 0, patch: 0)
        )
        XCTAssertEqual(
            GhosttyVersion("1.3"),
            GhosttyVersion(major: 1, minor: 3, patch: 0)
        )
    }

    func testVersionParserRejectsMalformedAndOverflowingVersions() {
        for value in [
            "",
            "1.",
            ".1",
            "1..3",
            "1.3.0.1",
            "1.3-beta",
            " 1.3.0",
            "1.3.0 ",
            "١.٣.٠",
            "999999999999999999999999.0.0",
        ] {
            XCTAssertNil(GhosttyVersion(value), value)
        }
    }

    func testAppleScriptEscapesQuotesAndBackslashesInCWD() {
        let source = GhosttyService.appleScriptSource(
            cwd: #"/tmp/a "quote"\folder"#
        )

        XCTAssertEqual(
            source,
            """
            tell application "Ghostty"
                activate
                set cfg to new surface configuration
                set initial working directory of cfg to "/tmp/a \\"quote\\"\\\\folder"
                new window with configuration cfg
            end tell
            """
        )
    }

    func testAppleScriptKeepsInjectedStatementsInsideTheStringLiteral() {
        let source = GhosttyService.appleScriptSource(
            cwd: "\"\nend tell\nreturn \"injected"
        )

        XCTAssertEqual(
            source,
            """
            tell application "Ghostty"
                activate
                set cfg to new surface configuration
                set initial working directory of cfg to "\\"\nend tell\nreturn \\"injected"
                new window with configuration cfg
            end tell
            """
        )
    }

    func testStatusDistinguishesMissingUnsupportedAndAvailableApplication() throws {
        let missingURL = newTemporaryRoot()
            .appendingPathComponent("Missing.app", isDirectory: true)
        XCTAssertEqual(
            GhosttyService(applicationURL: missingURL).status(),
            .notInstalled
        )

        let unsupportedURL = try makeApplication(version: "1.2.9")
        XCTAssertEqual(
            GhosttyService(applicationURL: unsupportedURL).status(),
            .unsupported(GhosttyVersion("1.2.9")!)
        )

        let availableURL = try makeApplication(version: "1.3.0")
        XCTAssertEqual(
            GhosttyService(applicationURL: availableURL).status(),
            .available(GhosttyVersion("1.3.0")!)
        )
    }

    func testOpenShellRejectsInvalidCWDWithoutExecutingAppleScript() throws {
        let applicationURL = try makeApplication(version: "1.3.0")
        var executionCount = 0
        let service = GhosttyService(
            applicationURL: applicationURL,
            executeAppleScript: { _ in
                executionCount += 1
                return nil
            }
        )
        let missingDirectory = newTemporaryRoot()
            .appendingPathComponent("missing", isDirectory: true)

        XCTAssertThrowsError(
            try service.openShell(cwd: missingDirectory.path)
        ) { error in
            XCTAssertEqual(
                error as? GhosttyServiceError,
                .invalidWorkingDirectory(missingDirectory.path)
            )
        }
        XCTAssertEqual(executionCount, 0)
    }

    func testOpenShellRejectsRegularFileWithoutExecutingAppleScript() throws {
        let applicationURL = try makeApplication(version: "1.3.0")
        let regularFile = newTemporaryRoot()
            .appendingPathComponent("file")
        try Data("file".utf8).write(to: regularFile)
        var executionCount = 0
        let service = GhosttyService(
            applicationURL: applicationURL,
            executeAppleScript: { _ in
                executionCount += 1
                return nil
            }
        )

        XCTAssertThrowsError(try service.openShell(cwd: regularFile.path)) {
            error in
            XCTAssertEqual(
                error as? GhosttyServiceError,
                .invalidWorkingDirectory(regularFile.path)
            )
        }
        XCTAssertEqual(executionCount, 0)
    }

    func testOpenShellRejectsUnavailableApplicationWithoutExecutingAppleScript() {
        let missingURL = newTemporaryRoot()
            .appendingPathComponent("Missing.app", isDirectory: true)
        var executionCount = 0
        let service = GhosttyService(
            applicationURL: missingURL,
            executeAppleScript: { _ in
                executionCount += 1
                return nil
            }
        )

        XCTAssertThrowsError(try service.openShell(cwd: "/tmp")) { error in
            XCTAssertEqual(
                error as? GhosttyServiceError,
                .notInstalled
            )
        }
        XCTAssertEqual(executionCount, 0)
    }

    func testOpenShellRejectsUnsupportedApplicationWithoutExecutingAppleScript() throws {
        let applicationURL = try makeApplication(version: "1.2.9")
        var executionCount = 0
        let service = GhosttyService(
            applicationURL: applicationURL,
            executeAppleScript: { _ in
                executionCount += 1
                return nil
            }
        )

        XCTAssertThrowsError(try service.openShell(cwd: "/tmp")) { error in
            XCTAssertEqual(
                error as? GhosttyServiceError,
                .unsupported(GhosttyVersion("1.2.9")!)
            )
        }
        XCTAssertEqual(executionCount, 0)
    }

    func testOpenShellExecutesGeneratedSourceForSupportedApplication() throws {
        let applicationURL = try makeApplication(version: "1.3.0")
        let cwd = newTemporaryRoot()
        var executedSource: String?
        let service = GhosttyService(
            applicationURL: applicationURL,
            executeAppleScript: { source in
                executedSource = source
                return nil
            }
        )

        try service.openShell(cwd: cwd.path)

        XCTAssertEqual(
            executedSource,
            GhosttyService.appleScriptSource(cwd: cwd.path)
        )
    }

    func testOpenShellConvertsAppleScriptErrorDictionary() throws {
        let applicationURL = try makeApplication(version: "1.3.0")
        let cwd = newTemporaryRoot()
        let service = GhosttyService(
            applicationURL: applicationURL,
            executeAppleScript: { _ in
                [
                    NSAppleScript.errorMessage:
                        "Not authorized to send Apple events."
                ]
            }
        )

        XCTAssertThrowsError(try service.openShell(cwd: cwd.path)) { error in
            XCTAssertEqual(
                error as? GhosttyServiceError,
                .appleScript(
                    message: "Not authorized to send Apple events."
                )
            )
        }
    }

    func testOpenShellIncludesAppleScriptErrorNumberWhenMessageIsMissing() throws {
        let applicationURL = try makeApplication(version: "1.3.0")
        let cwd = newTemporaryRoot()
        let service = GhosttyService(
            applicationURL: applicationURL,
            executeAppleScript: { _ in
                [NSAppleScript.errorNumber: -1743]
            }
        )

        XCTAssertThrowsError(try service.openShell(cwd: cwd.path)) { error in
            XCTAssertEqual(
                error as? GhosttyServiceError,
                .appleScript(message: "AppleScript error -1743")
            )
        }
    }

    private func makeApplication(version: String) throws -> URL {
        let root = newTemporaryRoot()
        let applicationURL = root.appendingPathComponent(
            "Ghostty.app",
            isDirectory: true
        )
        let contentsURL = applicationURL.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: contentsURL,
            withIntermediateDirectories: true
        )
        let propertyList: [String: Any] = [
            "CFBundleIdentifier": "com.mitchellh.ghostty",
            "CFBundleName": "Ghostty",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        try data.write(
            to: contentsURL.appendingPathComponent("Info.plist")
        )
        return applicationURL
    }

    private func newTemporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        temporaryRoots.append(root)
        return root
    }
}

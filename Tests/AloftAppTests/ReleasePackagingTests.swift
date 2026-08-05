import Darwin
import Foundation
import XCTest

final class ReleasePackagingTests: XCTestCase {
    func testArchivingReleaseUnregistersAndRemovesRawAppBundle()
        throws {
        let fileManager = FileManager.default
        let temporaryRoot = URL(
            fileURLWithPath: "/private/tmp",
            isDirectory: true
        )
            .appendingPathComponent(
                "AloftReleasePackagingTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let bundle = temporaryRoot.appendingPathComponent(
            "Aloft.app",
            isDirectory: true
        )
        let contents = bundle.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: contents,
            withIntermediateDirectories: true
        )
        try Data("fixture".utf8).write(
            to: contents.appendingPathComponent("Info.plist")
        )
        let physicalBundlePath = try physicalPath(bundle.path)

        let unregisterLog = temporaryRoot.appendingPathComponent(
            "lsregister.log"
        )
        let fakeLSRegister = temporaryRoot.appendingPathComponent(
            "lsregister"
        )
        try Data(
            """
            #!/bin/bash
            if [[ "$*" != "-gc" ]]; then
              exit 73
            fi
            if [[ -e "$ALOFT_RAW_APP_PATH" ]]; then
              exit 74
            fi
            printf '%s\n' "$*" > "$ALOFT_LSREGISTER_LOG"
            """.utf8
        ).write(to: fakeLSRegister)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeLSRegister.path
        )

        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let archiveScript = projectRoot
            .appendingPathComponent("script/archive_release_bundle.sh")
        let archiveResult = try runProcess(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                archiveScript.path,
                temporaryRoot.path,
                fakeLSRegister.path,
            ],
            environment: [
                "ALOFT_LSREGISTER_LOG": unregisterLog.path,
                "ALOFT_RAW_APP_PATH": physicalBundlePath,
            ]
        )

        XCTAssertEqual(
            archiveResult.status,
            0,
            archiveResult.standardError
        )
        guard archiveResult.status == 0 else {
            return
        }
        XCTAssertFalse(fileManager.fileExists(atPath: bundle.path))

        let archive = temporaryRoot.appendingPathComponent("Aloft.zip")
        XCTAssertTrue(fileManager.fileExists(atPath: archive.path))
        let expanded = temporaryRoot.appendingPathComponent(
            "expanded",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: expanded,
            withIntermediateDirectories: true
        )
        let expandResult = try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", archive.path, expanded.path]
        )
        XCTAssertEqual(
            expandResult.status,
            0,
            expandResult.standardError
        )
        XCTAssertTrue(
            fileManager.fileExists(
                atPath: expanded
                    .appendingPathComponent("Aloft.app/Contents/Info.plist")
                    .path
            )
        )
        XCTAssertEqual(
            try String(contentsOf: unregisterLog, encoding: .utf8),
            "-gc\n"
        )
    }
}

private struct ProcessResult {
    let status: Int32
    let standardError: String
}

private func physicalPath(_ path: String) throws -> String {
    var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(path, &resolved) != nil else {
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno)
        )
    }
    return String(
        decoding: resolved.prefix { $0 != 0 }.map {
            UInt8(bitPattern: $0)
        },
        as: UTF8.self
    )
}

private func runProcess(
    executable: URL,
    arguments: [String],
    environment: [String: String] = [:]
) throws -> ProcessResult {
    let process = Process()
    let standardError = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment
        .merging(environment) { _, new in new }
    process.standardError = standardError
    try process.run()
    process.waitUntilExit()
    let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
    return ProcessResult(
        status: process.terminationStatus,
        standardError: String(decoding: errorData, as: UTF8.self)
    )
}

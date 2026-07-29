import XCTest
@testable import AloftApp

final class ShellCatalogTests: XCTestCase {
    func testParserReturnsExecutableSupportedIntersectionInFileOrder() {
        let executable: Set<String> = [
            "/bin/bash",
            "/bin/dash",
            "/bin/zsh",
        ]
        let contents = """
        # List of acceptable shells
        /bin/bash
        /bin/csh
        /bin/dash
        /bin/bash
        relative/zsh
        /bin/zsh
        /missing/ksh
        """

        let result = ShellCatalog.parseSupportedShells(contents) {
            executable.contains($0)
        }

        XCTAssertEqual(
            result,
            ["/bin/bash", "/bin/dash", "/bin/zsh"]
        )
    }

    func testSystemCatalogContainsOnlyExecutablePOSIXStyleShells() {
        let options = ShellCatalog.available

        XCTAssertFalse(options.isEmpty)
        XCTAssertEqual(
            options.filter(\.isSystemDefault).map(\.path),
            [ShellCatalog.systemDefaultShell]
        )
        for option in options {
            XCTAssertTrue(
                ShellCatalog.supportedNames.contains(
                    URL(fileURLWithPath: option.path).lastPathComponent
                )
            )
            XCTAssertTrue(
                FileManager.default.isExecutableFile(
                    atPath: option.path
                )
            )
        }
    }
}

import Foundation
import XCTest
@testable import AloftApp

final class ReleaseTerminalBenchmarkControllerTests:
    XCTestCase {
    func testConfigurationIsDisabledWithoutOptIn() {
        XCTAssertNil(
            ReleaseTerminalBenchmarkConfiguration.resolve(
                environment: [:]
            )
        )
    }

    func testConfigurationUsesExplicitDuration() {
        let configuration =
            ReleaseTerminalBenchmarkConfiguration.resolve(
                environment: [
                    "ALOFT_RELEASE_TERMINAL_BENCHMARK": "1",
                    "ALOFT_RELEASE_TERMINAL_BENCHMARK_SECONDS":
                        "12",
                ]
            )

        XCTAssertEqual(
            configuration,
            ReleaseTerminalBenchmarkConfiguration(
                duration: .seconds(12)
            )
        )
    }

    func testConfigurationClampsDurationToOneSecond() {
        let configuration =
            ReleaseTerminalBenchmarkConfiguration.resolve(
                environment: [
                    "ALOFT_RELEASE_TERMINAL_BENCHMARK": "1",
                    "ALOFT_RELEASE_TERMINAL_BENCHMARK_SECONDS":
                        "0",
                ]
            )

        XCTAssertEqual(
            configuration,
            ReleaseTerminalBenchmarkConfiguration(
                duration: .seconds(1)
            )
        )
    }

    func testStartupReadinessReporterRequiresOptIn() {
        var writes: [Data] = []

        StartupReadinessReporter.reportIfRequested(
            environment: [:],
            write: { writes.append($0) }
        )

        XCTAssertEqual(writes, [])
    }

    func testStartupReadinessReporterWritesOneStableMarker() {
        var writes: [Data] = []

        StartupReadinessReporter.reportIfRequested(
            environment: [
                "ALOFT_VERIFY_STARTUP": "1",
            ],
            write: { writes.append($0) }
        )

        XCTAssertEqual(
            writes,
            [Data("ALOFT_STARTUP_READY\n".utf8)]
        )
    }
}

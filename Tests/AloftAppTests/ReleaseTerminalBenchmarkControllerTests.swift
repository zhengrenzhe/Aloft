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
}

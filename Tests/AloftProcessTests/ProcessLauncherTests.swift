import Darwin
import Foundation
import XCTest
@testable import AloftApp

final class ProcessLauncherTests: XCTestCase {
    func testLaunchUsesConfiguredCWDAndTTY() throws {
        let directory = FileManager.default.temporaryDirectory.path
        let process = try ProcessLauncher.launch(
            command: #"printf "%s\n" "$PWD"; if test -t 1; then echo tty; fi"#,
            cwd: directory
        )
        defer {
            try? ProcessLauncher.signalProcessGroup(process.processGroupID, signal: SIGKILL)
            close(process.masterFileDescriptor)
            _ = try? ProcessLauncher.wait(pid: process.pid, noHang: false)
        }

        let output = try readUntilEOFOrTimeout(
            fd: process.masterFileDescriptor,
            timeout: 2
        )

        XCTAssertTrue(output.contains(directory))
        XCTAssertTrue(output.contains("tty"))
        XCTAssertEqual(process.pid, process.processGroupID)
    }

    func testKernelProbeAndSIGTERMAffectWholeGroup() throws {
        let process = try ProcessLauncher.launch(
            command: "sleep 30 & wait",
            cwd: "/tmp"
        )
        defer {
            try? ProcessLauncher.signalProcessGroup(process.processGroupID, signal: SIGKILL)
            close(process.masterFileDescriptor)
            _ = try? ProcessLauncher.wait(pid: process.pid, noHang: false)
        }

        XCTAssertTrue(try ProcessLauncher.processGroupExists(process.processGroupID))
        try ProcessLauncher.signalProcessGroup(process.processGroupID, signal: SIGTERM)
        var waitResult = ChildWaitResult.running
        XCTAssertTrue(waitUntil(timeout: 2) {
            if let current = try? ProcessLauncher.wait(pid: process.pid, noHang: true),
               current != .running {
                waitResult = current
            }
            return (try? ProcessLauncher.processGroupExists(process.processGroupID)) == false
        })
        XCTAssertEqual(waitResult, .signaled(signal: SIGTERM))
    }

    func testMissingCWDReportsChangeDirectoryPhase() {
        XCTAssertThrowsError(
            try ProcessLauncher.launch(
                command: "echo unreachable",
                cwd: "/path/that/does/not/exist"
            )
        ) { error in
            XCTAssertEqual(
                error as? ProcessLaunchError,
                ProcessLaunchError(phase: .changeDirectory, code: ENOENT)
            )
        }
    }

    func testWaitMapsRunningAndExitStatus() throws {
        let process = try ProcessLauncher.launch(
            command: "sleep 0.1; exit 7",
            cwd: "/tmp"
        )
        defer {
            try? ProcessLauncher.signalProcessGroup(process.processGroupID, signal: SIGKILL)
            close(process.masterFileDescriptor)
            _ = try? ProcessLauncher.wait(pid: process.pid, noHang: false)
        }

        XCTAssertEqual(
            try ProcessLauncher.wait(pid: process.pid, noHang: true),
            .running
        )

        var result = ChildWaitResult.running
        XCTAssertTrue(waitUntil(timeout: 2) {
            guard let current = try? ProcessLauncher.wait(pid: process.pid, noHang: true) else {
                return false
            }
            result = current
            return current != .running
        })
        XCTAssertEqual(result, .exited(code: 7))
    }
}

private func readUntilEOFOrTimeout(fd: Int32, timeout: TimeInterval) throws -> String {
    let deadline = Date().addingTimeInterval(timeout)
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4_096)

    while Date() < deadline {
        let remaining = max(0, deadline.timeIntervalSinceNow)
        var descriptor = pollfd(
            fd: fd,
            events: Int16(POLLIN | POLLHUP | POLLERR),
            revents: 0
        )
        let pollResult = poll(
            &descriptor,
            1,
            Int32(min(remaining * 1_000, TimeInterval(Int32.max)))
        )

        if pollResult == -1 {
            if errno == EINTR {
                continue
            }
            throw posixError(errno)
        }
        if pollResult == 0 {
            break
        }

        let bytesRead = buffer.withUnsafeMutableBytes {
            read(fd, $0.baseAddress, $0.count)
        }
        if bytesRead > 0 {
            bytes.append(contentsOf: buffer.prefix(bytesRead))
            continue
        }
        if bytesRead == 0 {
            return String(decoding: bytes, as: UTF8.self)
        }
        if errno == EINTR || errno == EAGAIN {
            continue
        }
        throw posixError(errno)
    }

    throw posixError(ETIMEDOUT)
}

private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        usleep(10_000)
    }
    return condition()
}

private func posixError(_ code: Int32) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code))
}

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

    func testReturnedPTYMasterClosesOnExec() throws {
        let process = try ProcessLauncher.launch(
            command: "exec sleep 30",
            cwd: "/tmp"
        )
        defer {
            try? ProcessLauncher.signalProcessGroup(
                process.processGroupID,
                signal: SIGKILL
            )
            close(process.masterFileDescriptor)
            _ = try? ProcessLauncher.wait(pid: process.pid, noHang: false)
        }

        let descriptorFlags = fcntl(
            process.masterFileDescriptor,
            F_GETFD
        )
        XCTAssertNotEqual(descriptorFlags, -1)
        XCTAssertEqual(descriptorFlags & FD_CLOEXEC, FD_CLOEXEC)
    }

    func testLaterLaunchCannotUseEarlierPTYMaster() throws {
        let earlier = try ProcessLauncher.launch(
            command: "exec sleep 30",
            cwd: "/tmp"
        )
        defer {
            try? ProcessLauncher.signalProcessGroup(
                earlier.processGroupID,
                signal: SIGKILL
            )
            close(earlier.masterFileDescriptor)
            _ = try? ProcessLauncher.wait(pid: earlier.pid, noHang: false)
        }

        let later = try ProcessLauncher.launch(
            command: """
                if { : >&\(earlier.masterFileDescriptor) } 2>/dev/null; then
                    print -r -- ALOFT_EARLIER_MASTER_VISIBLE
                else
                    print -r -- ALOFT_EARLIER_MASTER_CLOSED
                fi
                """,
            cwd: "/tmp"
        )
        defer {
            try? ProcessLauncher.signalProcessGroup(
                later.processGroupID,
                signal: SIGKILL
            )
            close(later.masterFileDescriptor)
            _ = try? ProcessLauncher.wait(pid: later.pid, noHang: false)
        }

        let output = try readUntilEOFOrTimeout(
            fd: later.masterFileDescriptor,
            timeout: 2
        )
        XCTAssertTrue(output.contains("ALOFT_EARLIER_MASTER_CLOSED"))
        XCTAssertFalse(output.contains("ALOFT_EARLIER_MASTER_VISIBLE"))
    }

    func testKernelProbeAndSIGTERMAffectWholeGroup() throws {
        let process = try ProcessLauncher.launch(
            command: #"/bin/sh -c 'trap "" HUP; "#
                + #"printf "child_pid=%d ALOFT_CHILD_READY\n" "$$"; "#
                + #"exec sleep 30' & exec sleep 30"#,
            cwd: "/tmp"
        )
        var backgroundPID: pid_t?
        defer {
            cleanupProcessGroup(process, backgroundPID: backgroundPID)
        }

        let readyOutput = try readUntilContains(
            fd: process.masterFileDescriptor,
            marker: "ALOFT_CHILD_READY",
            timeout: 2
        )
        let pidToken = readyOutput
            .split(whereSeparator: \.isWhitespace)
            .first { $0.hasPrefix("child_pid=") }
        let childPID = try XCTUnwrap(
            pidToken.flatMap {
                pid_t($0.dropFirst("child_pid=".count))
            }
        )
        backgroundPID = childPID

        XCTAssertNotEqual(childPID, process.pid)
        XCTAssertEqual(getpgid(childPID), process.processGroupID)
        let leaderExecedSleep = try waitUntil(timeout: 2) {
            try executableName(pid: process.pid) == "sleep"
        }
        XCTAssertTrue(leaderExecedSleep, "group leader did not exec sleep")
        guard leaderExecedSleep else {
            return
        }
        XCTAssertTrue(try ProcessLauncher.processGroupExists(process.processGroupID))
        try ProcessLauncher.signalProcessGroup(process.processGroupID, signal: SIGTERM)

        XCTAssertEqual(
            try waitForChildExit(pid: process.pid, timeout: 2),
            .signaled(signal: SIGTERM)
        )
        let backgroundGone = try waitUntil(timeout: 2) {
            try processIsGone(childPID)
        }
        XCTAssertTrue(backgroundGone, "background child \(childPID) survived SIGTERM")
        guard backgroundGone else {
            return
        }
        XCTAssertTrue(try waitUntil(timeout: 2) {
            try ProcessLauncher.processGroupExists(process.processGroupID) == false
        })
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

    func testLaunchResetsChildSignalMaskAndPreservesParentMask() throws {
        var termSet = sigset_t()
        XCTAssertEqual(sigemptyset(&termSet), 0)
        XCTAssertEqual(sigaddset(&termSet, SIGTERM), 0)

        var originalSet = sigset_t()
        XCTAssertEqual(
            pthread_sigmask(SIG_BLOCK, &termSet, &originalSet),
            0
        )
        var parentMaskRestored = false
        defer {
            if parentMaskRestored == false {
                pthread_sigmask(SIG_SETMASK, &originalSet, nil)
            }
        }

        var blockedSet = sigset_t()
        XCTAssertEqual(pthread_sigmask(SIG_BLOCK, nil, &blockedSet), 0)
        XCTAssertEqual(sigismember(&blockedSet, SIGTERM), 1)

        let process = try ProcessLauncher.launch(
            command: "exec sleep 30",
            cwd: "/tmp"
        )
        defer {
            try? ProcessLauncher.signalProcessGroup(
                process.processGroupID,
                signal: SIGKILL
            )
            close(process.masterFileDescriptor)
            _ = try? ProcessLauncher.wait(pid: process.pid, noHang: false)
        }

        XCTAssertEqual(
            pthread_sigmask(SIG_SETMASK, &originalSet, nil),
            0
        )
        parentMaskRestored = true

        var restoredSet = sigset_t()
        XCTAssertEqual(pthread_sigmask(SIG_BLOCK, nil, &restoredSet), 0)
        for signalNumber in 1 ..< NSIG {
            XCTAssertEqual(
                sigismember(&restoredSet, signalNumber),
                sigismember(&originalSet, signalNumber),
                "parent mask changed for signal \(signalNumber)"
            )
        }

        XCTAssertTrue(
            try waitUntil(timeout: 2) {
                try executableName(pid: process.pid) == "sleep"
            },
            "child did not exec sleep"
        )
        try ProcessLauncher.signalProcessGroup(
            process.processGroupID,
            signal: SIGTERM
        )
        XCTAssertEqual(
            try waitForChildExit(pid: process.pid, timeout: 2),
            .signaled(signal: SIGTERM)
        )
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

private func readUntilContains(
    fd: Int32,
    marker: String,
    timeout: TimeInterval
) throws -> String {
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
            let output = String(decoding: bytes, as: UTF8.self)
            if output.contains(marker) {
                return output
            }
            continue
        }
        if bytesRead == 0 {
            throw posixError(EPIPE)
        }
        if errno == EINTR || errno == EAGAIN {
            continue
        }
        throw posixError(errno)
    }

    throw posixError(ETIMEDOUT)
}

private func waitForChildExit(
    pid: pid_t,
    timeout: TimeInterval
) throws -> ChildWaitResult {
    var result = ChildWaitResult.running
    let completed = try waitUntil(timeout: timeout) {
        result = try ProcessLauncher.wait(pid: pid, noHang: true)
        return result != .running
    }
    guard completed else {
        throw posixError(ETIMEDOUT)
    }
    return result
}

private func processIsGone(_ pid: pid_t) throws -> Bool {
    if Darwin.kill(pid, 0) == 0 {
        return false
    }

    switch errno {
    case ESRCH:
        return true
    case EPERM:
        return false
    default:
        throw posixError(errno)
    }
}

private func executableName(pid: pid_t) throws -> String? {
    var path = [CChar](repeating: 0, count: 4_096)
    let length = proc_pidpath(pid, &path, UInt32(path.count))
    if length > 0 {
        let executablePath = path.withUnsafeBufferPointer {
            String(cString: $0.baseAddress!)
        }
        return URL(fileURLWithPath: executablePath).lastPathComponent
    }
    if errno == ESRCH {
        return nil
    }
    throw posixError(errno)
}

private func cleanupProcessGroup(
    _ process: LaunchedProcess,
    backgroundPID: pid_t?
) {
    let killResult = Darwin.killpg(process.processGroupID, SIGKILL)
    let killError = killResult == -1 ? errno : 0
    print(
        "cleanup killpg pgid=\(process.processGroupID) "
            + "result=\(killResult) errno=\(killError)"
    )
    XCTAssertTrue(
        killResult == 0 || (killResult == -1 && killError == ESRCH),
        "cleanup killpg failed with errno \(killError)"
    )
    close(process.masterFileDescriptor)

    var status: Int32 = 0
    var waitError: Int32?
    let leaderHandled = waitUntil(timeout: 2) {
        let result = Darwin.waitpid(process.pid, &status, WNOHANG)
        if result == process.pid {
            return true
        }
        if result == 0 || (result == -1 && errno == EINTR) {
            return false
        }
        if result == -1 && errno == ECHILD {
            return true
        }
        waitError = errno
        return true
    }
    XCTAssertNil(waitError, "cleanup waitpid failed with errno \(waitError ?? 0)")
    XCTAssertTrue(leaderHandled, "cleanup timed out reaping leader \(process.pid)")

    if let backgroundPID {
        let observedGroup = Darwin.getpgid(backgroundPID)
        if observedGroup == process.processGroupID {
            let childKillResult = Darwin.kill(backgroundPID, SIGKILL)
            let childKillError = childKillResult == -1 ? errno : 0
            print(
                "cleanup kill child pid=\(backgroundPID) "
                    + "result=\(childKillResult) errno=\(childKillError)"
            )
            XCTAssertTrue(
                childKillResult == 0
                    || (childKillResult == -1 && childKillError == ESRCH),
                "cleanup child kill failed with errno \(childKillError)"
            )
        } else if observedGroup == -1 {
            XCTAssertEqual(
                errno,
                ESRCH,
                "cleanup getpgid failed with unexpected errno \(errno)"
            )
        }

        let backgroundGone = waitUntil(timeout: 2) {
            if Darwin.kill(backgroundPID, 0) == 0 {
                return false
            }
            return errno == ESRCH
        }
        XCTAssertTrue(
            backgroundGone,
            "cleanup left background child \(backgroundPID)"
        )
    }

    let groupGone = waitUntil(timeout: 2) {
        if Darwin.killpg(process.processGroupID, 0) == 0 {
            return false
        }
        return errno == ESRCH
    }
    XCTAssertTrue(groupGone, "cleanup left process group \(process.processGroupID)")
}

private func waitUntil(
    timeout: TimeInterval,
    condition: () throws -> Bool
) rethrows -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try condition() {
            return true
        }
        usleep(10_000)
    }
    return try condition()
}

private func posixError(_ code: Int32) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code))
}

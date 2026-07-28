import Darwin
import XCTest
@testable import AloftApp

final class ManagedProcessTests: XCTestCase {
    func testDeinitCancelsSourceAndClosesOwnedFileDescriptor() throws {
        let descriptors = try makeNonblockingPipe()
        defer { Darwin.close(descriptors.write) }

        weak var weakProcess: ManagedProcess?
        do {
            let process = ManagedProcess(
                masterFileDescriptor: descriptors.read,
                onOutput: { _ in }
            )
            weakProcess = process
        }

        XCTAssertNil(weakProcess)
        XCTAssertTrue(
            waitForFileDescriptorToClose(
                descriptors.read,
                timeout: .seconds(2)
            ),
            "owner deinit did not close the file descriptor"
        )
    }

    func testCloseThenDeinitDoesNotCloseReusedFileDescriptor() throws {
        let descriptors = try makeNonblockingPipe()
        defer { Darwin.close(descriptors.write) }

        weak var weakProcess: ManagedProcess?
        var process: ManagedProcess? = ManagedProcess(
            masterFileDescriptor: descriptors.read,
            onOutput: { _ in }
        )
        weakProcess = process
        process?.close()
        XCTAssertTrue(
            waitForFileDescriptorToClose(
                descriptors.read,
                timeout: .seconds(2)
            )
        )

        let temporaryFD = Darwin.open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(temporaryFD, 0)
        if temporaryFD != descriptors.read {
            XCTAssertEqual(
                Darwin.dup2(temporaryFD, descriptors.read),
                descriptors.read
            )
            Darwin.close(temporaryFD)
        }
        defer { Darwin.close(descriptors.read) }

        process = nil
        XCTAssertNil(weakProcess)
        XCTAssertTrue(
            fileDescriptorRemainsOpen(
                descriptors.read,
                duration: .milliseconds(200)
            ),
            "deinit double-closed a reused file descriptor"
        )
    }
}

private func makeNonblockingPipe() throws -> (read: Int32, write: Int32) {
    var descriptors: [Int32] = [-1, -1]
    guard Darwin.pipe(&descriptors) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    let flags = Darwin.fcntl(descriptors[0], F_GETFL)
    guard flags != -1,
          Darwin.fcntl(descriptors[0], F_SETFL, flags | O_NONBLOCK) != -1 else {
        let error = errno
        Darwin.close(descriptors[0])
        Darwin.close(descriptors[1])
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
    }
    return (descriptors[0], descriptors[1])
}

private func waitForFileDescriptorToClose(
    _ fileDescriptor: Int32,
    timeout: Duration
) -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while clock.now < deadline {
        if Darwin.fcntl(fileDescriptor, F_GETFD) == -1 && errno == EBADF {
            return true
        }
        usleep(10_000)
    }
    return Darwin.fcntl(fileDescriptor, F_GETFD) == -1 && errno == EBADF
}

private func fileDescriptorRemainsOpen(
    _ fileDescriptor: Int32,
    duration: Duration
) -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: duration)

    while clock.now < deadline {
        if Darwin.fcntl(fileDescriptor, F_GETFD) == -1 {
            return false
        }
        usleep(10_000)
    }
    return Darwin.fcntl(fileDescriptor, F_GETFD) != -1
}

import Darwin
import XCTest
@testable import AloftApp

final class ManagedProcessTests: XCTestCase {
    func testDeinitCancelsSourceAndClosesOwnedFileDescriptor() throws {
        let descriptors = try makeNonblockingPipe()
        defer { Darwin.close(descriptors.write) }

        weak var weakProcess: ManagedProcess?
        do {
            let process = try ManagedProcess(
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
        var process: ManagedProcess? = try ManagedProcess(
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

    func testWriteReachesSlaveAndResizeChangesKernelWinsize()
        async throws {
        let pair = try makeRawPTY()
        let process = try ManagedProcess(
            masterFileDescriptor: pair.master,
            onOutput: { _ in }
        )
        defer {
            process.close()
            Darwin.close(pair.slave)
        }

        try await process.write(Data("reply".utf8))

        XCTAssertEqual(
            try readExactly(
                fileDescriptor: pair.slave,
                count: 5
            ),
            Data("reply".utf8)
        )

        let size = try XCTUnwrap(
            TerminalSize(
                columns: 120,
                rows: 40,
                pixelWidth: 1_200,
                pixelHeight: 800
            )
        )
        try await process.resize(size)

        XCTAssertEqual(
            try readWinsize(fileDescriptor: pair.slave),
            size
        )
    }
}

private func makeRawPTY() throws -> (master: Int32, slave: Int32) {
    var master: Int32 = -1
    var slave: Int32 = -1
    guard Darwin.openpty(
        &master,
        &slave,
        nil,
        nil,
        nil
    ) == 0 else {
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno)
        )
    }

    var attributes = termios()
    guard Darwin.tcgetattr(slave, &attributes) == 0 else {
        let error = errno
        Darwin.close(master)
        Darwin.close(slave)
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(error)
        )
    }
    Darwin.cfmakeraw(&attributes)
    guard Darwin.tcsetattr(
        slave,
        TCSANOW,
        &attributes
    ) == 0 else {
        let error = errno
        Darwin.close(master)
        Darwin.close(slave)
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(error)
        )
    }
    return (master, slave)
}

private func readExactly(
    fileDescriptor: Int32,
    count: Int
) throws -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: count)

    while result.count < count {
        let bytesRead = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(
                fileDescriptor,
                bytes.baseAddress,
                count - result.count
            )
        }
        if bytesRead > 0 {
            result.append(contentsOf: buffer.prefix(bytesRead))
            continue
        }
        if bytesRead == -1 && errno == EINTR {
            continue
        }
        let error = bytesRead == 0 ? EIO : errno
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(error)
        )
    }
    return result
}

private func readWinsize(
    fileDescriptor: Int32
) throws -> TerminalSize {
    var windowSize = winsize()
    guard Darwin.ioctl(
        fileDescriptor,
        TIOCGWINSZ,
        &windowSize
    ) == 0 else {
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno)
        )
    }
    return try XCTUnwrap(
        TerminalSize(
            columns: Int(windowSize.ws_col),
            rows: Int(windowSize.ws_row),
            pixelWidth: Int(windowSize.ws_xpixel),
            pixelHeight: Int(windowSize.ws_ypixel)
        )
    )
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

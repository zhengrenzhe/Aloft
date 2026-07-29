import Darwin
import Foundation
import XCTest
@testable import AloftApp

final class PTYWritePumpTests: XCTestCase {
    func testWriteAllRetriesEINTRAndCompletesPartialWrites() throws {
        let state = WriteState(
            results: [
                .failure(PTYSystemCallError(code: EINTR)),
                .success(2),
                .success(3),
            ]
        )
        let pump = PTYWritePump(
            write: { _, bytes in
                state.nextWrite(for: bytes)
            },
            waitWritable: { _ in .success(true) }
        )

        try pump.writeAll(
            Data("hello".utf8),
            to: 9,
            isCancelled: { false }
        )

        XCTAssertEqual(
            state.writtenData,
            Data("hello".utf8)
        )
    }

    func testWriteAllWaitsAfterEAGAIN() throws {
        let state = WriteState(
            results: [
                .failure(PTYSystemCallError(code: EAGAIN)),
                .success(3),
            ]
        )
        let waitCount = LockedCounter()
        let pump = PTYWritePump(
            write: { _, bytes in
                state.nextWrite(for: bytes)
            },
            waitWritable: { _ in
                waitCount.increment()
                return .success(true)
            }
        )

        try pump.writeAll(
            Data([1, 2, 3]),
            to: 9,
            isCancelled: { false }
        )

        XCTAssertEqual(waitCount.value, 1)
        XCTAssertEqual(state.writtenData, Data([1, 2, 3]))
    }
}

private final class WriteState: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<Int, PTYSystemCallError>]
    private var written = Data()

    init(results: [Result<Int, PTYSystemCallError>]) {
        self.results = results
    }

    var writtenData: Data {
        lock.withLock { written }
    }

    func nextWrite(
        for bytes: UnsafeRawBufferPointer
    ) -> Result<Int, PTYSystemCallError> {
        lock.withLock {
            let result = results.removeFirst()
            if case .success(let count) = result {
                written.append(contentsOf:
                    bytes.bindMemory(to: UInt8.self).prefix(count)
                )
            }
            return result
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock {
            count += 1
        }
    }
}

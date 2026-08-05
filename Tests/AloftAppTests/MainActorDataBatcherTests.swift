import Foundation
import XCTest
@testable import AloftApp

@MainActor
final class MainActorDataBatcherTests: XCTestCase {
    func testCoalescesOrderedBytesIntoBoundedMainActorBatches() async {
        var delivered: [Data] = []
        let batcher = MainActorDataBatcher(
            maximumBatchByteCount: 8
        ) { data in
            delivered.append(data)
        }

        for byte in UInt8(0)..<UInt8(32) {
            batcher.submit(Data([byte]))
        }
        await batcher.waitUntilIdle()

        XCTAssertEqual(
            Data(delivered.flatMap { Array($0) }),
            Data((UInt8(0)..<UInt8(32)).map { $0 })
        )
        XCTAssertEqual(delivered.map(\.count), [8, 8, 8, 8])
    }

    func testDiscardPendingDropsOnlyQueuedBytes() async {
        var delivered = Data()
        let batcher = MainActorDataBatcher(
            maximumBatchByteCount: 64
        ) { data in
            delivered.append(data)
        }

        batcher.submit(Data("discarded".utf8))
        batcher.discardPending()
        batcher.submit(Data("kept".utf8))
        await batcher.waitUntilIdle()

        XCTAssertEqual(delivered, Data("kept".utf8))
    }
}

import Foundation

final class MainActorDataBatcher: @unchecked Sendable {
    typealias Consumer = @MainActor @Sendable (Data) -> Void

    private let maximumBatchByteCount: Int
    private let consumer: Consumer
    private let lock = NSLock()

    private var pending = Data()
    private var drainScheduled = false
    private var closed = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        maximumBatchByteCount: Int,
        consumer: @escaping Consumer
    ) {
        precondition(maximumBatchByteCount > 0)
        self.maximumBatchByteCount = maximumBatchByteCount
        self.consumer = consumer
    }

    func submit(_ data: Data) {
        guard !data.isEmpty else {
            return
        }

        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        pending.append(data)
        let needsSchedule = !drainScheduled
        drainScheduled = true
        lock.unlock()

        if needsSchedule {
            scheduleDrain()
        }
    }

    func discardPending() {
        lock.lock()
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        pending.removeAll()
        drainScheduled = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        lock.unlock()

        waiters.forEach { $0.resume() }
    }

    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !drainScheduled && pending.isEmpty {
                lock.unlock()
                continuation.resume()
            } else {
                idleWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func scheduleDrain() {
        DispatchQueue.main.async { [weak self] in
            self?.drainOneBatch()
        }
    }

    @MainActor
    private func drainOneBatch() {
        lock.lock()
        if closed || pending.isEmpty {
            drainScheduled = false
            let waiters = idleWaiters
            idleWaiters.removeAll()
            lock.unlock()
            waiters.forEach { $0.resume() }
            return
        }

        let byteCount = min(maximumBatchByteCount, pending.count)
        let batch = pending.prefix(byteCount)
        pending.removeFirst(byteCount)
        lock.unlock()

        consumer(Data(batch))

        lock.lock()
        if pending.isEmpty {
            drainScheduled = false
            let waiters = idleWaiters
            idleWaiters.removeAll()
            lock.unlock()
            waiters.forEach { $0.resume() }
        } else {
            lock.unlock()
            scheduleDrain()
        }
    }
}

import Darwin
import Foundation

struct RemainingProcess: Equatable, Sendable {
    let entryID: UUID
    let processGroupID: pid_t
}

enum TerminationResult: Equatable, Sendable {
    case safeToTerminate
    case remaining([RemainingProcess])
    case cancelled

    var remaining: [RemainingProcess] {
        if case .remaining(let values) = self {
            return values
        }
        return []
    }
}

@MainActor
struct TerminationCoordinator {
    let runtimeStore: RuntimeStore

    func stopAllForTermination(
        timeout: Duration = .seconds(5)
    ) async -> TerminationResult {
        let barrier = runtimeStore.beginTerminationBarrier()
        var preservesBarrierForSafeTermination = false
        defer {
            if !preservesBarrierForSafeTermination
                || Task.isCancelled {
                runtimeStore.cancelTerminationBarrier(barrier)
            }
        }
        await runtimeStore.waitForAdmittedLaunches()
        guard !Task.isCancelled else {
            return cancelTermination(barrier: barrier)
        }

        let initialSnapshots: [UUID: ProcessSnapshot]
        do {
            initialSnapshots = try await runtimeStore
                .refreshManagedRecords()
        } catch {
            if Task.isCancelled {
                return cancelTermination(barrier: barrier)
            }
            return cancelTerminationAfterEnumerationFailure(
                barrier: barrier
            )
        }
        guard !Task.isCancelled else {
            return cancelTermination(barrier: barrier)
        }

        let liveEntryIDs = initialSnapshots.values
            .filter {
                $0.liveness == .running
                    && $0.processGroupID != nil
            }
            .map(\.entryID)
            .sorted { $0.uuidString < $1.uuidString }
        _ = await runtimeStore.stopManagedRecords(
            entryIDs: liveEntryIDs,
            timeout: timeout
        )
        guard !Task.isCancelled else {
            return cancelTermination(barrier: barrier)
        }

        let finalSnapshots: [UUID: ProcessSnapshot]
        do {
            finalSnapshots = try await runtimeStore
                .refreshManagedRecords()
        } catch {
            if Task.isCancelled {
                return cancelTermination(barrier: barrier)
            }
            return cancelTerminationAfterEnumerationFailure(
                barrier: barrier
            )
        }
        guard !Task.isCancelled else {
            return cancelTermination(barrier: barrier)
        }

        let remaining = finalSnapshots.values.compactMap {
            snapshot -> RemainingProcess? in
            guard snapshot.liveness == .running,
                  let processGroupID = snapshot.processGroupID else {
                return nil
            }
            return RemainingProcess(
                entryID: snapshot.entryID,
                processGroupID: processGroupID
            )
        }
        .sorted { $0.entryID.uuidString < $1.entryID.uuidString }

        guard !remaining.isEmpty else {
            preservesBarrierForSafeTermination = true
            return .safeToTerminate
        }
        return .remaining(remaining)
    }

    private func cancelTermination(
        barrier: TerminationBarrierToken
    ) -> TerminationResult {
        runtimeStore.cancelTerminationBarrier(barrier)
        return .cancelled
    }

    private func cancelTerminationAfterEnumerationFailure(
        barrier: TerminationBarrierToken
    ) -> TerminationResult {
        let fallback = runtimeStore.liveEntryIDs.compactMap {
            entryID -> RemainingProcess? in
            guard let processGroupID = runtimeStore
                .runtime(for: entryID)
                .process.processGroupID else {
                return nil
            }
            return RemainingProcess(
                entryID: entryID,
                processGroupID: processGroupID
            )
        }
        .sorted { $0.entryID.uuidString < $1.entryID.uuidString }
        runtimeStore.cancelTerminationBarrier(barrier)
        return .remaining(fallback)
    }
}

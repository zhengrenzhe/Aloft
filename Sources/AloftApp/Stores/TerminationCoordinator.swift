import Darwin
import Foundation

struct RemainingProcess: Equatable, Sendable {
    let entryID: UUID
    let processGroupID: pid_t
}

enum TerminationResult: Equatable, Sendable {
    case safeToTerminate
    case remaining([RemainingProcess])

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
        await runtimeStore.refreshAll()
        let entryIDs = runtimeStore.liveEntryIDs.sorted {
            $0.uuidString < $1.uuidString
        }
        guard !entryIDs.isEmpty else {
            return .safeToTerminate
        }

        let entries = runtimeStore.entries(for: entryIDs)
        _ = await runtimeStore.stopAll(entries, timeout: timeout)
        await runtimeStore.refreshAll()

        let remaining = runtimeStore
            .remainingProcesses(among: entryIDs)
            .sorted { $0.entryID.uuidString < $1.entryID.uuidString }
        return remaining.isEmpty
            ? .safeToTerminate
            : .remaining(remaining)
    }
}

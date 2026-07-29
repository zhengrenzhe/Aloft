import Foundation
import Observation

@MainActor
@Observable
final class EntryRuntime {
    let entryID: UUID
    var process: ProcessSnapshot
    var output = OutputSnapshot(
        committedLines: [],
        currentLine: "",
        latestMatch: nil
    )
    var outputDisplayMode: OutputDisplayMode = .default
    var terminalSurface: (any TerminalSurface)?
    var terminalRendererState: TerminalRendererState = .awaitingWindow
    var lastError: String?

    init(entryID: UUID) {
        self.entryID = entryID
        process = ProcessSnapshot(
            entryID: entryID,
            pid: nil,
            processGroupID: nil,
            liveness: .stopped,
            launchedAt: nil,
            exitResult: nil
        )
    }
}

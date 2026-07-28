import SwiftUI

struct EntryDetailView: View {
    let model: AppModel

    @State private var autoScroll = true

    var body: some View {
        Group {
            if let entry = model.selectedEntry {
                detail(for: entry)
                    .id(entry.id)
            } else {
                ContentUnavailableView(
                    "No Command Selected",
                    systemImage: "terminal",
                    description: Text(
                        "Select a command to inspect its process and output."
                    )
                )
            }
        }
    }

    @ViewBuilder
    private func detail(for entry: CommandEntry) -> some View {
        let entryRuntime = model.runtime.runtimes[entry.id]
        let process = entryRuntime?.process
        let isLive = process?.liveness == .running

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name)
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(entry.cwd)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                ProcessStatusLabel(isLive: isLive)
            }

            Text(entry.command)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)

            if isLive, let process,
               let pid = process.pid,
               let processGroupID = process.processGroupID {
                Text("PID \(pid) · PGID \(processGroupID)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let match = entryRuntime?.output.latestMatch {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Latest match: \(match.keyword)")
                        .font(.callout)
                        .fontWeight(.medium)
                    Text(match.line)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }

            if let lastError = entryRuntime?.lastError {
                Text(lastError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            ReadOnlyOutputView(
                text: entryRuntime?.output.displayText ?? "",
                autoScroll: autoScroll
            )
            .frame(minHeight: 220)

            HStack {
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Clear Output") {
                    model.runtime.clearOutput(entryID: entry.id)
                }
                Button("Open in Ghostty") {
                    model.openSelectedEntryInGhostty()
                }
            }
        }
        .padding()
        .navigationTitle(entry.name)
        .toolbar {
            ToolbarItemGroup {
                if isLive {
                    Button("Stop", systemImage: "stop.fill") {
                        stop(entry)
                    }
                    Button("Restart", systemImage: "arrow.clockwise") {
                        restart(entry)
                    }
                } else {
                    Button("Start", systemImage: "play.fill") {
                        start(entry)
                    }
                }
            }
        }
        .task(id: entry.id) {
            await model.runtime.refreshAll()
        }
    }

    private func start(_ entry: CommandEntry) {
        Task {
            _ = await model.runtime.start(entry)
        }
    }

    private func stop(_ entry: CommandEntry) {
        Task {
            _ = await model.runtime.stop(entry)
        }
    }

    private func restart(_ entry: CommandEntry) {
        Task {
            _ = await model.runtime.restart(entry)
        }
    }
}

private struct ProcessStatusLabel: View {
    let isLive: Bool

    var body: some View {
        Label(
            isLive ? "Running" : "Stopped",
            systemImage: isLive
                ? "circle.fill"
                : "circle"
        )
        .foregroundStyle(isLive ? .green : .secondary)
        .font(.callout)
    }
}

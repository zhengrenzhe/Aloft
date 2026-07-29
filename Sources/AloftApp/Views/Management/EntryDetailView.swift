import SwiftUI

struct EntryDetailView: View {
    let model: AppModel

    @State private var autoScroll = true
    @State private var editor: DetailEntryEditorPresentation?

    var body: some View {
        Group {
            if let entry = model.selectedEntry {
                detail(for: entry)
                    .id(entry.id)
            } else {
                ContentUnavailableView(
                    L10n.string("No Command Selected"),
                    systemImage: "terminal",
                    description: Text(
                        L10n.string(
                            "Select a command to inspect its process and output."
                        )
                    )
                )
            }
        }
        .sheet(item: $editor) { presentation in
            if let entry = model.entry(
                id: presentation.entryID,
                in: presentation.groupID
            ) {
                EntryEditorView(
                    model: model,
                    groupID: presentation.groupID,
                    entry: entry
                )
            } else {
                ContentUnavailableView(
                    L10n.string("Command No Longer Exists"),
                    systemImage: "exclamationmark.triangle"
                )
                .frame(minWidth: 360, minHeight: 220)
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
                Text(
                    L10n.format(
                        "PID %@ · PGID %@",
                        String(pid),
                        String(processGroupID)
                    )
                )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let match = entryRuntime?.output.latestMatch {
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        L10n.format(
                            "Latest match: %@",
                            match.keyword
                        )
                    )
                        .font(.callout)
                        .fontWeight(.medium)
                    Text(match.line)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
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
                Toggle(
                    L10n.string("Auto-scroll"),
                    isOn: $autoScroll
                )
                    .toggleStyle(.checkbox)
                Spacer()
                Button(L10n.string("Clear Output")) {
                    model.runtime.clearOutput(entryID: entry.id)
                }
                Button(L10n.string("Open in Ghostty")) {
                    model.openSelectedEntryInGhostty()
                }
            }
        }
        .padding()
        .navigationTitle(entry.name)
        .toolbar {
            ToolbarItemGroup {
                Button(
                    L10n.string("Edit"),
                    systemImage: "pencil"
                ) {
                    guard let groupID = model.selectedGroupID else {
                        return
                    }
                    editor = DetailEntryEditorPresentation(
                        groupID: groupID,
                        entryID: entry.id
                    )
                }
                if isLive {
                    Button(
                        L10n.string("Stop"),
                        systemImage: "stop.fill"
                    ) {
                        model.stopEntry(id: entry.id)
                    }
                    .disabled(
                        model.runtime.protectedEntryIDs.contains(entry.id)
                    )
                    Button(
                        L10n.string("Restart"),
                        systemImage: "arrow.clockwise"
                    ) {
                        model.restartEntry(id: entry.id)
                    }
                    .disabled(
                        model.runtime.protectedEntryIDs.contains(entry.id)
                    )
                } else {
                    Button(
                        L10n.string("Start"),
                        systemImage: "play.fill"
                    ) {
                        model.startEntry(id: entry.id)
                    }
                    .disabled(
                        model.runtime.protectedEntryIDs.contains(entry.id)
                    )
                }
            }
        }
        .task(id: entry.id) {
            await model.runtime.refreshAll()
        }
    }

}

private struct DetailEntryEditorPresentation: Identifiable {
    let groupID: UUID
    let entryID: UUID

    var id: UUID { entryID }
}

private struct ProcessStatusLabel: View {
    let isLive: Bool

    var body: some View {
        Label(
            L10n.string(isLive ? "Running" : "Stopped"),
            systemImage: isLive
                ? "circle.fill"
                : "circle"
        )
        .foregroundStyle(isLive ? .green : .secondary)
        .font(.callout)
    }
}

import SwiftUI

struct EntryDetailView: View {
    let model: AppModel

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
        let entryRuntime = model.runtime.runtime(for: entry.id)
        let process = entryRuntime.process
        let isLive = process.liveness == .running

        VStack(spacing: 0) {
            commandHeader(
                entry: entry,
                runtime: entryRuntime,
                isLive: isLive
            )

            terminalPanel(
                entry: entry,
                runtime: entryRuntime
            )
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
                .help(L10n.string("Edit"))
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
                    .help(L10n.string("Stop"))
                    Button(
                        L10n.string("Restart"),
                        systemImage: "arrow.clockwise"
                    ) {
                        model.restartEntry(id: entry.id)
                    }
                    .disabled(
                        model.runtime.protectedEntryIDs.contains(entry.id)
                    )
                    .help(L10n.string("Restart"))
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
                    .help(L10n.string("Start"))
                }
            }
        }
        .task(id: entry.id) {
            await model.runtime.refreshAll()
        }
    }

    private func commandHeader(
        entry: CommandEntry,
        runtime: EntryRuntime,
        isLive: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(
                        .tint.opacity(0.12),
                        in: RoundedRectangle(
                            cornerRadius: 12,
                            style: .continuous
                        )
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name)
                        .font(.title2.weight(.semibold))
                    Text(entry.cwd)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 12)
                ProcessStatusLabel(isLive: isLive)
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "chevron.forward.2")
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                Text(entry.command)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(
                .quaternary.opacity(0.5),
                in: RoundedRectangle(
                    cornerRadius: 10,
                    style: .continuous
                )
            )

            if isLive,
               let pid = runtime.process.pid,
               let processGroupID = runtime.process.processGroupID {
                Label(
                    L10n.format(
                        "PID %@ · PGID %@",
                        String(pid),
                        String(processGroupID)
                    ),
                    systemImage: "waveform.path.ecg"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }

            if let match = runtime.output.latestMatch {
                NoticeCard(
                    icon: "text.magnifyingglass",
                    color: .orange,
                    title: L10n.format(
                        "Latest match: %@",
                        match.keyword
                    ),
                    detail: match.line
                )
            }

            if let termination = runtime.lastTermination {
                NoticeCard(
                    icon: terminationIcon(for: termination.kind),
                    color: terminationColor(for: termination.kind),
                    title: L10n.string("Last Termination"),
                    detail: termination.detail
                )
            }

            if let lastError = runtime.lastError {
                NoticeCard(
                    icon: "exclamationmark.triangle.fill",
                    color: .red,
                    title: "Aloft",
                    detail: lastError
                )
            }
        }
        .padding(18)
    }

    private func terminationIcon(
        for kind: ProcessTerminationKind
    ) -> String {
        switch kind {
        case .normal:
            return "checkmark.circle.fill"
        case .intentional:
            return "stop.circle.fill"
        case .unexpected:
            return "exclamationmark.triangle.fill"
        case .unavailable:
            return "questionmark.circle.fill"
        }
    }

    private func terminationColor(
        for kind: ProcessTerminationKind
    ) -> Color {
        switch kind {
        case .normal:
            return .green
        case .intentional:
            return .blue
        case .unexpected:
            return .red
        case .unavailable:
            return .orange
        }
    }

    private func terminalPanel(
        entry: CommandEntry,
        runtime: EntryRuntime
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label(
                    L10n.string("Terminal"),
                    systemImage: "terminal"
                )
                .font(.headline)

                rendererBadge(for: runtime.terminalRendererState)

                Spacer()

                Button {
                    model.runtime.clearOutput(entryID: entry.id)
                } label: {
                    Label(
                        L10n.string("Clear Output"),
                        systemImage: "trash"
                    )
                }
                .labelStyle(.iconOnly)
                .help(L10n.string("Clear Output"))

                Button {
                    model.openSelectedEntryInGhostty()
                } label: {
                    Label(
                        L10n.string("Open in Ghostty"),
                        systemImage: "arrow.up.forward.app"
                    )
                }
                .labelStyle(.iconOnly)
                .help(L10n.string("Open in Ghostty"))
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(.bar)

            Divider()

            terminalOutput(for: runtime)
                .frame(minHeight: 260)
        }
        .background(.background)
        .clipShape(
            RoundedRectangle(
                cornerRadius: 12,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: 12,
                style: .continuous
            )
            .stroke(.separator.opacity(0.7))
        }
    }

    @ViewBuilder
    private func terminalOutput(
        for runtime: EntryRuntime
    ) -> some View {
        if let surface = runtime.terminalSurface {
            TerminalOutputView(surface: surface)
                .accessibilityLabel(
                    L10n.string("Read-only terminal output")
                )
                .accessibilityValue(
                    rendererAccessibilityValue(
                        for: runtime.terminalRendererState
                    )
                )
        } else {
            let description = unavailableDescription(
                for: runtime.terminalRendererState
            )
            ContentUnavailableView {
                Label(
                    L10n.string("Terminal"),
                    systemImage: "terminal"
                )
            } description: {
                if let description {
                    Text(description)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func rendererBadge(
        for rendererState: TerminalRendererState
    ) -> some View {
        switch rendererState {
        case .awaitingWindow:
            EmptyView()
        case .metal:
            EmptyView()
        case .coreGraphicsFallback:
            RendererBadge(
                title: L10n.string("Compatible renderer"),
                color: .orange
            )
        case .unavailable:
            RendererBadge(
                title: L10n.string(
                    "Terminal rendering is unavailable."
                ),
                color: .red
            )
        }
    }

    private func rendererAccessibilityValue(
        for rendererState: TerminalRendererState
    ) -> String {
        switch rendererState {
        case .awaitingWindow:
            L10n.string("Terminal")
        case .metal:
            L10n.string("Terminal")
        case .coreGraphicsFallback:
            L10n.string("Compatible renderer")
        case .unavailable:
            L10n.string("Terminal rendering is unavailable.")
        }
    }

    private func unavailableDescription(
        for rendererState: TerminalRendererState
    ) -> String? {
        if case .unavailable(let reason) = rendererState {
            return reason.isEmpty
                ? L10n.string("Terminal rendering is unavailable.")
                : reason
        }
        return nil
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
        .font(.callout.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            (isLive ? Color.green : Color.secondary).opacity(0.1),
            in: Capsule()
        )
    }
}

private struct RendererBadge: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.1), in: Capsule())
    }
}

private struct NoticeCard: View {
    let icon: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            color.opacity(0.08),
            in: RoundedRectangle(
                cornerRadius: 9,
                style: .continuous
            )
        )
        .accessibilityElement(children: .combine)
    }
}

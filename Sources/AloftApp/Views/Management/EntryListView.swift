import SwiftUI

struct EntryListView: View {
    @Bindable var model: AppModel

    @State private var editor: EntryEditorPresentation?

    var body: some View {
        Group {
            if let group = model.selectedGroup {
                List(selection: entrySelection) {
                    ForEach(model.orderedEntries(in: group.id)) {
                        entry in
                        EntryRow(
                            entry: entry,
                            isLive: entryIsLive(entry)
                        )
                        .tag(entry.id)
                        .contextMenu {
                            Button("Edit") {
                                editor = .edit(
                                    groupID: group.id,
                                    entry: entry
                                )
                            }
                            Divider()
                            Button("Start") {
                                start(entry)
                            }
                            .disabled(entryIsLive(entry))
                            Button("Stop") {
                                stop(entry)
                            }
                            .disabled(!entryIsLive(entry))
                            Button("Restart") {
                                restart(entry)
                            }
                            .disabled(!entryIsLive(entry))
                            Divider()
                            Button("Delete", role: .destructive) {
                                deleteEntry(entry, in: group.id)
                            }
                            .disabled(entryIsLive(entry))
                        }
                    }
                    .onMove { offsets, destination in
                        do {
                            try model.moveEntries(
                                in: group.id,
                                fromOffsets: offsets,
                                toOffset: destination
                            )
                        } catch {
                            model.presentedError =
                                error.localizedDescription
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Group Selected",
                    systemImage: "folder",
                    description: Text(
                        "Create or select a group to add commands."
                    )
                )
            }
        }
        .navigationTitle(model.selectedGroup?.name ?? "Commands")
        .toolbar {
            ToolbarItem {
                Button {
                    if let groupID = model.selectedGroupID {
                        editor = .add(
                            id: UUID(),
                            groupID: groupID
                        )
                    }
                } label: {
                    Label("Add Command", systemImage: "plus")
                }
                .disabled(model.selectedGroupID == nil)
            }
        }
        .sheet(item: $editor) { presentation in
            switch presentation {
            case .add(_, let groupID):
                EntryEditorView(
                    model: model,
                    groupID: groupID
                )
            case .edit(let groupID, let entry):
                EntryEditorView(
                    model: model,
                    groupID: groupID,
                    entry: entry
                )
            }
        }
    }

    private var entrySelection: Binding<UUID?> {
        Binding(
            get: { model.selectedEntryID },
            set: { entryID in
                if let entryID {
                    model.selectEntry(entryID)
                } else {
                    model.selectedEntryID = nil
                }
            }
        )
    }

    private func entryIsLive(_ entry: CommandEntry) -> Bool {
        model.runtime.liveEntryIDs.contains(entry.id)
    }

    private func deleteEntry(
        _ entry: CommandEntry,
        in groupID: UUID
    ) {
        do {
            try model.deleteEntry(id: entry.id, in: groupID)
        } catch {
            model.presentedError = error.localizedDescription
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

private struct EntryRow: View {
    let entry: CommandEntry
    let isLive: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isLive ? .green : .secondary)
                .frame(width: 7, height: 7)
                .accessibilityLabel(isLive ? "Running" : "Stopped")
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .lineLimit(1)
                Text(entry.command)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private enum EntryEditorPresentation: Identifiable {
    case add(id: UUID, groupID: UUID)
    case edit(groupID: UUID, entry: CommandEntry)

    var id: UUID {
        switch self {
        case .add(let id, _):
            return id
        case .edit(_, let entry):
            return entry.id
        }
    }
}

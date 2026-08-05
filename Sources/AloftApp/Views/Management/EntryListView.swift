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
                            Button(L10n.string("Edit")) {
                                editor = .edit(
                                    groupID: group.id,
                                    entry: entry
                                )
                            }
                            Divider()
                            Button(L10n.string("Start")) {
                                model.startEntry(id: entry.id)
                            }
                            .disabled(
                                entryIsLive(entry)
                                    || entryIsProtected(entry)
                            )
                            Button(L10n.string("Stop")) {
                                model.stopEntry(id: entry.id)
                            }
                            .disabled(
                                !entryIsLive(entry)
                                    || entryIsProtected(entry)
                            )
                            Button(L10n.string("Restart")) {
                                model.restartEntry(id: entry.id)
                            }
                            .disabled(
                                !entryIsLive(entry)
                                    || entryIsProtected(entry)
                            )
                            Divider()
                            Button(
                                L10n.string("Delete"),
                                role: .destructive
                            ) {
                                deleteEntry(entry, in: group.id)
                            }
                            .disabled(
                                model.entryDeletionIsBlocked(entry.id)
                            )
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
                    L10n.string("No Group Selected"),
                    systemImage: "folder",
                    description: Text(
                        L10n.string(
                            "Create or select a group to add commands."
                        )
                    )
                )
            }
        }
        .navigationTitle(
            model.selectedGroup?.name
                ?? L10n.string("Commands")
        )
        .toolbar {
            ToolbarItemGroup {
                if let group = model.selectedGroup {
                    Button(
                        L10n.string("Start All"),
                        systemImage: "play.fill"
                    ) {
                        model.startGroup(id: group.id)
                    }
                    .help(L10n.string("Start All"))
                    Button(
                        L10n.string("Restart All"),
                        systemImage: "arrow.clockwise"
                    ) {
                        model.restartGroup(id: group.id)
                    }
                    .disabled(
                        !group.entries.contains {
                            entryIsLive($0)
                        }
                    )
                    .help(L10n.string("Restart All"))
                    Button(
                        L10n.string("Stop All"),
                        systemImage: "stop.fill"
                    ) {
                        model.stopGroup(id: group.id)
                    }
                    .disabled(
                        !group.entries.contains {
                            entryIsLive($0)
                        }
                    )
                    .help(L10n.string("Stop All"))
                }

                Button {
                    if let groupID = model.selectedGroupID {
                        editor = .add(
                            id: UUID(),
                            groupID: groupID
                        )
                    }
                } label: {
                    Label(
                        L10n.string("Add Command"),
                        systemImage: "plus"
                    )
                }
                .disabled(model.selectedGroupID == nil)
                .help(L10n.string("Add Command"))
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

    private func entryIsProtected(_ entry: CommandEntry) -> Bool {
        model.runtime.protectedEntryIDs.contains(entry.id)
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

}

private struct EntryRow: View {
    let entry: CommandEntry
    let isLive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(
                systemName: isLive
                    ? "play.fill"
                    : "terminal"
            )
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isLive ? .green : .secondary)
                .frame(width: 28, height: 28)
                .background(
                    (isLive ? Color.green : Color.secondary)
                        .opacity(0.1),
                    in: RoundedRectangle(
                        cornerRadius: 7,
                        style: .continuous
                    )
                )
                .accessibilityLabel(
                    L10n.string(isLive ? "Running" : "Stopped")
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(entry.command)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
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

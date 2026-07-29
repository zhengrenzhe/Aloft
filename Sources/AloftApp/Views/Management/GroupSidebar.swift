import SwiftUI

struct GroupSidebar: View {
    @Bindable var model: AppModel

    @State private var editor: GroupEditorPresentation?

    var body: some View {
        List(selection: groupSelection) {
            ForEach(model.orderedGroups) { group in
                GroupRow(
                    group: group,
                    liveCount: group.entries.filter {
                        model.runtime.liveEntryIDs.contains($0.id)
                    }.count
                )
                .tag(group.id)
                .contextMenu {
                    Button(L10n.string("Rename")) {
                        editor = .edit(group)
                    }
                    Divider()
                    Button(L10n.string("Start All")) {
                        model.startGroup(id: group.id)
                    }
                    Button(L10n.string("Stop All")) {
                        model.stopGroup(id: group.id)
                    }
                    Button(L10n.string("Restart All")) {
                        model.restartGroup(id: group.id)
                    }
                    Divider()
                    Button(
                        L10n.string("Delete"),
                        role: .destructive
                    ) {
                        deleteGroup(group)
                    }
                    .disabled(
                        model.groupDeletionIsBlocked(group.id)
                    )
                }
            }
            .onMove { offsets, destination in
                do {
                    try model.moveGroups(
                        fromOffsets: offsets,
                        toOffset: destination
                    )
                } catch {
                    model.presentedError = error.localizedDescription
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(L10n.string("Groups"))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    editor = .add(UUID())
                } label: {
                    Label(
                        L10n.string("Add Group"),
                        systemImage: "plus"
                    )
                }
            }
        }
        .sheet(item: $editor) { presentation in
            switch presentation {
            case .add:
                GroupEditorView(model: model)
            case .edit(let group):
                GroupEditorView(model: model, group: group)
            }
        }
    }

    private var groupSelection: Binding<UUID?> {
        Binding(
            get: { model.selectedGroupID },
            set: { model.selectGroup($0) }
        )
    }

    private func deleteGroup(_ group: CommandGroup) {
        do {
            try model.deleteGroup(id: group.id)
        } catch {
            model.presentedError = error.localizedDescription
        }
    }

}

private struct GroupRow: View {
    let group: CommandGroup
    let liveCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(group.name)
                .lineLimit(1)
            Spacer(minLength: 4)
            if liveCount > 0 {
                Text("\(liveCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(
                        L10n.format(
                            "%lld running commands",
                            liveCount
                        )
                    )
            }
        }
    }
}

private enum GroupEditorPresentation: Identifiable {
    case add(UUID)
    case edit(CommandGroup)

    var id: UUID {
        switch self {
        case .add(let id):
            return id
        case .edit(let group):
            return group.id
        }
    }
}

import AppKit
import SwiftUI

struct EntryEditorView: View {
    private enum Field: Hashable {
        case name
    }

    @Environment(\.dismiss) private var dismiss

    let model: AppModel
    let groupID: UUID
    let entry: CommandEntry?

    @State private var name: String
    @State private var cwd: String
    @State private var command: String
    @State private var shell: String
    @State private var keywords: String
    @State private var validationError: String?
    @FocusState private var focusedField: Field?

    init(
        model: AppModel,
        groupID: UUID,
        entry: CommandEntry? = nil
    ) {
        self.model = model
        self.groupID = groupID
        self.entry = entry
        _name = State(initialValue: entry?.name ?? "")
        _cwd = State(initialValue: entry?.cwd ?? "")
        _command = State(initialValue: entry?.command ?? "")
        _shell = State(
            initialValue: ShellCatalog.normalizedSelection(
                entry?.shell ?? ShellCatalog.systemDefaultShell
            )
        )
        _keywords = State(
            initialValue: entry?.keywords.joined(separator: "\n") ?? ""
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(
                L10n.string(
                    entry == nil ? "New Command" : "Edit Command"
                )
            )
                .font(.title2)
                .fontWeight(.semibold)

            Form {
                TextField(L10n.string("Name"), text: $name)
                    .focused($focusedField, equals: .name)

                HStack {
                    TextField(
                        L10n.string("Working Directory"),
                        text: $cwd
                    )
                    Button(L10n.string("Browse…")) {
                        chooseWorkingDirectory()
                    }
                }

                Picker(L10n.string("Shell"), selection: $shell) {
                    ForEach(ShellCatalog.available) { option in
                        Text(option.displayName)
                            .tag(option.path)
                    }
                }

                LabeledContent(L10n.string("Command")) {
                    TextEditor(text: $command)
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.leading)
                        .frame(minHeight: 80)
                }

                LabeledContent(L10n.string("Keywords")) {
                    TextEditor(text: $keywords)
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.leading)
                        .frame(minHeight: 70)
                }
            }
            .formStyle(.grouped)

            Text(
                L10n.string(
                    "Available login shells come from /etc/shells. "
                        + "Aloft supports POSIX-style sh, bash, dash, "
                        + "ksh, and zsh."
                )
            )
                .foregroundStyle(.secondary)
                .font(.caption)

            Text(
                L10n.string(
                    "Enter one case-sensitive keyword per line."
                )
            )
                .foregroundStyle(.secondary)
                .font(.caption)

            if let validationError {
                Text(validationError)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button(L10n.string("Cancel"), role: .cancel) {
                    dismiss()
                }
                Button(L10n.string("Save")) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 430)
        .task {
            await Task.yield()
            focusedField = .name
        }
    }

    private func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L10n.string("Choose")
        if !cwd.isEmpty {
            panel.directoryURL = URL(
                fileURLWithPath: WorkingDirectoryPath.normalize(cwd),
                isDirectory: true
            )
        }
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        cwd = url.path
    }

    private func save() {
        let trimmedKeywords = keywords
            .components(separatedBy: .newlines)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        do {
            if let entry {
                try model.updateEntry(
                    id: entry.id,
                    in: groupID,
                    name: name,
                    cwd: cwd,
                    command: command,
                    shell: shell,
                    keywords: trimmedKeywords
                )
            } else {
                try model.addEntry(
                    to: groupID,
                    name: name,
                    cwd: cwd,
                    command: command,
                    shell: shell,
                    keywords: trimmedKeywords
                )
            }
            dismiss()
        } catch {
            validationError = error.localizedDescription
        }
    }
}

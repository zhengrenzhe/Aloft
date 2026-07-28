import AppKit
import SwiftUI

struct EntryEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let model: AppModel
    let groupID: UUID
    let entry: CommandEntry?

    @State private var name: String
    @State private var cwd: String
    @State private var command: String
    @State private var keywords: String
    @State private var validationError: String?

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
        _keywords = State(
            initialValue: entry?.keywords.joined(separator: "\n") ?? ""
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(entry == nil ? "New Command" : "Edit Command")
                .font(.title2)
                .fontWeight(.semibold)

            Form {
                TextField("Name", text: $name)

                HStack {
                    TextField("Working Directory", text: $cwd)
                    Button("Browse…") {
                        chooseWorkingDirectory()
                    }
                }

                LabeledContent("Command") {
                    TextEditor(text: $command)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 80)
                }

                LabeledContent("Keywords") {
                    TextEditor(text: $keywords)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 70)
                }
            }
            .formStyle(.grouped)

            Text("Enter one case-sensitive keyword per line.")
                .foregroundStyle(.secondary)
                .font(.caption)

            if let validationError {
                Text(validationError)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 430)
    }

    private func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if !cwd.isEmpty {
            panel.directoryURL = URL(
                fileURLWithPath: cwd,
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
                    keywords: trimmedKeywords
                )
            } else {
                try model.addEntry(
                    to: groupID,
                    name: name,
                    cwd: cwd,
                    command: command,
                    keywords: trimmedKeywords
                )
            }
            dismiss()
        } catch {
            validationError = error.localizedDescription
        }
    }
}

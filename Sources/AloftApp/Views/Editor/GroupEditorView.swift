import SwiftUI

struct GroupEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let model: AppModel
    let group: CommandGroup?

    @State private var name: String
    @State private var validationError: String?

    init(model: AppModel, group: CommandGroup? = nil) {
        self.model = model
        self.group = group
        _name = State(initialValue: group?.name ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(
                L10n.string(
                    group == nil ? "New Group" : "Rename Group"
                )
            )
                .font(.title2)
                .fontWeight(.semibold)

            TextField(L10n.string("Name"), text: $name)

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
        .frame(minWidth: 360)
    }

    private func save() {
        do {
            let trimmedName = name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if let group {
                try model.updateGroup(id: group.id, name: trimmedName)
            } else {
                try model.addGroup(name: trimmedName)
            }
            dismiss()
        } catch {
            validationError = error.localizedDescription
        }
    }
}

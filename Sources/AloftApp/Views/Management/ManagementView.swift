import SwiftUI

struct ManagementView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            GroupSidebar(model: model)
                .navigationSplitViewColumnWidth(
                    min: 180,
                    ideal: 220
                )
        } content: {
            EntryListView(model: model)
                .navigationSplitViewColumnWidth(
                    min: 220,
                    ideal: 280
                )
        } detail: {
            EntryDetailView(model: model)
        }
        .toolbar(removing: .sidebarToggle)
        .alert(
            "Aloft",
            isPresented: Binding(
                get: { model.presentedError != nil },
                set: { isPresented in
                    if !isPresented {
                        model.presentedError = nil
                    }
                }
            ),
            actions: {
                Button(L10n.string("OK")) {
                    model.presentedError = nil
                }
            },
            message: {
                Text(model.presentedError ?? "")
            }
        )
    }
}

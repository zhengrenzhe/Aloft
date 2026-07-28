import SwiftUI

@main
@MainActor
struct AloftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: appDelegate.model)
        } label: {
            let liveCount = appDelegate.model.runtime.liveEntryIDs.count
            Label(
                liveCount == 0 ? "Aloft" : "\(liveCount)",
                systemImage: "terminal"
            )
        }
        .menuBarExtraStyle(.menu)

        Window("Aloft", id: "management") {
            ManagementView(model: appDelegate.model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1120, height: 720)
    }
}

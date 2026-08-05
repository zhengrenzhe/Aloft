import SwiftUI

@main
@MainActor
struct AloftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate

    @AppStorage(MenuBarIconPreference.storageKey)
    private var menuBarIconRawValue =
        MenuBarIconPreference.defaultChoice.rawValue

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: appDelegate.model)
        } label: {
            MenuBarStatusLabel(
                choice: MenuBarIconPreference.resolve(
                    menuBarIconRawValue
                ),
                runtime: appDelegate.model.runtime
            )
            .background {
                ManagementNotificationRouteBridge(
                    model: appDelegate.model
                )
            }
        }
        .menuBarExtraStyle(.menu)

        Window("Aloft", id: "management") {
            ManagementView(model: appDelegate.model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1120, height: 720)

        Settings {
            SettingsView()
        }
    }
}

struct MenuBarStatusLabel: View {
    let choice: MenuBarIconChoice
    let runtime: RuntimeStore

    @MainActor
    var liveCount: Int {
        runtime.liveEntryIDs.count
    }

    @MainActor
    var attentionCount: Int {
        runtime.unacknowledgedAttentionItems.count
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: choice.systemName)
                .font(.system(size: 16, weight: .semibold))
            if liveCount > 0 {
                Text("\(liveCount)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            if attentionCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(attentionCount)")
                    .font(
                        .system(size: 12, weight: .semibold)
                            .monospacedDigit()
                    )
            }
        }
        .accessibilityLabel("Aloft")
        .accessibilityValue(
            L10n.format(
                "Running: %lld · Needs attention: %lld",
                liveCount,
                attentionCount
            )
        )
    }
}

import SwiftUI

struct ManagementRouteRequest: Equatable, Identifiable, Sendable {
    let id: UUID
    let entryID: UUID

    init(id: UUID = UUID(), entryID: UUID) {
        self.id = id
        self.entryID = entryID
    }
}

@MainActor
struct ManagementNotificationRouteAction {
    let selectEntry: (UUID) -> Void
    let presentWindow: () -> Void

    func perform(_ request: ManagementRouteRequest) {
        selectEntry(request.entryID)
        presentWindow()
    }
}

struct ManagementNotificationRouteBridge: View {
    @Bindable var model: AppModel

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                consumePendingRoute()
            }
            .onChange(of: model.pendingManagementRoute) {
                consumePendingRoute()
            }
    }

    @MainActor
    private func consumePendingRoute() {
        guard let request = model.consumePendingManagementRoute() else {
            return
        }
        let action = ManagementNotificationRouteAction(
            selectEntry: { model.selectEntry($0) },
            presentWindow: {
                ManagementWindowPresenter().present {
                    openWindow(id: "management")
                }
            }
        )
        action.perform(request)
    }
}

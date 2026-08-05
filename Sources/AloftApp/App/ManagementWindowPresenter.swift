import AppKit

@MainActor
final class ManagementMenuTrackingActivationScheduler:
    NSObject {
    static let shared =
        ManagementMenuTrackingActivationScheduler()

    private let notificationCenter: NotificationCenter
    private var activation:
        ManagementWindowPresenter.Activation?

    init(
        notificationCenter: NotificationCenter =
            .default
    ) {
        self.notificationCenter = notificationCenter
        super.init()
    }

    func schedule(
        _ activation:
            @escaping ManagementWindowPresenter.Activation
    ) {
        notificationCenter.removeObserver(
            self,
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
        self.activation = activation
        notificationCenter.addObserver(
            self,
            selector: #selector(menuTrackingDidEnd),
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
        RunLoop.main.perform(inModes: [.default]) {
            [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.performScheduledActivation()
            }
        }
    }

    @objc
    private func menuTrackingDidEnd() {
        performScheduledActivation()
    }

    private func performScheduledActivation() {
        notificationCenter.removeObserver(
            self,
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
        let activation = self.activation
        self.activation = nil
        activation?()
    }
}

@MainActor
struct ManagementWindowPresenter {
    typealias Activation =
        @MainActor @Sendable () -> Void
    typealias ActivationScheduler =
        @MainActor (@escaping Activation) -> Void

    private let activateApplication: Activation
    private let scheduleActivation: ActivationScheduler

    init(
        activateApplication:
            @escaping Activation = {
            ManagementWindowRegistry.shared
                .presentRegisteredWindow()
        },
        scheduleActivation:
            @escaping ActivationScheduler = {
                activation in
            ManagementMenuTrackingActivationScheduler
                .shared
                .schedule(activation)
        }
    ) {
        self.activateApplication = activateApplication
        self.scheduleActivation = scheduleActivation
    }

    func present(openWindow: @MainActor () -> Void) {
        openWindow()
        scheduleActivation(activateApplication)
    }
}

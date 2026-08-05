import Foundation
import UserNotifications

struct UserNotificationPayload: Equatable, Sendable {
    let id: UUID
    let title: String
    let body: String
    let entryID: String?
}

@MainActor
protocol UserNotificationCenterClient: AnyObject {
    var responseHandler: ((String?) -> Void)? { get set }

    func requestAuthorization()
    func deliver(_ payload: UserNotificationPayload)
}

@MainActor
protocol UserNotificationDelivering: AnyObject {
    var onOpenEntry: ((UUID) -> Void)? { get set }

    func requestAuthorization()
    func deliver(_ item: RuntimeAttentionItem)
}

@MainActor
final class UserNotificationService: UserNotificationDelivering {
    var onOpenEntry: ((UUID) -> Void)?

    private let center: any UserNotificationCenterClient

    convenience init() {
        self.init(center: SystemUserNotificationCenterClient())
    }

    init(center: any UserNotificationCenterClient) {
        self.center = center
        center.responseHandler = { [weak self] rawEntryID in
            guard let rawEntryID,
                  let entryID = UUID(uuidString: rawEntryID) else {
                return
            }
            self?.onOpenEntry?(entryID)
        }
    }

    func requestAuthorization() {
        center.requestAuthorization()
    }

    func deliver(_ item: RuntimeAttentionItem) {
        center.deliver(
            UserNotificationPayload(
                id: item.id,
                title: item.title,
                body: item.detail,
                entryID: item.entryID?.uuidString
            )
        )
    }
}

@MainActor
private final class SystemUserNotificationCenterClient:
    NSObject,
    UserNotificationCenterClient,
    UNUserNotificationCenterDelegate {
    nonisolated static let entryIDKey = "entryID"

    var responseHandler: ((String?) -> Void)?

    private lazy var center: UNUserNotificationCenter = {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }()

    override init() {
        super.init()
    }

    func requestAuthorization() {
        center.requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }
    }

    func deliver(_ payload: UserNotificationPayload) {
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.sound = .default
        if let entryID = payload.entryID {
            content.userInfo = [Self.entryIDKey: entryID]
        }
        center.add(
            UNNotificationRequest(
                identifier: payload.id.uuidString,
                content: content,
                trigger: nil
            )
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let rawEntryID = response.notification.request.content
            .userInfo[Self.entryIDKey] as? String
        Task { @MainActor [weak self] in
            self?.responseHandler?(rawEntryID)
        }
        completionHandler()
    }
}

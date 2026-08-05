import AppKit
import Foundation
import XCTest
@testable import AloftApp

@MainActor
final class UserNotificationServiceTests: XCTestCase {
    func testDeliveryMapsAttentionToNativePayloadAndRoutesEntryResponse()
        throws {
        let center = UserNotificationCenterRecorder()
        let service = UserNotificationService(center: center)
        let entryID = UUID()
        let item = RuntimeAttentionItem(
            id: UUID(),
            entryID: entryID,
            kind: .unexpectedTermination,
            title: "Command Exited: Web",
            detail: "Exited with status 17.",
            createdAt: Date(timeIntervalSince1970: 123),
            isAcknowledged: false
        )
        var openedEntryIDs: [UUID] = []
        service.onOpenEntry = { openedEntryIDs.append($0) }

        service.deliver(item)

        XCTAssertEqual(
            center.payloads,
            [
                UserNotificationPayload(
                    id: item.id,
                    title: item.title,
                    body: item.detail,
                    entryID: entryID.uuidString
                ),
            ]
        )

        center.respond(entryID: entryID.uuidString)

        XCTAssertEqual(openedEntryIDs, [entryID])
    }

    func testMalformedOrMissingEntryResponseDoesNotRoute() {
        let center = UserNotificationCenterRecorder()
        let service = UserNotificationService(center: center)
        var openedEntryIDs: [UUID] = []
        service.onOpenEntry = { openedEntryIDs.append($0) }

        center.respond(entryID: nil)
        center.respond(entryID: "not-a-uuid")

        XCTAssertTrue(openedEntryIDs.isEmpty)
    }

    func testAuthorizationRequestForwardsExactlyOnce() {
        let center = UserNotificationCenterRecorder()
        let service = UserNotificationService(center: center)

        service.requestAuthorization()

        XCTAssertEqual(center.authorizationRequestCount, 1)
    }
}

@MainActor
final class AppDelegateNotificationTests: XCTestCase {
    func testNormalLaunchRequestsAuthorizationAndDeliversRuntimeAttention()
        throws {
        _ = NSApplication.shared
        let model = try makeNotificationModel()
        let notifications = UserNotificationDeliveryRecorder()
        let delegate = AppDelegate(
            model: model,
            userNotificationService: notifications
        )
        let entry = try XCTUnwrap(
            model.workspace.configuration.groups.first?
                .entries.first
        )

        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        model.runtime.recordOperationFailure(
            operation: .stop,
            entries: [entry],
            results: [
                EntryActionResult(
                    entryID: entry.id,
                    errorDescription: "Timed out"
                ),
            ]
        )

        XCTAssertEqual(notifications.authorizationRequestCount, 1)
        XCTAssertEqual(notifications.delivered.count, 1)
        XCTAssertEqual(notifications.delivered.first?.entryID, entry.id)
    }

    func testNotificationResponseCreatesOneConsumableManagementRoute()
        throws {
        let model = try makeNotificationModel()
        let notifications = UserNotificationDeliveryRecorder()
        _ = AppDelegate(
            model: model,
            userNotificationService: notifications
        )
        let entryID = try XCTUnwrap(
            model.workspace.configuration.groups.first?
                .entries.first?.id
        )

        notifications.open(entryID: entryID)

        XCTAssertEqual(
            model.pendingManagementRoute?.entryID,
            entryID
        )
        let consumed = model.consumePendingManagementRoute()
        XCTAssertEqual(consumed?.entryID, entryID)
        XCTAssertNil(model.consumePendingManagementRoute())
    }
}

@MainActor
final class ManagementNotificationRouteTests: XCTestCase {
    func testRouteActionSelectsEntryAndPresentsWindowOnce() throws {
        let model = try makeNotificationModel()
        let entryID = try XCTUnwrap(
            model.workspace.configuration.groups.first?
                .entries.first?.id
        )
        var presentationCount = 0
        let action = ManagementNotificationRouteAction(
            selectEntry: { model.selectEntry($0) },
            presentWindow: { presentationCount += 1 }
        )
        let request = ManagementRouteRequest(entryID: entryID)

        action.perform(request)

        XCTAssertEqual(model.selectedEntryID, entryID)
        XCTAssertEqual(presentationCount, 1)
    }
}

@MainActor
private final class UserNotificationCenterRecorder:
    UserNotificationCenterClient {
    var responseHandler: ((String?) -> Void)?
    private(set) var authorizationRequestCount = 0
    private(set) var payloads: [UserNotificationPayload] = []

    func requestAuthorization() {
        authorizationRequestCount += 1
    }

    func deliver(_ payload: UserNotificationPayload) {
        payloads.append(payload)
    }

    func respond(entryID: String?) {
        responseHandler?(entryID)
    }
}

@MainActor
private final class UserNotificationDeliveryRecorder:
    UserNotificationDelivering {
    var onOpenEntry: ((UUID) -> Void)?
    private(set) var authorizationRequestCount = 0
    private(set) var delivered: [RuntimeAttentionItem] = []

    func requestAuthorization() {
        authorizationRequestCount += 1
    }

    func deliver(_ item: RuntimeAttentionItem) {
        delivered.append(item)
    }

    func open(entryID: UUID) {
        onOpenEntry?(entryID)
    }
}

@MainActor
private func makeNotificationModel() throws -> AppModel {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let repository = ConfigurationRepository(
        fileURL: directory.appendingPathComponent("config.json")
    )
    let workspace = try WorkspaceStore(repository: repository)
    let groupID = try workspace.addGroup(name: "Development")
    _ = try workspace.addEntry(
        to: groupID,
        name: "Web",
        cwd: "/tmp",
        command: "echo Web",
        keywords: []
    )
    return AppModel(
        workspace: workspace,
        runtime: RuntimeStore(supervisor: ProcessSupervisor()),
        ghostty: GhosttyService()
    )
}

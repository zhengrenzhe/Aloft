import AppKit
import XCTest
@testable import AloftApp

@MainActor
private final class ManagementWindowEventRecorder {
    var events: [String] = []
    var scheduledActivation:
        ManagementWindowPresenter.Activation?
}

@MainActor
final class ManagementWindowPresenterTests: XCTestCase {
    func testPresentDefersActivationUntilAfterOpeningScene() {
        let recorder = ManagementWindowEventRecorder()
        let presenter = ManagementWindowPresenter(
            activateApplication: {
                recorder.events.append("activate")
            },
            scheduleActivation: { activation in
                recorder.events.append("schedule")
                recorder.scheduledActivation = activation
            }
        )

        presenter.present {
            recorder.events.append("open")
        }

        XCTAssertEqual(
            recorder.events,
            ["open", "schedule"]
        )

        recorder.scheduledActivation?()

        XCTAssertEqual(
            recorder.events,
            ["open", "schedule", "activate"]
        )
    }

    func testWindowActivationActionActivatesBeforeOrderingFront() {
        let window = NSWindow()
        var events: [String] = []
        let action = ManagementWindowActivationAction(
            activateApplication: {
                events.append("activate")
            },
            orderFront: { receivedWindow in
                XCTAssertIdentical(receivedWindow, window)
                events.append("front")
            }
        )

        action.perform(on: window)

        XCTAssertEqual(events, ["activate", "front"])
    }

    func testWindowRegistryActivatesAndOrdersRegisteredWindowFront() {
        let window = NSWindow()
        var events: [String] = []
        let registry = ManagementWindowRegistry(
            activationAction: ManagementWindowActivationAction(
                activateApplication: {
                    events.append("activate")
                },
                orderFront: { receivedWindow in
                    XCTAssertIdentical(receivedWindow, window)
                    events.append("front")
                }
            )
        )
        registry.register(window)

        registry.presentRegisteredWindow()

        XCTAssertEqual(events, ["activate", "front"])
    }

    func testWindowRegistryStillActivatesWhenWindowIsNotRegistered() {
        var events: [String] = []
        let registry = ManagementWindowRegistry(
            activationAction: ManagementWindowActivationAction(
                activateApplication: {
                    events.append("activate")
                },
                orderFront: { _ in
                    events.append("front")
                }
            )
        )

        registry.presentRegisteredWindow()

        XCTAssertEqual(events, ["activate"])
    }

    func testMenuTrackingSchedulerActivatesOnceWhenTrackingEnds() {
        let center = NotificationCenter()
        let recorder = ManagementWindowEventRecorder()
        let scheduler =
            ManagementMenuTrackingActivationScheduler(
                notificationCenter: center
            )

        scheduler.schedule {
            recorder.events.append("activate")
        }
        center.post(
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
        center.post(
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )

        XCTAssertEqual(recorder.events, ["activate"])
    }

    func testMenuTrackingSchedulerActivatesWhenActionArrivesAfterTrackingEnded()
        async {
        let center = NotificationCenter()
        let recorder = ManagementWindowEventRecorder()
        let scheduler =
            ManagementMenuTrackingActivationScheduler(
                notificationCenter: center
            )
        let activated = expectation(
            description: "activation ran on the default run loop"
        )
        center.post(
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )

        scheduler.schedule {
            recorder.events.append("activate")
            activated.fulfill()
        }

        await fulfillment(of: [activated], timeout: 0.2)
        XCTAssertEqual(recorder.events, ["activate"])
    }

    func testAttachmentViewReportsBackingWindowOnNextRunLoop()
        async {
        let window = NSWindow()
        var attachedWindow: NSWindow?
        let reported = expectation(
            description: "backing window reported"
        )
        let view = ManagementWindowAttachmentView {
            attachedWindow = $0
            reported.fulfill()
        }

        window.contentView = view

        XCTAssertNil(attachedWindow)
        await fulfillment(of: [reported], timeout: 1)
        XCTAssertIdentical(attachedWindow, window)
    }
}

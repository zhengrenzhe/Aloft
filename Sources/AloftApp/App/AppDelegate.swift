import AppKit
import Foundation

struct StartupReadinessReporter {
    private static let marker = Data(
        "ALOFT_STARTUP_READY\n".utf8
    )

    static func reportIfRequested(
        environment: [String: String],
        write: (Data) -> Void
    ) {
        guard environment[
            "ALOFT_VERIFY_STARTUP"
        ] == "1" else {
            return
        }
        write(marker)
    }
}

enum ApplicationTerminationDisposition: Equatable, Sendable {
    case terminateNow
    case beginDeferredTermination
    case awaitDeferredTermination
}

struct TerminationAlertPresentation: Equatable, Sendable {
    let messageText: String
    let informativeText: String
}

struct ApplicationTerminationCompletion: Equatable, Sendable {
    let shouldTerminate: Bool
    let alert: TerminationAlertPresentation?
}

struct ApplicationTerminationState: Sendable {
    private enum Phase: Sendable {
        case idle
        case deferred
        case completing
    }

    private var phase: Phase = .idle

    mutating func request(
        liveEntryIDs: Set<UUID>,
        protectedEntryIDs: Set<UUID>,
        inFlightLaunchCount: Int
    ) -> ApplicationTerminationDisposition {
        guard phase == .idle else {
            return .awaitDeferredTermination
        }
        let hasManagedWork = !liveEntryIDs.isEmpty
            || !protectedEntryIDs.isEmpty
            || inFlightLaunchCount > 0
        guard hasManagedWork else {
            return .terminateNow
        }
        phase = .deferred
        return .beginDeferredTermination
    }

    mutating func complete(
        result: TerminationResult,
        entryNames: [UUID: String]
    ) -> ApplicationTerminationCompletion? {
        guard phase == .deferred else {
            return nil
        }
        phase = .completing

        switch result {
        case .safeToTerminate:
            return ApplicationTerminationCompletion(
                shouldTerminate: true,
                alert: nil
            )
        case .cancelled:
            return ApplicationTerminationCompletion(
                shouldTerminate: false,
                alert: nil
            )
        case .remaining(let remaining):
            return ApplicationTerminationCompletion(
                shouldTerminate: false,
                alert: Self.alert(
                    remaining: remaining,
                    entryNames: entryNames
                )
            )
        }
    }

    mutating func didReply() {
        guard phase == .completing else {
            return
        }
        phase = .idle
    }

    private static func alert(
        remaining: [RemainingProcess],
        entryNames: [UUID: String]
    ) -> TerminationAlertPresentation {
        let lines = remaining
            .sorted {
                $0.entryID.uuidString < $1.entryID.uuidString
            }
            .map { process in
                let name = entryNames[process.entryID]
                    ?? process.entryID.uuidString
                return "\(name) — PGID \(process.processGroupID)"
            }
        return TerminationAlertPresentation(
            messageText: L10n.string(
                "Aloft Could Not Stop All Commands"
            ),
            informativeText: lines.isEmpty
                ? L10n.string(
                    "No process identity was available."
                )
                : lines.joined(separator: "\n")
        )
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    typealias StopAllForTermination =
        @MainActor () async -> TerminationResult
    typealias ReplyToTermination = @MainActor (Bool) -> Void
    typealias PresentTerminationAlert =
        @MainActor (TerminationAlertPresentation) -> Void

    let model: AppModel

    private let stopAllForTermination: StopAllForTermination
    private let replyToTermination: ReplyToTermination
    private let presentTerminationAlert: PresentTerminationAlert
    private let userNotificationService:
        any UserNotificationDelivering
    private var terminationState = ApplicationTerminationState()
    private var terminationTask: Task<Void, Never>?
    private var terminalBenchmarkController:
        ReleaseTerminalBenchmarkController?

    override convenience init() {
        self.init(model: AppModel.bootstrap())
    }

    init(
        model: AppModel,
        stopAllForTermination: StopAllForTermination? = nil,
        replyToTermination: ReplyToTermination? = nil,
        presentTerminationAlert: PresentTerminationAlert? = nil,
        userNotificationService:
            (any UserNotificationDelivering)? = nil
    ) {
        self.model = model
        let notifications = userNotificationService
            ?? UserNotificationService()
        self.userNotificationService = notifications
        self.stopAllForTermination = stopAllForTermination ?? {
            await TerminationCoordinator(
                runtimeStore: model.runtime
            ).stopAllForTermination()
        }
        self.replyToTermination = replyToTermination ?? {
            NSApp.reply(toApplicationShouldTerminate: $0)
        }
        self.presentTerminationAlert = presentTerminationAlert ?? {
            presentation in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = presentation.messageText
            alert.informativeText = presentation.informativeText
            alert.addButton(withTitle: L10n.string("OK"))
            alert.runModal()
        }
        super.init()
        notifications.onOpenEntry = { [weak model] entryID in
            model?.requestManagementRoute(entryID: entryID)
        }
        model.runtime.onAttention = { [weak notifications] item in
            notifications?.deliver(item)
        }
    }

    func applicationDidFinishLaunching(
        _ notification: Notification
    ) {
        if let configuration =
            ReleaseTerminalBenchmarkConfiguration.resolve(
                environment:
                    ProcessInfo.processInfo.environment
            ) {
            let controller =
                ReleaseTerminalBenchmarkController(
                    configuration: configuration
                )
            terminalBenchmarkController = controller
            controller.start()
            return
        }
        NSApp.setActivationPolicy(.accessory)
        userNotificationService.requestAuthorization()
        let environment = ProcessInfo.processInfo.environment
        DispatchQueue.main.async {
            StartupReadinessReporter.reportIfRequested(
                environment: environment,
                write: { data in
                    FileHandle.standardError.write(data)
                }
            )
        }
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        let disposition = terminationState.request(
            liveEntryIDs: model.runtime.liveEntryIDs,
            protectedEntryIDs: model.runtime.protectedEntryIDs,
            inFlightLaunchCount: model.runtime.inFlightLaunchCount
        )
        switch disposition {
        case .terminateNow:
            model.runtime.disposeAllTerminalSurfaces()
            return .terminateNow
        case .awaitDeferredTermination:
            return .terminateLater
        case .beginDeferredTermination:
            terminationTask = Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                let result = await self.stopAllForTermination()
                self.finishDeferredTermination(with: result)
            }
            return .terminateLater
        }
    }

    private func finishDeferredTermination(
        with result: TerminationResult
    ) {
        let entryNames = Dictionary(
            uniqueKeysWithValues: model.orderedGroups
                .flatMap(\.entries)
                .map { ($0.id, $0.name) }
        )
        guard let completion = terminationState.complete(
            result: result,
            entryNames: entryNames
        ) else {
            return
        }
        if let alert = completion.alert {
            presentTerminationAlert(alert)
        }
        if completion.shouldTerminate {
            model.runtime.disposeAllTerminalSurfaces()
        }
        replyToTermination(completion.shouldTerminate)
        terminationState.didReply()
        terminationTask = nil
    }
}

import AppKit

@MainActor
enum ForceStopConfirmationService {
    static func confirm(_ confirmation: ForceStopConfirmation) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        let isGroup = confirmation.entries.count > 1
        switch confirmation.operation {
        case .stop:
            alert.messageText = L10n.string(
                isGroup
                    ? "Commands Did Not Stop"
                    : "Command Did Not Stop"
            )
            alert.addButton(withTitle: L10n.string("Force Stop"))
        case .restart:
            alert.messageText = L10n.string(
                isGroup
                    ? "Commands Did Not Restart"
                    : "Command Did Not Restart"
            )
            alert.addButton(
                withTitle: L10n.string("Force Stop and Restart")
            )
        }
        alert.informativeText = informativeText(for: confirmation)
        alert.addButton(withTitle: L10n.string("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func informativeText(
        for confirmation: ForceStopConfirmation
    ) -> String {
        let processGroups = confirmation.entries.map {
            "\($0.name) — PGID \($0.processGroupID)"
        }.joined(separator: "\n")
        return [
            L10n.string(
                "SIGTERM timed out after 5 seconds. Force stopping sends SIGKILL to the listed process groups."
            ),
            processGroups,
        ].joined(separator: "\n\n")
    }
}

import Darwin
import Foundation

struct ShellOption: Equatable, Identifiable, Sendable {
    let path: String
    let isSystemDefault: Bool

    var id: String { path }

    var displayName: String {
        guard isSystemDefault else {
            return path
        }
        return L10n.format("%@ (System Default)", path)
    }
}

enum ShellCatalog {
    static let supportedNames: Set<String> = [
        "sh",
        "bash",
        "dash",
        "ksh",
        "zsh",
    ]

    static var available: [ShellOption] {
        availableShellPaths().map {
            ShellOption(
                path: $0,
                isSystemDefault: $0 == systemDefaultShell
            )
        }
    }

    static var systemDefaultShell: String {
        guard let account = getpwuid(getuid()),
              let pointer = account.pointee.pw_shell else {
            return fallbackShell()
        }
        let shell = String(cString: pointer)
        guard isAvailableAndSupported(shell) else {
            return fallbackShell()
        }
        return shell
    }

    static func isAvailableAndSupported(_ path: String) -> Bool {
        availableShellPaths().contains(path)
    }

    static func normalizedSelection(_ path: String) -> String {
        isAvailableAndSupported(path) ? path : systemDefaultShell
    }

    static func parseSupportedShells(
        _ contents: String,
        isExecutable: (String) -> Bool
    ) -> [String] {
        var seen: Set<String> = []
        return contents
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let value = line.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard value.hasPrefix("/"),
                      !value.hasPrefix("#"),
                      supportedNames.contains(
                        URL(fileURLWithPath: value).lastPathComponent
                      ),
                      isExecutable(value),
                      seen.insert(value).inserted else {
                    return nil
                }
                return value
            }
    }

    private static func availableShellPaths() -> [String] {
        let contents = (
            try? String(
                contentsOfFile: "/etc/shells",
                encoding: .utf8
            )
        ) ?? ""
        let shells = parseSupportedShells(contents) {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        guard !shells.isEmpty else {
            return ["/bin/sh"]
        }
        return shells
    }

    private static func fallbackShell() -> String {
        let available = availableShellPaths()
        if available.contains("/bin/zsh") {
            return "/bin/zsh"
        }
        if available.contains("/bin/sh") {
            return "/bin/sh"
        }
        return available[0]
    }
}

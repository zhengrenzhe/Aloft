import AppKit
import Foundation

struct GhosttyVersion: Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(_ string: String) {
        let components = string.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard (1...3).contains(components.count) else {
            return nil
        }

        var values: [Int] = []
        values.reserveCapacity(3)
        for component in components {
            guard !component.isEmpty,
                  component.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(component) else {
                return nil
            }
            values.append(value)
        }
        while values.count < 3 {
            values.append(0)
        }

        major = values[0]
        minor = values[1]
        patch = values[2]
    }

    var supportsAppleScript: Bool {
        self >= GhosttyVersion(major: 1, minor: 3, patch: 0)
    }

    static func < (lhs: GhosttyVersion, rhs: GhosttyVersion) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        if lhs.minor != rhs.minor {
            return lhs.minor < rhs.minor
        }
        return lhs.patch < rhs.patch
    }
}

enum GhosttyStatus: Equatable, Sendable {
    case available(GhosttyVersion)
    case notInstalled
    case unsupported(GhosttyVersion)
}

enum GhosttyServiceError: Error, Equatable, LocalizedError, Sendable {
    case notInstalled
    case unsupported(GhosttyVersion)
    case invalidWorkingDirectory(String)
    case appleScript(message: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return L10n.string(
                "Ghostty is not installed in /Applications."
            )
        case .unsupported(let version):
            return L10n.format(
                "Ghostty %@.%@.%@ does not support companion shells.",
                String(version.major),
                String(version.minor),
                String(version.patch)
            )
        case .invalidWorkingDirectory(let path):
            return L10n.format(
                "The working directory does not exist or is not a directory: %@",
                path
            )
        case .appleScript(let message):
            return message
        }
    }
}

@MainActor
struct GhosttyService {
    typealias AppleScriptExecutor = @MainActor (String) -> NSDictionary?

    static let applicationURL = URL(
        fileURLWithPath: "/Applications/Ghostty.app",
        isDirectory: true
    )

    private let installedApplicationURL: URL
    private let fileManager: FileManager
    private let executeAppleScript: AppleScriptExecutor

    init(
        applicationURL: URL = GhosttyService.applicationURL,
        fileManager: FileManager = .default,
        executeAppleScript: AppleScriptExecutor? = nil
    ) {
        installedApplicationURL = applicationURL
        self.fileManager = fileManager
        self.executeAppleScript =
            executeAppleScript ?? GhosttyService.execute(source:)
    }

    func status() -> GhosttyStatus {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: installedApplicationURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue,
            let bundle = Bundle(url: installedApplicationURL),
            let versionString = bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String,
            let version = GhosttyVersion(versionString) else {
            return .notInstalled
        }

        if version.supportsAppleScript {
            return .available(version)
        }
        return .unsupported(version)
    }

    func openShell(cwd: String) throws {
        switch status() {
        case .available:
            break
        case .notInstalled:
            throw GhosttyServiceError.notInstalled
        case .unsupported(let version):
            throw GhosttyServiceError.unsupported(version)
        }

        guard !cwd.isEmpty else {
            throw GhosttyServiceError.invalidWorkingDirectory(cwd)
        }
        let currentDirectoryURL = URL(
            fileURLWithPath: fileManager.currentDirectoryPath,
            isDirectory: true
        )
        let cwdURL: URL
        if cwd.first == "/" {
            cwdURL = URL(fileURLWithPath: cwd)
        } else {
            cwdURL = currentDirectoryURL.appendingPathComponent(cwd)
        }
        let resolvedCWD = cwdURL.standardizedFileURL.path

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: resolvedCWD,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw GhosttyServiceError.invalidWorkingDirectory(resolvedCWD)
        }

        let errorDictionary = executeAppleScript(
            Self.appleScriptSource(cwd: resolvedCWD)
        )
        if let errorDictionary {
            throw GhosttyServiceError.appleScript(
                message: Self.errorMessage(from: errorDictionary)
            )
        }
    }

    static func appleScriptSource(cwd: String) -> String {
        let escapedCWD = cwd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "Ghostty"
            activate
            set cfg to new surface configuration
            set initial working directory of cfg to "\(escapedCWD)"
            new window with configuration cfg
        end tell
        """
    }

    private static func execute(source: String) -> NSDictionary? {
        guard let script = NSAppleScript(source: source) else {
            return [
                NSAppleScript.errorMessage:
                    L10n.string(
                        "The Ghostty AppleScript could not be created."
                    )
            ]
        }
        var errorDictionary: NSDictionary?
        _ = script.executeAndReturnError(&errorDictionary)
        return errorDictionary
    }

    private static func errorMessage(
        from dictionary: NSDictionary
    ) -> String {
        if let message = dictionary[NSAppleScript.errorMessage] as? String,
           !message.isEmpty {
            return message
        }
        if let message = dictionary[
            NSAppleScript.errorBriefMessage
        ] as? String, !message.isEmpty {
            return message
        }
        if let number = dictionary[
            NSAppleScript.errorNumber
        ] as? NSNumber {
            return L10n.format(
                "AppleScript error %@",
                String(number.intValue)
            )
        }
        return L10n.string("AppleScript execution failed.")
    }
}

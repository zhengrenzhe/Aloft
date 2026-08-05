import Foundation

enum MenuBarIconChoice: String, CaseIterable, Identifiable, Sendable {
    case bolt = "bolt.circle.fill"
    case terminal = "terminal.fill"
    case command = "command.circle.fill"
    case play = "play.circle.fill"

    var id: String {
        rawValue
    }

    var systemName: String {
        rawValue
    }
}

enum MenuBarIconPreference {
    static let storageKey = "menuBarIcon"
    static let defaultChoice = MenuBarIconChoice.bolt

    static func resolve(_ rawValue: String?) -> MenuBarIconChoice {
        guard let rawValue,
              let choice = MenuBarIconChoice(rawValue: rawValue) else {
            return defaultChoice
        }
        return choice
    }
}

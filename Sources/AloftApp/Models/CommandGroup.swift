import Foundation

struct CommandGroup: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var order: Int
    var entries: [CommandEntry]
}

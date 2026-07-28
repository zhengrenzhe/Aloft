import Foundation

struct CommandEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var cwd: String
    var command: String
    var keywords: [String]
    var order: Int
}

import Foundation

struct CommandEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var cwd: String
    var command: String
    var shell: String
    var keywords: [String]
    var order: Int

    init(
        id: UUID,
        name: String,
        cwd: String,
        command: String,
        shell: String = ShellCatalog.systemDefaultShell,
        keywords: [String],
        order: Int
    ) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.command = command
        self.shell = shell
        self.keywords = keywords
        self.order = order
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case cwd
        case command
        case shell
        case keywords
        case order
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        cwd = try container.decode(String.self, forKey: .cwd)
        command = try container.decode(String.self, forKey: .command)
        shell = try container.decodeIfPresent(
            String.self,
            forKey: .shell
        ) ?? ShellCatalog.systemDefaultShell
        keywords = try container.decode(
            [String].self,
            forKey: .keywords
        )
        order = try container.decode(Int.self, forKey: .order)
    }
}

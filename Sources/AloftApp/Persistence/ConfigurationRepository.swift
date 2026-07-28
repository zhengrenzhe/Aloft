import Foundation

struct ConfigurationRepository: Sendable {
    let fileURL: URL

    func load() throws -> WorkspaceConfiguration {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty
        }
        return try JSONDecoder().decode(
            WorkspaceConfiguration.self,
            from: Data(contentsOf: fileURL)
        )
    }

    func save(_ configuration: WorkspaceConfiguration) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: fileURL, options: .atomic)
    }
}

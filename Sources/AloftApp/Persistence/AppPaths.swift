import Foundation

enum AppPaths {
    static func configurationURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("Aloft", isDirectory: true)
            .appendingPathComponent("config.json")
    }
}

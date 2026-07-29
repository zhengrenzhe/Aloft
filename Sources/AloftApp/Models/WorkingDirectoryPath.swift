import Foundation

enum WorkingDirectoryPath {
    static func normalize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return (trimmed as NSString).expandingTildeInPath
    }
}

struct WorkspaceConfiguration: Codable, Equatable, Sendable {
    var groups: [CommandGroup]
    static let empty = WorkspaceConfiguration(groups: [])
}

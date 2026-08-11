import Foundation

enum ProcessTerminationKind: Equatable, Sendable {
    case normal
    case unexpected
    case intentional
    case unavailable
}

struct ProcessTerminationRecord: Equatable, Sendable {
    let endedAt: Date
    let result: ChildWaitResult?
    let kind: ProcessTerminationKind
    let detail: String
}

enum RuntimeAttentionKind: Equatable, Sendable {
    case unexpectedTermination
    case operationFailure
}

struct RuntimeAttentionItem: Equatable, Identifiable, Sendable {
    let id: UUID
    let entryID: UUID?
    let relatedEntryIDs: Set<UUID>
    let kind: RuntimeAttentionKind
    let title: String
    let detail: String
    let createdAt: Date
    var isAcknowledged: Bool

    init(
        id: UUID,
        entryID: UUID?,
        kind: RuntimeAttentionKind,
        title: String,
        detail: String,
        createdAt: Date,
        relatedEntryIDs: Set<UUID>? = nil,
        isAcknowledged: Bool
    ) {
        self.id = id
        self.entryID = entryID
        self.relatedEntryIDs = relatedEntryIDs
            ?? entryID.map { [$0] }
            ?? []
        self.kind = kind
        self.title = title
        self.detail = detail
        self.createdAt = createdAt
        self.isAcknowledged = isAcknowledged
    }
}

enum RuntimeOperationName: Equatable, Sendable {
    case stop
    case restart
}

struct ForceStopConfirmationEntry: Equatable, Sendable {
    let entryID: UUID
    let name: String
    let processGroupID: pid_t
}

struct ForceStopConfirmation: Equatable, Sendable {
    let operation: RuntimeOperationName
    let entries: [ForceStopConfirmationEntry]
}

typealias ForceStopConfirmationHandler = @MainActor (
    ForceStopConfirmation
) async -> Bool

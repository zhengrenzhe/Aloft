import Foundation

struct KeywordMatchEvent: Equatable, Sendable {
    let entryID: UUID
    let keyword: String
    let line: String
    let timestamp: Date
}

struct KeywordMatcher: Sendable {
    let entryID: UUID
    let keywords: [String]
    private var matchedKeywordsForRevision: Set<String> = []
    private var priorRevision = ""

    init(entryID: UUID, keywords: [String]) {
        self.entryID = entryID
        self.keywords = keywords
    }

    mutating func matches(in lineRevision: String, at timestamp: Date) -> [KeywordMatchEvent] {
        if lineRevision != priorRevision {
            matchedKeywordsForRevision = Set(
                matchedKeywordsForRevision.filter { lineRevision.contains($0) }
            )
            priorRevision = lineRevision
        }

        var events: [KeywordMatchEvent] = []
        for keyword in keywords where !keyword.isEmpty {
            guard lineRevision.contains(keyword), matchedKeywordsForRevision.insert(keyword).inserted else {
                continue
            }
            events.append(
                KeywordMatchEvent(
                    entryID: entryID,
                    keyword: keyword,
                    line: lineRevision,
                    timestamp: timestamp
                )
            )
        }
        return events
    }

    mutating func reset() {
        matchedKeywordsForRevision.removeAll()
        priorRevision = ""
    }
}

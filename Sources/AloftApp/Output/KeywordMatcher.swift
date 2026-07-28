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
    private var patterns: [Pattern]

    init(entryID: UUID, keywords: [String]) {
        self.entryID = entryID
        self.keywords = keywords
        var seenKeywords: Set<String> = []
        patterns = keywords.compactMap { keyword in
            guard !keyword.isEmpty, seenKeywords.insert(keyword).inserted else {
                return nil
            }
            return Pattern(keyword: keyword)
        }
    }

    mutating func matches(in lineRevision: String, at timestamp: Date) -> [KeywordMatchEvent] {
        guard lineRevision != priorRevision else { return [] }

        let previouslyMatchedKeywords = matchedKeywordsForRevision
        matchedKeywordsForRevision.removeAll()
        resetPatternStates()
        var events: [KeywordMatchEvent] = []
        for scalar in lineRevision.unicodeScalars {
            for index in patterns.indices where patterns[index].advance(with: scalar) {
                let keyword = patterns[index].keyword
                guard matchedKeywordsForRevision.insert(keyword).inserted,
                      !previouslyMatchedKeywords.contains(keyword)
                else {
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
        }
        priorRevision = lineRevision
        return events
    }

    mutating func append(
        _ scalar: Unicode.Scalar,
        in lineRevision: String,
        at timestamp: Date
    ) -> [KeywordMatchEvent] {
        var events: [KeywordMatchEvent] = []
        for index in patterns.indices {
            guard patterns[index].advance(with: scalar) else {
                continue
            }
            let keyword = patterns[index].keyword
            guard matchedKeywordsForRevision.insert(keyword).inserted else { continue }
            events.append(
                KeywordMatchEvent(
                    entryID: entryID,
                    keyword: keyword,
                    line: lineRevision,
                    timestamp: timestamp
                )
            )
        }
        priorRevision = lineRevision
        return events
    }

    mutating func reset() {
        resetRevision()
    }

    mutating func resetRevision() {
        matchedKeywordsForRevision.removeAll()
        priorRevision = ""
        resetPatternStates()
    }

    private mutating func resetPatternStates() {
        for index in patterns.indices {
            patterns[index].reset()
        }
    }

    private struct Pattern: Sendable {
        let keyword: String
        let scalars: [Unicode.Scalar]
        let prefixLengths: [Int]
        var matchedLength = 0

        init(keyword: String) {
            self.keyword = keyword
            scalars = Array(keyword.unicodeScalars)
            prefixLengths = Self.makePrefixLengths(for: scalars)
        }

        mutating func advance(with scalar: Unicode.Scalar) -> Bool {
            while matchedLength > 0, scalar != scalars[matchedLength] {
                matchedLength = prefixLengths[matchedLength - 1]
            }
            if scalar == scalars[matchedLength] {
                matchedLength += 1
            }
            guard matchedLength == scalars.count else { return false }

            matchedLength = prefixLengths[matchedLength - 1]
            return true
        }

        mutating func reset() {
            matchedLength = 0
        }

        private static func makePrefixLengths(for scalars: [Unicode.Scalar]) -> [Int] {
            var prefixLengths = Array(repeating: 0, count: scalars.count)
            var prefixLength = 0

            for index in 1..<scalars.count {
                while prefixLength > 0, scalars[index] != scalars[prefixLength] {
                    prefixLength = prefixLengths[prefixLength - 1]
                }
                if scalars[index] == scalars[prefixLength] {
                    prefixLength += 1
                }
                prefixLengths[index] = prefixLength
            }
            return prefixLengths
        }
    }
}

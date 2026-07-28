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
    private var trailingCharacter = ""
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
        resetStreamingState()
        var events: [KeywordMatchEvent] = []
        for character in lineRevision {
            appendCommitted(
                character,
                in: lineRevision,
                at: timestamp,
                previouslyMatchedKeywords: previouslyMatchedKeywords,
                events: &events
            )
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
        let candidateCharacters = Array(trailingCharacter + String(scalar))
        guard let latestCharacter = candidateCharacters.last else { return events }

        if candidateCharacters.count > 1 {
            for character in candidateCharacters.dropLast() {
                appendCommitted(
                    character,
                    in: lineRevision,
                    at: timestamp,
                    previouslyMatchedKeywords: nil,
                    events: &events
                )
            }
        }
        trailingCharacter = String(latestCharacter)
        return events
    }

    mutating func flushTrailingCharacter(
        in lineRevision: String,
        at timestamp: Date
    ) -> [KeywordMatchEvent] {
        guard let character = trailingCharacter.first else { return [] }

        var events: [KeywordMatchEvent] = []
        appendSpeculative(
            character,
            in: lineRevision,
            at: timestamp,
            events: &events
        )
        return events
    }

    mutating func finishRevision(
        in lineRevision: String,
        at timestamp: Date
    ) -> [KeywordMatchEvent] {
        guard let character = trailingCharacter.first else { return [] }

        trailingCharacter = ""
        var events: [KeywordMatchEvent] = []
        appendCommitted(
            character,
            in: lineRevision,
            at: timestamp,
            previouslyMatchedKeywords: nil,
            events: &events
        )
        return events
    }

    mutating func reset() {
        resetRevision()
    }

    mutating func resetRevision() {
        matchedKeywordsForRevision.removeAll()
        priorRevision = ""
        resetStreamingState()
    }

    private mutating func resetStreamingState() {
        trailingCharacter = ""
        for index in patterns.indices {
            patterns[index].reset()
        }
    }

    private mutating func appendCommitted(
        _ character: Character,
        in lineRevision: String,
        at timestamp: Date,
        previouslyMatchedKeywords: Set<String>?,
        events: inout [KeywordMatchEvent]
    ) {
        for index in patterns.indices where patterns[index].advanceCommitted(with: character) {
            record(
                patterns[index].keyword,
                in: lineRevision,
                at: timestamp,
                previouslyMatchedKeywords: previouslyMatchedKeywords,
                events: &events
            )
        }
    }

    private mutating func appendSpeculative(
        _ character: Character,
        in lineRevision: String,
        at timestamp: Date,
        events: inout [KeywordMatchEvent]
    ) {
        for pattern in patterns where pattern.matchesTrailing(character) {
            record(
                pattern.keyword,
                in: lineRevision,
                at: timestamp,
                previouslyMatchedKeywords: nil,
                events: &events
            )
        }
    }

    private mutating func record(
        _ keyword: String,
        in lineRevision: String,
        at timestamp: Date,
        previouslyMatchedKeywords: Set<String>?,
        events: inout [KeywordMatchEvent]
    ) {
        guard matchedKeywordsForRevision.insert(keyword).inserted,
              previouslyMatchedKeywords?.contains(keyword) != true
        else {
            return
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

    private struct Pattern: Sendable {
        let keyword: String
        let characters: [Character]
        let prefixLengths: [Int]
        var committedMatchLength = 0

        init(keyword: String) {
            self.keyword = keyword
            characters = Array(keyword)
            prefixLengths = Self.makePrefixLengths(for: characters)
        }

        mutating func advanceCommitted(with character: Character) -> Bool {
            let result = advanced(from: committedMatchLength, with: character)
            committedMatchLength = result.length
            return result.matched
        }

        func matchesTrailing(_ character: Character) -> Bool {
            advanced(from: committedMatchLength, with: character).matched
        }

        mutating func reset() {
            committedMatchLength = 0
        }

        private func advanced(from initialLength: Int, with character: Character) -> (length: Int, matched: Bool) {
            var matchedLength = initialLength
            while matchedLength > 0, character != characters[matchedLength] {
                matchedLength = prefixLengths[matchedLength - 1]
            }
            if character == characters[matchedLength] {
                matchedLength += 1
            }
            guard matchedLength == characters.count else {
                return (matchedLength, false)
            }
            return (prefixLengths[matchedLength - 1], true)
        }

        private static func makePrefixLengths(for characters: [Character]) -> [Int] {
            var prefixLengths = Array(repeating: 0, count: characters.count)
            var prefixLength = 0

            for index in 1..<characters.count {
                while prefixLength > 0, characters[index] != characters[prefixLength] {
                    prefixLength = prefixLengths[prefixLength - 1]
                }
                if characters[index] == characters[prefixLength] {
                    prefixLength += 1
                }
                prefixLengths[index] = prefixLength
            }
            return prefixLengths
        }
    }
}

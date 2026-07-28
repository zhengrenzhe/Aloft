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
    private var priorRevision = ""
    private var trailingCharacter = ""
    private var committedPresence: Set<String> = []
    private var speculativePresence: Set<String> = []
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

        let oldPresence = presence
        resetStreamingState()
        for character in lineRevision {
            advanceCommitted(character)
        }
        priorRevision = lineRevision
        return events(for: presence.subtracting(oldPresence), line: lineRevision, at: timestamp)
    }

    mutating func append(_ text: String, in lineRevision: String, at timestamp: Date) -> [KeywordMatchEvent] {
        guard !text.isEmpty else { return [] }

        let oldPresence = presence
        let candidateCharacters = Array(trailingCharacter + text)
        guard let latestCharacter = candidateCharacters.last else { return [] }

        for character in candidateCharacters.dropLast() {
            advanceCommitted(character)
        }
        trailingCharacter = String(latestCharacter)
        speculativePresence = Set(
            patterns.compactMap { $0.matchesTrailing(latestCharacter) ? $0.keyword : nil }
        )
        return events(for: presence.subtracting(oldPresence), line: lineRevision, at: timestamp)
    }

    mutating func finishRevision(in lineRevision: String, at timestamp: Date) -> [KeywordMatchEvent] {
        let oldPresence = presence
        if let character = trailingCharacter.first {
            advanceCommitted(character)
        }
        trailingCharacter = ""
        speculativePresence.removeAll()
        return events(for: presence.subtracting(oldPresence), line: lineRevision, at: timestamp)
    }

    mutating func reset() {
        resetRevision()
    }

    mutating func resetRevision() {
        priorRevision = ""
        resetStreamingState()
    }

    private var presence: Set<String> {
        committedPresence.union(speculativePresence)
    }

    private mutating func resetStreamingState() {
        trailingCharacter = ""
        committedPresence.removeAll()
        speculativePresence.removeAll()
        for index in patterns.indices {
            patterns[index].reset()
        }
    }

    private mutating func advanceCommitted(_ character: Character) {
        for index in patterns.indices where patterns[index].advanceCommitted(with: character) {
            committedPresence.insert(patterns[index].keyword)
        }
    }

    private func events(for addedKeywords: Set<String>, line: String, at timestamp: Date) -> [KeywordMatchEvent] {
        patterns.compactMap { pattern in
            guard addedKeywords.contains(pattern.keyword) else { return nil }
            return KeywordMatchEvent(
                entryID: entryID,
                keyword: pattern.keyword,
                line: line,
                timestamp: timestamp
            )
        }
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

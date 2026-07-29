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
    private var boundaryState = GraphemeBoundaryState()
    private var trailingCluster = GraphemeTokenBuilder()
    private var committedPresence: Set<String> = []
    private var speculativePresence: Set<String> = []
    private var patterns: [Pattern]

    init(entryID: UUID, keywords: [String]) {
        precondition(
            Unicode17Data.isValid,
            "Aloft's embedded Unicode 17.0.0 tables failed integrity validation"
        )
        self.entryID = entryID
        self.keywords = keywords
        var seenKeywords: Set<String> = []
        patterns = keywords.compactMap { keyword in
            guard !keyword.isEmpty, seenKeywords.insert(keyword).inserted else { return nil }
            return Pattern(keyword: keyword)
        }
    }

    mutating func matches(in lineRevision: String, at timestamp: Date) -> [KeywordMatchEvent] {
        guard lineRevision != priorRevision else { return [] }
        let oldPresence = presence
        resetStreamingState()
        for token in GraphemeToken.tokenize(lineRevision) { advanceCommitted(token) }
        priorRevision = lineRevision
        return events(for: presence.subtracting(oldPresence), line: lineRevision, at: timestamp)
    }

    mutating func append(_ text: String, in lineRevision: String, at timestamp: Date) -> [KeywordMatchEvent] {
        guard !text.isEmpty else { return [] }
        let oldPresence = presence

        for scalar in text.unicodeScalars {
            let startsNewCluster = boundaryState.startsNewCluster(before: scalar)
            if startsNewCluster, let token = trailingCluster.token() {
                advanceCommitted(token)
                trailingCluster.reset()
            }
            trailingCluster.append(scalar)
        }
        speculativePresence = speculativeMatches()
        return events(for: presence.subtracting(oldPresence), line: lineRevision, at: timestamp)
    }

    mutating func finishRevision(in lineRevision: String, at timestamp: Date) -> [KeywordMatchEvent] {
        let oldPresence = presence
        if let token = trailingCluster.token() {
            advanceCommitted(token)
        }
        trailingCluster.reset()
        speculativePresence.removeAll()
        return events(for: presence.subtracting(oldPresence), line: lineRevision, at: timestamp)
    }

    mutating func reset() { resetRevision() }

    mutating func resetRevision() {
        priorRevision = ""
        resetStreamingState()
    }

    private var presence: Set<String> { committedPresence.union(speculativePresence) }

    private mutating func resetStreamingState() {
        boundaryState.reset()
        trailingCluster.reset()
        committedPresence.removeAll()
        speculativePresence.removeAll()
        for index in patterns.indices { patterns[index].reset() }
    }

    private mutating func advanceCommitted(_ token: GraphemeToken) {
        for index in patterns.indices where patterns[index].advanceCommitted(with: token) {
            committedPresence.insert(patterns[index].keyword)
        }
    }

    private mutating func speculativeMatches() -> Set<String> {
        let candidates = patterns.filter { $0.tokens.last?.scalars.count == trailingCluster.scalarCount }
        guard !candidates.isEmpty, let token = trailingCluster.token() else { return [] }
        return candidates.reduce(into: Set<String>()) { matches, pattern in
            if pattern.matchesTrailing(token) { matches.insert(pattern.keyword) }
        }
    }

    private func events(for addedKeywords: Set<String>, line: String, at timestamp: Date) -> [KeywordMatchEvent] {
        patterns.compactMap { pattern in
            guard addedKeywords.contains(pattern.keyword) else { return nil }
            return KeywordMatchEvent(entryID: entryID, keyword: pattern.keyword, line: line, timestamp: timestamp)
        }
    }

    private struct Pattern: Sendable {
        let keyword: String
        let tokens: [GraphemeToken]
        let prefixLengths: [Int]
        var committedMatchLength = 0

        init(keyword: String) {
            self.keyword = keyword
            tokens = GraphemeToken.tokenize(keyword)
            prefixLengths = Self.makePrefixLengths(for: tokens)
        }

        mutating func advanceCommitted(with token: GraphemeToken) -> Bool {
            let result = advanced(from: committedMatchLength, with: token)
            committedMatchLength = result.length
            return result.matched
        }

        func matchesTrailing(_ token: GraphemeToken) -> Bool {
            guard committedMatchLength < tokens.count else { return false }
            return advanced(from: committedMatchLength, with: token).matched
        }

        mutating func reset() { committedMatchLength = 0 }

        private func advanced(from initialLength: Int, with token: GraphemeToken) -> (length: Int, matched: Bool) {
            var matchedLength = initialLength
            while matchedLength > 0, token != tokens[matchedLength] {
                matchedLength = prefixLengths[matchedLength - 1]
            }
            if token == tokens[matchedLength] { matchedLength += 1 }
            guard matchedLength == tokens.count else { return (matchedLength, false) }
            return (prefixLengths[matchedLength - 1], true)
        }

        private static func makePrefixLengths(for tokens: [GraphemeToken]) -> [Int] {
            var prefixLengths = Array(repeating: 0, count: tokens.count)
            var prefixLength = 0
            for index in 1..<tokens.count {
                while prefixLength > 0, tokens[index] != tokens[prefixLength] {
                    prefixLength = prefixLengths[prefixLength - 1]
                }
                if tokens[index] == tokens[prefixLength] { prefixLength += 1 }
                prefixLengths[index] = prefixLength
            }
            return prefixLengths
        }
    }
}

struct GraphemeToken: Equatable, Sendable {
    let scalars: [UInt32]

    init(scalars: [UInt32]) {
        self.scalars = scalars
    }

    static func tokenize(_ text: String) -> [GraphemeToken] {
        var state = GraphemeBoundaryState()
        var builder = GraphemeTokenBuilder()
        var tokens: [GraphemeToken] = []

        for scalar in text.unicodeScalars {
            if state.startsNewCluster(before: scalar), let token = builder.token() {
                tokens.append(token)
                builder.reset()
            }
            builder.append(scalar)
        }
        if let token = builder.token() { tokens.append(token) }
        return tokens
    }
}

private struct GraphemeTokenBuilder: Sendable {
    private var normalizer = Unicode17Normalizer.Builder()
    private var cachedToken: GraphemeToken?

    var scalarCount: Int { normalizer.count }

    mutating func append(_ scalar: Unicode.Scalar) {
        normalizer.append(scalar.value)
        cachedToken = nil
    }

    mutating func reset() {
        normalizer.reset()
        cachedToken = nil
    }

    mutating func token() -> GraphemeToken? {
        guard !normalizer.scalars.isEmpty else { return nil }
        if let cachedToken { return cachedToken }
        let token = GraphemeToken(scalars: normalizer.scalars)
        cachedToken = token
        return token
    }
}

struct GraphemeBoundaryState: Sendable {
    private var previousClass: Unicode17GraphemeBreakClass?
    private var regionalIndicatorCount = 0
    private var hasExtendedPictographicBeforeZWJ = false
    private var hasZWJAfterExtendedPictographic = false
    private var hasIndicConsonantBeforeLinker = false
    private var hasIndicLinkerAfterConsonant = false

    mutating func startsNewCluster(before scalar: Unicode.Scalar) -> Bool {
        startsNewCluster(before: scalar.value)
    }

    mutating func startsNewCluster(before scalar: UInt32) -> Bool {
        let currentClass = Unicode17Data.graphemeBreakClass(of: scalar)
        let currentIsExtendedPictographic = Unicode17Data.isExtendedPictographic(scalar)
        let currentIndicClass = Unicode17Data.indicConjunctBreakClass(of: scalar)
        guard let previousClass else {
            consume(
                currentClass,
                indicClass: currentIndicClass,
                isExtendedPictographic: currentIsExtendedPictographic,
                didBreak: true
            )
            return false
        }

        let didBreak: Bool
        if previousClass == .cr, currentClass == .lf {
            didBreak = false
        } else if isControl(previousClass) || isControl(currentClass) {
            didBreak = true
        } else if previousClass == .l, [.l, .v, .lv, .lvt].contains(currentClass) {
            didBreak = false
        } else if [.lv, .v].contains(previousClass), [.v, .t].contains(currentClass) {
            didBreak = false
        } else if [.lvt, .t].contains(previousClass), currentClass == .t {
            didBreak = false
        } else if [.extend, .zwj].contains(currentClass) || currentClass == .spacingMark {
            didBreak = false
        } else if previousClass == .prepend {
            didBreak = false
        } else if currentIndicClass == .consonant, hasIndicLinkerAfterConsonant {
            didBreak = false
        } else if currentIsExtendedPictographic, hasZWJAfterExtendedPictographic {
            didBreak = false
        } else if previousClass == .regionalIndicator,
                  currentClass == .regionalIndicator,
                  regionalIndicatorCount % 2 == 1 {
            didBreak = false
        } else {
            didBreak = true
        }
        consume(
            currentClass,
            indicClass: currentIndicClass,
            isExtendedPictographic: currentIsExtendedPictographic,
            didBreak: didBreak
        )
        return didBreak
    }

    mutating func reset() {
        previousClass = nil
        regionalIndicatorCount = 0
        hasExtendedPictographicBeforeZWJ = false
        hasZWJAfterExtendedPictographic = false
        hasIndicConsonantBeforeLinker = false
        hasIndicLinkerAfterConsonant = false
    }

    private mutating func consume(
        _ currentClass: Unicode17GraphemeBreakClass,
        indicClass: Unicode17IndicConjunctBreakClass,
        isExtendedPictographic: Bool,
        didBreak: Bool
    ) {
        if didBreak {
            regionalIndicatorCount = 0
            hasExtendedPictographicBeforeZWJ = false
            hasZWJAfterExtendedPictographic = false
            hasIndicConsonantBeforeLinker = false
            hasIndicLinkerAfterConsonant = false
        }
        if currentClass == .regionalIndicator {
            regionalIndicatorCount += 1
        } else {
            regionalIndicatorCount = 0
        }
        if isExtendedPictographic {
            hasExtendedPictographicBeforeZWJ = true
            hasZWJAfterExtendedPictographic = false
        } else if currentClass == .extend {
            // Extend before ZWJ preserves GB11 context; Extend after ZWJ invalidates it.
            hasZWJAfterExtendedPictographic = false
        } else if currentClass == .zwj {
            hasZWJAfterExtendedPictographic = hasExtendedPictographicBeforeZWJ
            hasExtendedPictographicBeforeZWJ = false
        } else {
            hasExtendedPictographicBeforeZWJ = false
            hasZWJAfterExtendedPictographic = false
        }
        if indicClass == .consonant {
            hasIndicConsonantBeforeLinker = true
            hasIndicLinkerAfterConsonant = false
        } else if indicClass == .linker {
            hasIndicLinkerAfterConsonant = hasIndicConsonantBeforeLinker
        } else if indicClass != .extend {
            hasIndicConsonantBeforeLinker = false
            hasIndicLinkerAfterConsonant = false
        }
        previousClass = currentClass
    }

    private func isControl(_ value: Unicode17GraphemeBreakClass) -> Bool {
        [.cr, .lf, .control].contains(value)
    }
}

enum Unicode17GraphemeSegmenter {
    static func boundaries(in scalars: [UInt32]) -> [Int] {
        var state = GraphemeBoundaryState()
        var result = [0]
        for (index, scalar) in scalars.enumerated() {
            if state.startsNewCluster(before: scalar) {
                result.append(index)
            }
        }
        if result.last != scalars.count {
            result.append(scalars.count)
        }
        return result
    }
}

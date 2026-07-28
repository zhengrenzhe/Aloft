import Foundation
import ICU

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
        for character in lineRevision {
            advanceCommitted(GraphemeToken(character))
        }
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
            tokens = keyword.map(GraphemeToken.init)
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

private struct GraphemeToken: Equatable, Sendable {
    let scalars: [UInt32]

    init(_ character: Character) {
        scalars = Array(String(character).decomposedStringWithCanonicalMapping.unicodeScalars).map(\.value)
    }

    init(scalars: [UInt32]) {
        self.scalars = scalars
    }
}

private struct GraphemeTokenBuilder: Sendable {
    private var scalars: [Unicode.Scalar] = []
    private var cachedToken: GraphemeToken?

    var scalarCount: Int { scalars.count }

    mutating func append(_ scalar: Unicode.Scalar) {
        scalars.append(contentsOf: String(scalar).decomposedStringWithCanonicalMapping.unicodeScalars)
        cachedToken = nil
    }

    mutating func reset() {
        scalars.removeAll(keepingCapacity: true)
        cachedToken = nil
    }

    mutating func token() -> GraphemeToken? {
        guard !scalars.isEmpty else { return nil }
        if let cachedToken { return cachedToken }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        let token = GraphemeToken(scalars: Array(String(view).decomposedStringWithCanonicalMapping.unicodeScalars).map(\.value))
        cachedToken = token
        return token
    }
}

private struct GraphemeBoundaryState: Sendable {
    private var previousClass: UGraphemeClusterBreak?
    private var regionalIndicatorCount = 0
    private var hasExtendedPictographicBeforeZWJ = false
    private var hasZWJAfterExtendedPictographic = false

    mutating func startsNewCluster(before scalar: Unicode.Scalar) -> Bool {
        let currentClass = graphemeClass(of: scalar)
        let currentIsExtendedPictographic = isExtendedPictographic(scalar)
        guard let previousClass else {
            consume(currentClass, isExtendedPictographic: currentIsExtendedPictographic, didBreak: true)
            return false
        }

        let didBreak: Bool
        if previousClass == U_GCB_CR, currentClass == U_GCB_LF {
            didBreak = false
        } else if isControl(previousClass) || isControl(currentClass) {
            didBreak = true
        } else if previousClass == U_GCB_L, [U_GCB_L, U_GCB_V, U_GCB_LV, U_GCB_LVT].contains(currentClass) {
            didBreak = false
        } else if [U_GCB_LV, U_GCB_V].contains(previousClass), [U_GCB_V, U_GCB_T].contains(currentClass) {
            didBreak = false
        } else if [U_GCB_LVT, U_GCB_T].contains(previousClass), currentClass == U_GCB_T {
            didBreak = false
        } else if [U_GCB_EXTEND, U_GCB_ZWJ].contains(currentClass) || currentClass == U_GCB_SPACING_MARK {
            didBreak = false
        } else if previousClass == U_GCB_PREPEND {
            didBreak = false
        } else if currentIsExtendedPictographic, hasZWJAfterExtendedPictographic {
            didBreak = false
        } else if previousClass == U_GCB_REGIONAL_INDICATOR, currentClass == U_GCB_REGIONAL_INDICATOR, regionalIndicatorCount % 2 == 1 {
            didBreak = false
        } else {
            didBreak = true
        }
        consume(currentClass, isExtendedPictographic: currentIsExtendedPictographic, didBreak: didBreak)
        return didBreak
    }

    mutating func reset() {
        previousClass = nil
        regionalIndicatorCount = 0
        hasExtendedPictographicBeforeZWJ = false
        hasZWJAfterExtendedPictographic = false
    }

    private mutating func consume(
        _ currentClass: UGraphemeClusterBreak,
        isExtendedPictographic: Bool,
        didBreak: Bool
    ) {
        if didBreak {
            regionalIndicatorCount = 0
            hasExtendedPictographicBeforeZWJ = false
            hasZWJAfterExtendedPictographic = false
        }
        if currentClass == U_GCB_REGIONAL_INDICATOR {
            regionalIndicatorCount += 1
        } else {
            regionalIndicatorCount = 0
        }
        if isExtendedPictographic {
            hasExtendedPictographicBeforeZWJ = true
            hasZWJAfterExtendedPictographic = false
        } else if currentClass == U_GCB_EXTEND {
            // Extend preserves the GB11 context.
        } else if currentClass == U_GCB_ZWJ {
            hasZWJAfterExtendedPictographic = hasExtendedPictographicBeforeZWJ
            hasExtendedPictographicBeforeZWJ = false
        } else {
            hasExtendedPictographicBeforeZWJ = false
            hasZWJAfterExtendedPictographic = false
        }
        previousClass = currentClass
    }

    private func graphemeClass(of scalar: Unicode.Scalar) -> UGraphemeClusterBreak {
        UGraphemeClusterBreak(rawValue: UInt32(u_getIntPropertyValue(Int32(scalar.value), UCHAR_GRAPHEME_CLUSTER_BREAK)))
    }

    private func isExtendedPictographic(_ scalar: Unicode.Scalar) -> Bool {
        u_hasBinaryProperty(Int32(scalar.value), UCHAR_EXTENDED_PICTOGRAPHIC) != 0
    }

    private func isControl(_ value: UGraphemeClusterBreak) -> Bool {
        [U_GCB_CR, U_GCB_LF, U_GCB_CONTROL].contains(value)
    }
}

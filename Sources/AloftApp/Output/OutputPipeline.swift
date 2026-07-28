import Foundation

struct OutputSnapshot: Equatable, Sendable {
    var committedLines: [String]
    var currentLine: String
    var latestMatch: KeywordMatchEvent?

    var displayText: String {
        (committedLines + (currentLine.isEmpty ? [] : [currentLine]))
            .joined(separator: "\n")
    }
}

struct OutputUpdate: Equatable, Sendable {
    let snapshot: OutputSnapshot
    let matches: [KeywordMatchEvent]
}

struct OutputPipeline {
    private let lineLimit: Int
    private var decoder = UTF8StreamDecoder()
    private var filter = ANSITextFilter()
    private var matcher: KeywordMatcher
    private var committedLines: [String] = []
    private var currentLine = ""
    private var latestMatch: KeywordMatchEvent?

    init(entryID: UUID, keywords: [String], lineLimit: Int) {
        self.lineLimit = max(0, lineLimit)
        matcher = KeywordMatcher(entryID: entryID, keywords: keywords)
    }

    mutating func consume(_ data: Data, at timestamp: Date) -> OutputUpdate {
        var events: [KeywordMatchEvent] = []
        let plainText = filter.consume(decoder.consume(data))

        for scalar in plainText.unicodeScalars {
            switch scalar.value {
            case 0x0D:
                evaluateCurrentLine(at: timestamp, events: &events)
                currentLine = ""
                _ = matcher.matches(in: currentLine, at: timestamp)
            case 0x0A:
                evaluateCurrentLine(at: timestamp, events: &events)
                commitCurrentLine()
                currentLine = ""
                _ = matcher.matches(in: currentLine, at: timestamp)
            default:
                currentLine.unicodeScalars.append(scalar)
                evaluateCurrentLine(at: timestamp, events: &events)
            }
        }

        return OutputUpdate(snapshot: snapshot, matches: events)
    }

    mutating func insertSessionSeparator(at timestamp: Date) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        appendCommittedLine("──── Session started \(formatter.string(from: timestamp)) ────")
    }

    mutating func clear() {
        decoder = UTF8StreamDecoder()
        filter = ANSITextFilter()
        matcher.reset()
        committedLines.removeAll()
        currentLine = ""
        latestMatch = nil
    }

    private var snapshot: OutputSnapshot {
        OutputSnapshot(
            committedLines: committedLines,
            currentLine: currentLine,
            latestMatch: latestMatch
        )
    }

    private mutating func evaluateCurrentLine(at timestamp: Date, events: inout [KeywordMatchEvent]) {
        let newEvents = matcher.matches(in: currentLine, at: timestamp)
        events.append(contentsOf: newEvents)
        latestMatch = newEvents.last ?? latestMatch
    }

    private mutating func commitCurrentLine() {
        appendCommittedLine(currentLine)
    }

    private mutating func appendCommittedLine(_ line: String) {
        guard lineLimit > 0 else { return }

        committedLines.append(line)
        let excessCount = committedLines.count - lineLimit
        if excessCount > 0 {
            committedLines.removeFirst(excessCount)
        }
    }
}

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
    private var pendingCarriageReturn = false

    init(entryID: UUID, keywords: [String], lineLimit: Int) {
        self.lineLimit = max(0, lineLimit)
        matcher = KeywordMatcher(entryID: entryID, keywords: keywords)
    }

    mutating func consume(_ data: Data, at timestamp: Date) -> OutputUpdate {
        var events: [KeywordMatchEvent] = []
        let plainText = filter.consume(decoder.consume(data))
        process(plainText, at: timestamp, events: &events)

        return OutputUpdate(snapshot: snapshot, matches: events)
    }

    @discardableResult
    mutating func insertSessionSeparator(at timestamp: Date) -> OutputUpdate {
        var events: [KeywordMatchEvent] = []
        process(filter.consume(decoder.finish()), at: timestamp, events: &events)
        if pendingCarriageReturn {
            pendingCarriageReturn = false
            record(matcher.finishRevision(in: currentLine, at: timestamp), in: &events)
            commitCurrentLine()
            resetCurrentLineRevision()
        }
        if !currentLine.isEmpty {
            record(matcher.finishRevision(in: currentLine, at: timestamp), in: &events)
            commitCurrentLine()
        }
        currentLine = ""
        matcher.resetRevision()
        filter = ANSITextFilter()

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        appendCommittedLine("──── Session started \(formatter.string(from: timestamp)) ────")
        return OutputUpdate(snapshot: snapshot, matches: events)
    }

    mutating func clear() {
        decoder = UTF8StreamDecoder()
        filter = ANSITextFilter()
        matcher.reset()
        committedLines.removeAll()
        currentLine = ""
        latestMatch = nil
        pendingCarriageReturn = false
    }

    private var snapshot: OutputSnapshot {
        OutputSnapshot(
            committedLines: committedLines,
            currentLine: currentLine,
            latestMatch: latestMatch
        )
    }

    private mutating func process(_ plainText: String, at timestamp: Date, events: inout [KeywordMatchEvent]) {
        var textRun = ""
        for scalar in plainText.unicodeScalars {
            if pendingCarriageReturn {
                flush(&textRun, at: timestamp, events: &events)
                if scalar.value == 0x0A {
                    pendingCarriageReturn = false
                    record(matcher.finishRevision(in: currentLine, at: timestamp), in: &events)
                    commitCurrentLine()
                    resetCurrentLineRevision()
                    continue
                }
                resolvePendingCarriageReturn(at: timestamp, events: &events)
            }

            switch scalar.value {
            case 0x0D:
                flush(&textRun, at: timestamp, events: &events)
                pendingCarriageReturn = true
            case 0x0A:
                flush(&textRun, at: timestamp, events: &events)
                record(matcher.finishRevision(in: currentLine, at: timestamp), in: &events)
                commitCurrentLine()
                resetCurrentLineRevision()
            default:
                textRun.unicodeScalars.append(scalar)
            }
        }
        flush(&textRun, at: timestamp, events: &events)
    }

    private mutating func flush(
        _ textRun: inout String,
        at timestamp: Date,
        events: inout [KeywordMatchEvent]
    ) {
        guard !textRun.isEmpty else { return }
        currentLine.append(contentsOf: textRun)
        record(matcher.append(textRun, in: currentLine, at: timestamp), in: &events)
        textRun = ""
    }

    private mutating func resolvePendingCarriageReturn(
        at timestamp: Date,
        events: inout [KeywordMatchEvent]
    ) {
        guard pendingCarriageReturn else { return }
        pendingCarriageReturn = false
        record(matcher.finishRevision(in: currentLine, at: timestamp), in: &events)
        resetCurrentLineRevision()
    }

    private mutating func record(_ newEvents: [KeywordMatchEvent], in events: inout [KeywordMatchEvent]) {
        events.append(contentsOf: newEvents)
        latestMatch = newEvents.last ?? latestMatch
    }

    private mutating func resetCurrentLineRevision() {
        currentLine = ""
        matcher.resetRevision()
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

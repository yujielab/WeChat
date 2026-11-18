import Foundation
import CoreGraphics
import CuvenCore

// MARK: - Word & CJK Phrase Tokenizer (`public/js/ui/text-pick.js` Parity)

public struct ExplainTextSegment: Identifiable, Equatable, Hashable, Sendable {
    public let id: Int
    public let text: String
    public let utf16Start: Int
    public let utf16End: Int
    public let isWordLike: Bool
    public let isCJK: Bool

    public init(
        id: Int,
        text: String,
        utf16Start: Int,
        utf16End: Int,
        isWordLike: Bool,
        isCJK: Bool
    ) {
        self.id = id
        self.text = text
        self.utf16Start = utf16Start
        self.utf16End = utf16End
        self.isWordLike = isWordLike
        self.isCJK = isCJK
    }
}

public enum WordExplainTokenizer: Sendable {
    /// Segments `text` into selectable units (`text-pick.js:13-32`):
    /// - Spaced alphabetic/numeric words stay intact as whole words.
    /// - Chinese/Japanese (`Han`, `Hiragana`, `Katakana`) characters segment individually so any multi-character phrase can be selected cleanly.
    /// - Whitespace and punctuation are preserved between words for faithful inline rendering.
    public static func segments(of text: String) -> [ExplainTextSegment] {
        guard !text.isEmpty else { return [] }
        var result: [ExplainTextSegment] = []
        var nextID = 0
        var utf16Cursor = 0

        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if isCJKCharacter(ch) {
                let s = String(ch)
                let len = s.utf16.count
                result.append(ExplainTextSegment(
                    id: nextID,
                    text: s,
                    utf16Start: utf16Cursor,
                    utf16End: utf16Cursor + len,
                    isWordLike: true,
                    isCJK: true
                ))
                nextID += 1
                utf16Cursor += len
                index = text.index(after: index)
            } else if isWordScalarCharacter(ch) {
                let wordStart = index
                var cursor = text.index(after: index)
                while cursor < text.endIndex {
                    let nextChar = text[cursor]
                    if isCJKCharacter(nextChar) { break }
                    if isWordScalarCharacter(nextChar) {
                        cursor = text.index(after: cursor)
                    } else if (nextChar == "'" || nextChar == "’" || nextChar == "-"),
                              let afterTick = text.index(cursor, offsetBy: 1, limitedBy: text.endIndex),
                              afterTick < text.endIndex,
                              isWordScalarCharacter(text[afterTick]) && !isCJKCharacter(text[afterTick])
                    {
                        cursor = text.index(after: cursor)
                    } else {
                        break
                    }
                }
                let word = String(text[wordStart..<cursor])
                let len = word.utf16.count
                result.append(ExplainTextSegment(
                    id: nextID,
                    text: word,
                    utf16Start: utf16Cursor,
                    utf16End: utf16Cursor + len,
                    isWordLike: true,
                    isCJK: false
                ))
                nextID += 1
                utf16Cursor += len
                index = cursor
            } else {
                // Group contiguous whitespace or single punctuation mark
                let start = index
                var cursor = text.index(after: index)
                if ch.isWhitespace {
                    while cursor < text.endIndex && text[cursor].isWhitespace {
                        cursor = text.index(after: cursor)
                    }
                }
                let token = String(text[start..<cursor])
                let len = token.utf16.count
                result.append(ExplainTextSegment(
                    id: nextID,
                    text: token,
                    utf16Start: utf16Cursor,
                    utf16End: utf16Cursor + len,
                    isWordLike: false,
                    isCJK: false
                ))
                nextID += 1
                utf16Cursor += len
                index = cursor
            }
        }
        return result
    }

    /// Maps `seedText` inside `contextText` to the covering `ClosedRange<Int>` of `ExplainTextSegment` indices.
    public static func initialSpan(
        for seedText: String,
        in contextText: String,
        segments: [ExplainTextSegment]
    ) -> ClosedRange<Int>? {
        guard !segments.isEmpty else { return nil }
        let trimmedSeed = seedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSeed.isEmpty,
           let range = contextText.range(of: trimmedSeed, options: [.caseInsensitive])
        {
            let startUTF16 = contextText.utf16.distance(from: contextText.utf16.startIndex, to: range.lowerBound.samePosition(in: contextText.utf16) ?? contextText.utf16.startIndex)
            let endUTF16 = contextText.utf16.distance(from: contextText.utf16.startIndex, to: range.upperBound.samePosition(in: contextText.utf16) ?? contextText.utf16.endIndex)
            let overlapping = segments.filter { seg in
                seg.utf16End > startUTF16 && seg.utf16Start < endUTF16
            }
            if let first = overlapping.first?.id, let last = overlapping.last?.id {
                return first...last
            }
        }
        if let firstWord = segments.first(where: \.isWordLike)?.id {
            return firstWord...firstWord
        }
        return 0...0
    }

    /// Extracts the cleaned phrase from `segments[span]`, stripping leading/trailing spaces & punctuation (`text-pick.js:95-100`).
    public static func pickedText(from segments: [ExplainTextSegment], span: ClosedRange<Int>?) -> String {
        guard let span, !segments.isEmpty else { return "" }
        let lo = max(0, min(segments.count - 1, span.lowerBound))
        let hi = max(lo, min(segments.count - 1, span.upperBound))
        let joined = segments[lo...hi].map(\.text).joined()
        let trimSet = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let tidied = joined.trimmingCharacters(in: trimSet)
        return tidied.isEmpty ? joined.trimmingCharacters(in: .whitespacesAndNewlines) : String(tidied.prefix(300))
    }

    /// Estimates the word or CJK token under a double-tap location `(normalizedX, normalizedY)` inside a message bubble.
    public static func wordNearNormalizedPoint(
        in text: String,
        normalizedX: CGFloat,
        normalizedY: CGFloat,
        highlightedKeywords: [String] = []
    ) -> String {
        let segs = segments(of: text)
        let wordSegs = segs.filter(\.isWordLike)
        guard !wordSegs.isEmpty else {
            return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
        }

        let clampedX = min(1.0, max(0.0, normalizedX))
        let clampedY = min(1.0, max(0.0, normalizedY))

        // Estimate multi-line wrapping (~32 UTF-16 code units per bubble line)
        let totalUTF16 = max(1, text.utf16.count)
        let estimatedLines = max(1, Int(ceil(Double(totalUTF16) / 32.0)))
        let lineIndex = min(estimatedLines - 1, Int(floor(Double(clampedY) * Double(estimatedLines))))
        let lineChars = Double(totalUTF16) / Double(estimatedLines)
        let targetUTF16 = Int((Double(lineIndex) + Double(clampedX)) * lineChars)

        // Snap to nearest word segment; if an AI-highlighted keyword overlaps that word, select the full keyword phrase!
        let nearest = wordSegs.min { lhs, rhs in
            let lMid = (lhs.utf16Start + lhs.utf16End) / 2
            let rMid = (rhs.utf16Start + rhs.utf16End) / 2
            return abs(lMid - targetUTF16) < abs(rMid - targetUTF16)
        } ?? wordSegs[0]

        for keyword in highlightedKeywords where !keyword.isEmpty {
            if let kwSpan = initialSpan(for: keyword, in: text, segments: segs),
               kwSpan.contains(nearest.id)
            {
                return keyword
            }
        }

        // For single CJK character double-tap, grab a 2-character compound if adjacent is also CJK
        if nearest.isCJK,
           nearest.id + 1 < segs.count,
           segs[nearest.id + 1].isCJK
        {
            return nearest.text + segs[nearest.id + 1].text
        }
        return nearest.text
    }

    private static func isCJKCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            let v = scalar.value
            return (0x3400...0x9FFF).contains(v)     // CJK Unified Ideographs + Ext A
                || (0xF900...0xFAFF).contains(v)     // CJK Compatibility Ideographs
                || (0x3040...0x309F).contains(v)     // Hiragana
                || (0x30A0...0x30FF).contains(v)     // Katakana
                || (0x20000...0x2FA1F).contains(v)   // CJK Extensions B–F
        }
    }

    private static func isWordScalarCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }
    }
}

// MARK: - Structured Answer & Citation Parser (`public/js/views/explain.js:23-68` Parity)

public enum ExplainInlineSpan: Equatable, Hashable, Sendable {
    case text(String)
    case bold(String)
    case citation(Int)
}

public enum ExplainAnswerBlock: Identifiable, Equatable, Sendable {
    case paragraph(id: Int, spans: [ExplainInlineSpan])
    case bulletList(id: Int, items: [[ExplainInlineSpan]])

    public var id: Int {
        switch self {
        case .paragraph(let id, _): return id
        case .bulletList(let id, _): return id
        }
    }
}

public enum ExplainAnswerParser: Sendable {
    /// Parses streaming AI markdown into structured paragraphs, bullet lists, `**bold**` runs, and `[n]` citations.
    public static func parseBlocks(from markdown: String) -> [ExplainAnswerBlock] {
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var blocks: [ExplainAnswerBlock] = []
        var currentBullets: [[ExplainInlineSpan]] = []
        var nextBlockID = 0

        func flushBulletsIfNeeded() {
            guard !currentBullets.isEmpty else { return }
            blocks.append(.bulletList(id: nextBlockID, items: currentBullets))
            nextBlockID += 1
            currentBullets.removeAll(keepingCapacity: true)
        }

        let lines = markdown.components(separatedBy: "\n")
        for rawLine in lines {
            let trimmedRight = rawLine.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            if let bulletBody = extractBulletBody(from: trimmedRight) {
                currentBullets.append(parseInlineSpans(in: bulletBody))
                continue
            }

            flushBulletsIfNeeded()
            let trimmed = trimmedRight.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let headingStripped = trimmed.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
            blocks.append(.paragraph(id: nextBlockID, spans: parseInlineSpans(in: headingStripped)))
            nextBlockID += 1
        }

        flushBulletsIfNeeded()
        return blocks
    }

    /// Parses `**bold**` and `[1]`..`[99]` citation badges within a single line (`explain.js:29-38`).
    public static func parseInlineSpans(in line: String) -> [ExplainInlineSpan] {
        guard !line.isEmpty else { return [] }
        let pattern = "\\*\\*([^*]+)\\*\\*|\\[(\\d{1,2})\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [.text(line)]
        }

        var spans: [ExplainInlineSpan] = []
        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        var lastUpper = line.startIndex

        for match in regex.matches(in: line, range: nsRange) {
            guard let fullRange = Range(match.range, in: line) else { continue }
            if fullRange.lowerBound > lastUpper {
                spans.append(.text(String(line[lastUpper..<fullRange.lowerBound])))
            }

            if let boldRange = Range(match.range(at: 1), in: line) {
                spans.append(.bold(String(line[boldRange])))
            } else if let citeRange = Range(match.range(at: 2), in: line),
                      let sourceNumber = Int(line[citeRange])
            {
                spans.append(.citation(sourceNumber))
            }
            lastUpper = fullRange.upperBound
        }

        if lastUpper < line.endIndex {
            spans.append(.text(String(line[lastUpper..<line.endIndex])))
        }
        return spans
    }

    /// Deterministic `0..<360` degree HSL hue for a source domain (`explain.js:61-67`).
    public static func siteHueDegrees(for site: String) -> Double {
        var hue: UInt32 = 0
        for scalar in site.unicodeScalars {
            hue = (hue &* 31 &+ scalar.value) % 360
        }
        return Double(hue)
    }

    /// Single uppercase monogram letter for a source domain (`explain.js:62`).
    public static func siteMonogram(for site: String) -> String {
        let stripped = site
            .replacingOccurrences(of: "^(?:m|en|www)\\.", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = stripped.first else { return "?" }
        return String(first).uppercased()
    }

    private static func extractBulletBody(from line: String) -> String? {
        let pattern = "^\\s*(?:[-*•]|\\d+[.)])\\s+(.*)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
              let bodyRange = Range(match.range(at: 1), in: line)
        else {
            return nil
        }
        return String(line[bodyRange])
    }
}

// MARK: - Streaming Explain Stage & Dual-Mode Stream Accumulator

public enum ExplainPipelineStage: String, CaseIterable, Identifiable, Sendable {
    case plan
    case search
    case compare
    case answer

    public var id: String { rawValue }

    /// Verbatim stage labels from `public/js/views/explain.js:11-16`.
    public var label: String {
        switch self {
        case .plan:    return "Understanding the question"
        case .search:  return "Searching the web"
        case .compare: return "Comparing sources"
        case .answer:  return "Writing the answer"
        }
    }
}

public enum ExplainStepStatus: Equatable, Sendable {
    case pending
    case active
    case completed
    case hidden
    case failed
}

/// Accumulates chunks from `store.streamExplain(...)` whether emitted as raw NDJSON event lines
/// (`{"type":"stage",...}`, `{"type":"delta",...}`, etc.) or pre-unwrapped plain-text delta chunks.
public struct ExplainStreamAccumulator: Sendable {
    public private(set) var stepStatuses: [ExplainPipelineStage: ExplainStepStatus] = [
        .plan: .active,
        .search: .pending,
        .compare: .pending,
        .answer: .pending
    ]
    public private(set) var queries: [String] = []
    public private(set) var sources: [CuvenExplainSource] = []
    public private(set) var noticeMessage: String?
    public private(set) var answerMarkdown: String = ""
    public private(set) var followUpQuestions: [String] = []
    public private(set) var isFinished: Bool = false
    public private(set) var streamErrorMessage: String?

    private var ndjsonParser = NDJSONLineParser()
    private var sawStructuredNDJSON = false

    public init() {}

    public mutating func ingestEvent(_ event: CuvenExplainStreamEvent) {
        sawStructuredNDJSON = true
        apply(event: event)
    }

    public mutating func ingestChunk(_ rawChunk: String) {
        guard !rawChunk.isEmpty else { return }

        let trimmed = rawChunk.trimmingCharacters(in: .whitespacesAndNewlines)

        // Fast path 1: Complete single JSON event object without trailing newline
        if !rawChunk.contains("\n"),
           trimmed.hasPrefix("{"),
           trimmed.hasSuffix("}"),
           let event = NDJSONLineParser.parseLine(trimmed)
        {
            sawStructuredNDJSON = true
            apply(event: event)
            return
        }

        // Fast path 2: Multi-line or incremental NDJSON stream
        if sawStructuredNDJSON || trimmed.hasPrefix("{\"type\"") || rawChunk.contains("\n{\"type\"") {
            let parsed = ndjsonParser.append(rawChunk)
            if !parsed.isEmpty {
                sawStructuredNDJSON = true
                for ev in parsed {
                    apply(event: ev)
                }
                return
            }
            if trimmed.hasPrefix("{") {
                // Buffering partial JSON line until '\n' arrives
                return
            }
        }

        // Fast path 3: Pre-unwrapped plain-text delta chunk from `AppStore.streamExplain`
        advanceToStage(.answer)
        answerMarkdown.append(rawChunk)
    }

    public mutating func finish(selectedText: String) {
        if sawStructuredNDJSON {
            for ev in ndjsonParser.flush() {
                apply(event: ev)
            }
        }
        for stage in ExplainPipelineStage.allCases where stepStatuses[stage] == .active {
            stepStatuses[stage] = .completed
        }
        if followUpQuestions.isEmpty && !answerMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            followUpQuestions = Self.defaultFollowUps(for: selectedText)
        }
        isFinished = true
    }

    public mutating func markFailed(_ message: String) {
        for stage in ExplainPipelineStage.allCases where stepStatuses[stage] == .active {
            stepStatuses[stage] = .failed
        }
        streamErrorMessage = message
        isFinished = true
    }

    public var collapsedSummaryLabel: String {
        if !sources.isEmpty {
            return "Searched the web · \(sources.count) source\(sources.count == 1 ? "" : "s")"
        } else if !queries.isEmpty {
            return "Answered without web sources"
        } else {
            return "Answered"
        }
    }

    private mutating func apply(event: CuvenExplainStreamEvent) {
        switch event {
        case .stage(let rawStage):
            if let stage = ExplainPipelineStage(rawValue: rawStage) {
                advanceToStage(stage)
            }
        case .queries(let list, _):
            queries = list
            advanceToStage(.search)
        case .sources(let list):
            sources = list
            advanceToStage(.compare)
        case .notice(let code):
            noticeMessage = (code == "no-search")
                ? "Not checked against the web: answered from what the model knows."
                : "Couldn't search the web just now, so this wasn't checked."
            stepStatuses[.search] = .hidden
            stepStatuses[.compare] = .hidden
        case .delta(let text):
            advanceToStage(.answer)
            answerMarkdown.append(text)
        case .followups(let questions):
            followUpQuestions = questions
        case .done:
            isFinished = true
        case .error(let msg):
            markFailed(msg)
        }
    }

    private mutating func advanceToStage(_ target: ExplainPipelineStage) {
        var reached = false
        for stage in ExplainPipelineStage.allCases {
            if stage == target {
                reached = true
                if stepStatuses[stage] != .hidden {
                    stepStatuses[stage] = .active
                }
            } else if !reached {
                if stepStatuses[stage] == .active || stepStatuses[stage] == .pending {
                    if stepStatuses[stage] != .hidden {
                        stepStatuses[stage] = .completed
                    }
                }
            }
        }
    }

    public static func defaultFollowUps(for phrase: String) -> [String] {
        let clean = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = clean.count > 28 ? String(clean.prefix(26)) + "…" : clean
        return [
            "How is “\(short)” used in everyday conversation?",
            "Give a quick example reply",
            "Any related nuances or origin?"
        ]
    }
}

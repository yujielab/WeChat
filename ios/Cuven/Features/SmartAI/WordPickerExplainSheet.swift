import SwiftUI
import CuvenCore

// MARK: - Word Picker & Live Streaming AI Explain Sheet (`PROJECT.md § 5.4`, `explain.js` + `explain-pick.js`)
//
// Apple HIG & Developer Documentation Grounding:
// - Apple HIG › Generative AI & Progressive Disclosure: Explicit stage progression ("Understanding the question" ->
//   "Searching the web" -> "Comparing sources" -> "Writing the answer"), inline [n] source citations, and clear
//   data-scope transparency ("Only these words and their message are sent.").
// - Apple HIG › Accessibility: >= 44pt interactive controls, Dynamic Type capped chrome (`CuvenFonts`),
//   Reduce Motion compliance (suppresses spinner rotation & flash animations), and VoiceOver labels.

public struct WordPickerExplainSheet: View {
    private let store: AppStore
    private let initialText: String
    private let roomContext: String
    private let onCloseCallback: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var segments: [ExplainTextSegment] = []
    @State private var anchorSegmentID: Int?
    @State private var selectedSpan: ClosedRange<Int>?
    @State private var isRangeExtendMode: Bool = false

    @State private var explainedPhrase: String = ""
    @State private var turns: [ExplainConversationTurn] = []
    @State private var followUpDraft: String = ""
    @State private var isStreaming: Bool = false
    @State private var flashedSourceKey: String?
    @State private var activeStreamTask: Task<Void, Never>?

    /// Canonical `PROJECT.md § 5.4` initializer.
    public init(store: AppStore, initialText: String, roomContext: String) {
        self.store = store
        self.initialText = initialText
        self.roomContext = roomContext
        self.onCloseCallback = nil
    }

    /// Extended initializer with explicit close callback when hosted inside `.cuvenAdaptiveModal`.
    public init(
        store: AppStore,
        initialText: String,
        roomContext: String,
        onClose: (() -> Void)?
    ) {
        self.store = store
        self.initialText = initialText
        self.roomContext = roomContext
        self.onCloseCallback = onClose
    }

    private var effectiveContext: String {
        let trimmedContext = roomContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedContext.isEmpty {
            return trimmedContext
        }
        return initialText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentPickedPhrase: String {
        let picked = WordExplainTokenizer.pickedText(from: segments, span: selectedSpan)
        if !picked.isEmpty {
            return picked
        }
        return initialText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasUnexplainedSelectionChange: Bool {
        let current = currentPickedPhrase
        return !current.isEmpty
            && current.caseInsensitiveCompare(explainedPhrase) != .orderedSame
    }

    private var latestFollowUpChips: [String] {
        guard !isStreaming, let last = turns.last else { return [] }
        return last.accumulator.followUpQuestions
    }

    public var body: some View {
        VStack(spacing: 0) {
            sheetHeaderBar

            Divider()
                .overlay(CuvenColors.hairlineSeparator)

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        interactiveWordPickerCard

                        ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                            if index > 0 {
                                Divider()
                                    .overlay(CuvenColors.hairlineSeparator)
                                    .padding(.vertical, 2)
                            }
                            turnSectionView(turn, scrollProxy: scrollProxy)
                                .id(turn.id)
                        }

                        if !latestFollowUpChips.isEmpty {
                            followUpChipsSection(scrollProxy: scrollProxy)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 18)
                }
            }

            Divider()
                .overlay(CuvenColors.hairlineSeparator)

            followUpInputFooter
        }
        .background(CuvenColors.cardSurface)
        .onAppear {
            initializeSegmentsAndStartInitialStream()
        }
        .onDisappear {
            activeStreamTask?.cancel()
            activeStreamTask = nil
        }
    }

    // MARK: - Top Sheet Chrome

    private var sheetHeaderBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CuvenColors.sidebarBlue)
                Text("Explain")
                    .font(CuvenFonts.cappedTitle(weight: .bold))
                    .foregroundStyle(CuvenColors.inkPrimary)
            }

            Spacer()

            Button {
                CuvenHaptics.lightTap()
                activeStreamTask?.cancel()
                if let onCloseCallback {
                    onCloseCallback()
                } else {
                    dismiss()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(CuvenColors.inkSecondary)
                    .frame(width: 32, height: 32)
                    .background(CuvenColors.fieldBackground, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Explain")
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Interactive Word & Phrase Picker (`explain-pick.js` + `text-pick.js`)

    private var interactiveWordPickerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text("Selected words")
                    .font(CuvenFonts.cappedCaption(weight: .semibold))
                    .foregroundStyle(CuvenColors.inkSecondary)

                Spacer()

                // Toggle between single-word tap and phrase-span extension (`dragEdge` / `pickSpan`)
                Button {
                    CuvenHaptics.selectionChanged()
                    isRangeExtendMode.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isRangeExtendMode ? "selection.pin.in.out" : "hand.tap")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(isRangeExtendMode ? "Extend phrase" : "Tap word")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(isRangeExtendMode ? CuvenColors.accessibleBlueText : CuvenColors.inkSecondary)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 32)
                    .background(
                        isRangeExtendMode
                            ? CuvenColors.sidebarBlue.opacity(0.14)
                            : CuvenColors.fieldBackground,
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityLabel(isRangeExtendMode ? "Phrase extension active, tap another word to select range" : "Single word tap mode, tap to enable phrase extension")
            }

            // Interactive token canvas where every word & CJK character can be tapped to refine the selection
            if !segments.isEmpty {
                ExplainTokenFlowLayout(horizontalSpacing: 0, verticalSpacing: 4) {
                    ForEach(segments) { segment in
                        let isSelected = selectedSpan?.contains(segment.id) ?? false
                        let isStartHandle = selectedSpan?.lowerBound == segment.id
                        let isEndHandle = selectedSpan?.upperBound == segment.id

                        if segment.isWordLike {
                            Button {
                                handleTapOnSegment(segment)
                            } label: {
                                HStack(spacing: 0) {
                                    if isStartHandle {
                                        selectionHandlePin(isStart: true)
                                    }
                                    Text(segment.text)
                                        .font(CuvenFonts.cappedSubheadline(weight: isSelected ? .semibold : .regular))
                                        .foregroundStyle(isSelected ? CuvenColors.accessibleBlueText : CuvenColors.inkPrimary)
                                        .padding(.horizontal, segment.isCJK ? 1.5 : 3)
                                        .padding(.vertical, 2.5)
                                    if isEndHandle {
                                        selectionHandlePin(isStart: false)
                                    }
                                }
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(isSelected ? CuvenColors.systemBlue.opacity(0.16) : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(segment.text)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        } else {
                            Text(segment.text)
                                .font(CuvenFonts.cappedSubheadline())
                                .foregroundStyle(CuvenColors.inkSecondary)
                                .padding(.vertical, 2.5)
                                .background(
                                    isSelected ? CuvenColors.systemBlue.opacity(0.10) : Color.clear
                                )
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(CuvenColors.fieldBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(CuvenColors.cardLine, lineWidth: 0.75)
                )
            }

            // Highlighted picked quote & Liquid Glass "Explain" confirmation capsule (`explain.css:25-49`)
            HStack(alignment: .center, spacing: 10) {
                Text(currentPickedPhrase)
                    .font(CuvenFonts.cappedHeadline(weight: .semibold))
                    .foregroundStyle(CuvenColors.inkPrimary)
                    .lineLimit(2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(CuvenColors.systemBlue.opacity(0.15))
                    )

                Spacer(minLength: 4)

                if hasUnexplainedSelectionChange {
                    Button {
                        CuvenHaptics.lightTap()
                        startExplainTurn(phrase: currentPickedPhrase, followUpQuestion: nil, replaceTurns: true)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Explain")
                                .font(CuvenFonts.cappedSubheadline(weight: .semibold))
                        }
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 38)
                    }
                    .buttonStyle(.cuvenGlassPill(mode: store.prefs.glassMode, cornerRadius: 22, triggersHaptic: false))
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
                    .accessibilityLabel("Search and explain \(currentPickedPhrase)")
                }
            }
        }
    }

    private func selectionHandlePin(isStart: Bool) -> some View {
        VStack(spacing: 0) {
            if isStart {
                Circle()
                    .fill(CuvenColors.sidebarBlue)
                    .frame(width: 6, height: 6)
            }
            Rectangle()
                .fill(CuvenColors.sidebarBlue)
                .frame(width: 2, height: 16)
            if !isStart {
                Circle()
                    .fill(CuvenColors.sidebarBlue)
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Turn Section (Live Steps + Streamed Answer + Citations + Source Cards)

    @ViewBuilder
    private func turnSectionView(_ turn: ExplainConversationTurn, scrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let q = turn.question, !q.isEmpty {
                Text(q)
                    .font(CuvenFonts.cappedHeadline(weight: .semibold))
                    .foregroundStyle(CuvenColors.inkPrimary)
            }

            // Stage pipeline (`xp-steps` -> folds into 1-line `xp-summary` on completion)
            if turn.accumulator.isFinished && turn.accumulator.streamErrorMessage == nil {
                HStack(spacing: 8) {
                    Image(systemName: turn.accumulator.sources.isEmpty ? "sparkles" : "globe")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CuvenColors.inkSecondary)
                        .frame(width: 20, height: 20)
                        .background(CuvenColors.fieldBackground, in: Circle())
                    Text(turn.accumulator.collapsedSummaryLabel)
                        .font(CuvenFonts.cappedSubheadline())
                        .foregroundStyle(CuvenColors.inkSecondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ExplainPipelineStage.allCases) { stage in
                        let status = turn.accumulator.stepStatuses[stage] ?? .pending
                        if status != .hidden {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 10) {
                                    stepIndicatorDot(for: status)
                                    Text(stage.label)
                                        .font(CuvenFonts.cappedSubheadline(weight: status == .active ? .medium : .regular))
                                        .foregroundStyle(stepForeground(for: status))
                                }

                                if stage == .search && !turn.accumulator.queries.isEmpty {
                                    ExplainTokenFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                                        ForEach(turn.accumulator.queries, id: \.self) { query in
                                            HStack(spacing: 4) {
                                                Image(systemName: "magnifyingglass")
                                                    .font(.system(size: 10.5, weight: .medium))
                                                Text(query)
                                                    .font(CuvenFonts.cappedCaption())
                                                    .lineLimit(1)
                                            }
                                            .foregroundStyle(CuvenColors.inkSecondary)
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 4)
                                            .background(CuvenColors.fieldBackground, in: Capsule())
                                        }
                                    }
                                    .padding(.leading, 28)
                                }
                            }
                        }
                    }
                }
            }

            // Streamed Answer (`xp-answer`)
            let blocks = ExplainAnswerParser.parseBlocks(from: turn.accumulator.answerMarkdown)
            if !blocks.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(blocks.enumerated()), id: \.element.id) { blockIdx, block in
                        let isLastBlock = (blockIdx == blocks.count - 1)
                        let showCaret = !turn.accumulator.isFinished && isLastBlock
                        switch block {
                        case .paragraph(_, let spans):
                            inlineSpansRow(
                                spans: spans,
                                turnID: turn.id,
                                showCaret: showCaret,
                                scrollProxy: scrollProxy
                            )
                        case .bulletList(_, let items):
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(Array(items.enumerated()), id: \.offset) { itemIdx, itemSpans in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text("•")
                                            .font(CuvenFonts.cappedBody(weight: .semibold))
                                            .foregroundStyle(CuvenColors.inkSecondary)
                                        inlineSpansRow(
                                            spans: itemSpans,
                                            turnID: turn.id,
                                            showCaret: showCaret && itemIdx == items.count - 1,
                                            scrollProxy: scrollProxy
                                        )
                                    }
                                }
                            }
                            .padding(.leading, 4)
                        }
                    }
                }
                .textSelection(.enabled)
            }

            // Notice (`no-search` / `search-failed`)
            if let notice = turn.accumulator.noticeMessage, !notice.isEmpty {
                Text(notice)
                    .font(CuvenFonts.cappedFootnote())
                    .foregroundStyle(CuvenColors.inkSecondary)
            }

            // Horizontal Snapping Source Cards (`xp-sources`)
            if !turn.accumulator.sources.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(turn.accumulator.sources) { source in
                            let cardKey = "\(turn.id)-source-\(source.id)"
                            sourceCardView(source: source, isFlashed: flashedSourceKey == cardKey)
                                .id(cardKey)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            // Error + Retry (`xp-error` / `xp-retry`)
            if let errMsg = turn.accumulator.streamErrorMessage {
                HStack(spacing: 10) {
                    Text(errMsg)
                        .font(CuvenFonts.cappedSubheadline())
                        .foregroundStyle(CuvenColors.dangerRedText)

                    Button {
                        CuvenHaptics.lightTap()
                        retryTurn(turn)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Try again")
                                .font(CuvenFonts.cappedSubheadline(weight: .medium))
                        }
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .background(CuvenColors.fieldBackground, in: Capsule())
                        .overlay(Capsule().strokeBorder(CuvenColors.cardLine, lineWidth: 0.75))
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                }
            }
        }
    }

    @ViewBuilder
    private func inlineSpansRow(
        spans: [ExplainInlineSpan],
        turnID: UUID,
        showCaret: Bool,
        scrollProxy: ScrollViewProxy
    ) -> some View {
        // Render rich text + interactive [n] citation pills seamlessly
        let hasCitations = spans.contains {
            if case .citation = $0 { return true }
            return false
        }

        if !hasCitations {
            let combined = spans.reduce(Text("")) { acc, span in
                switch span {
                case .text(let s):
                    return acc + Text(s).font(CuvenFonts.cappedBody()).foregroundColor(CuvenColors.inkPrimary)
                case .bold(let s):
                    return acc + Text(s).font(CuvenFonts.cappedBody(weight: .semibold)).foregroundColor(CuvenColors.inkPrimary)
                case .citation(let n):
                    return acc + Text(" [\(n)]").font(CuvenFonts.cappedCaption(weight: .semibold)).foregroundColor(CuvenColors.accessibleBlueText)
                }
            }
            let withCaret = showCaret
                ? (combined + Text(" ●").font(.system(size: 9)).foregroundColor(CuvenColors.inkTertiary))
                : combined
            withCaret
                .lineSpacing(3)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                let textRun = spans.reduce(Text("")) { acc, span in
                    switch span {
                    case .text(let s):
                        return acc + Text(s).font(CuvenFonts.cappedBody()).foregroundColor(CuvenColors.inkPrimary)
                    case .bold(let s):
                        return acc + Text(s).font(CuvenFonts.cappedBody(weight: .semibold)).foregroundColor(CuvenColors.inkPrimary)
                    case .citation(let n):
                        return acc + Text(" [\(n)]")
                            .font(.system(size: 12, weight: .bold).monospacedDigit())
                            .foregroundColor(CuvenColors.accessibleBlueText)
                    }
                }
                (showCaret
                    ? (textRun + Text(" ●").font(.system(size: 9)).foregroundColor(CuvenColors.inkTertiary))
                    : textRun)
                    .lineSpacing(3)

                // Interactive citation jump chips for accessibility & 1-tap source highlight
                let citedNumbers = Array(Set(spans.compactMap { span -> Int? in
                    if case .citation(let n) = span { return n }
                    return nil
                })).sorted()

                if !citedNumbers.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(citedNumbers, id: \.self) { num in
                            Button {
                                CuvenHaptics.selectionChanged()
                                let key = "\(turnID)-source-\(num)"
                                withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
                                    scrollProxy.scrollTo(key, anchor: .center)
                                    flashedSourceKey = key
                                }
                                Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(1100))
                                    if flashedSourceKey == key {
                                        flashedSourceKey = nil
                                    }
                                }
                            } label: {
                                Text("[\(num)]")
                                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(CuvenColors.accessibleBlueText)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(CuvenColors.sidebarBlue.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Jump to source \(num)")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func stepIndicatorDot(for status: ExplainStepStatus) -> some View {
        switch status {
        case .active:
            ProgressView()
                .controlSize(.mini)
                .tint(CuvenColors.systemBlue)
                .frame(width: 18, height: 18)
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(CuvenColors.onlineGreen, in: Circle())
        case .failed:
            Image(systemName: "exclamationmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(CuvenColors.dangerRed, in: Circle())
        case .pending, .hidden:
            Circle()
                .strokeBorder(CuvenColors.inkTertiary, lineWidth: 1.5)
                .frame(width: 18, height: 18)
        }
    }

    private func stepForeground(for status: ExplainStepStatus) -> Color {
        switch status {
        case .active: return CuvenColors.inkPrimary
        case .completed: return CuvenColors.inkSecondary
        case .failed: return CuvenColors.dangerRedText
        case .pending, .hidden: return CuvenColors.inkTertiary
        }
    }

    private func sourceCardView(source: CuvenExplainSource, isFlashed: Bool) -> some View {
        let hue = ExplainAnswerParser.siteHueDegrees(for: source.site) / 360.0
        let monogram = ExplainAnswerParser.siteMonogram(for: source.site)

        return Button {
            guard let url = URL(string: source.url),
                  let scheme = url.scheme?.lowercased(),
                  (scheme == "https" || scheme == "http")
            else { return }
            CuvenHaptics.lightTap()
            openURL(url)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(monogram)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Color(hue: hue, saturation: 0.55, brightness: 0.72), in: Circle())

                    Text(source.site.isEmpty ? "Source" : source.site)
                        .font(CuvenFonts.cappedCaption())
                        .foregroundStyle(CuvenColors.inkSecondary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text("\(source.id)")
                        .font(CuvenFonts.cappedCaption(weight: .semibold).monospacedDigit())
                        .foregroundStyle(CuvenColors.inkTertiary)
                }

                Text(source.title)
                    .font(CuvenFonts.cappedFootnote(weight: .medium))
                    .foregroundStyle(CuvenColors.inkPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: 204, alignment: .topLeading)
            .background(CuvenColors.fieldBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isFlashed ? CuvenColors.systemBlue : CuvenColors.hairlineSeparator,
                        lineWidth: isFlashed ? 2.0 : 0.75
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Source \(source.id): \(source.title), \(source.site)")
    }

    // MARK: - Follow-up Chips & Custom Question Input (`xp-follow` + `xp-ask`)

    private func followUpChipsSection(scrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask next")
                .font(CuvenFonts.cappedCaption(weight: .semibold))
                .foregroundStyle(CuvenColors.inkSecondary)

            ExplainTokenFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(latestFollowUpChips, id: \.self) { chipQuestion in
                    Button {
                        guard !isStreaming else { return }
                        CuvenHaptics.lightTap()
                        startExplainTurn(
                            phrase: explainedPhrase.isEmpty ? currentPickedPhrase : explainedPhrase,
                            followUpQuestion: chipQuestion,
                            replaceTurns: false,
                            scrollProxy: scrollProxy
                        )
                    } label: {
                        Text(chipQuestion)
                            .font(CuvenFonts.cappedSubheadline())
                            .foregroundStyle(CuvenColors.inkPrimary)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .frame(minHeight: 40)
                            .background(CuvenColors.fieldBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(CuvenColors.cardLine, lineWidth: 0.75)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isStreaming)
                }
            }
        }
    }

    private var followUpInputFooter: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("Ask a follow-up", text: $followUpDraft)
                    .font(CuvenFonts.cappedBody())
                    .foregroundStyle(CuvenColors.inkPrimary)
                    .submitLabel(.send)
                    .disabled(isStreaming)
                    .onSubmit {
                        submitFollowUpDraft()
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .background(CuvenColors.fieldBackground, in: Capsule())
                    .overlay(Capsule().strokeBorder(CuvenColors.cardLine, lineWidth: 0.75))

                let canAsk = !followUpDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isStreaming
                Button {
                    submitFollowUpDraft()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(canAsk ? CuvenColors.onCtaInk : CuvenColors.inkTertiary)
                        .frame(width: 44, height: 44)
                        .background(
                            canAsk ? CuvenColors.ctaInk : CuvenColors.fieldBackground,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canAsk)
                .accessibilityLabel("Ask follow-up question")
            }

            Text("Only these words and their message are sent.")
                .font(CuvenFonts.cappedCaption2())
                .foregroundStyle(CuvenColors.inkTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    // MARK: - Selection & Stream Coordination

    private func initializeSegmentsAndStartInitialStream() {
        guard segments.isEmpty else { return }
        let parsedSegments = WordExplainTokenizer.segments(of: effectiveContext)
        segments = parsedSegments
        let span = WordExplainTokenizer.initialSpan(
            for: initialText,
            in: effectiveContext,
            segments: parsedSegments
        )
        selectedSpan = span
        anchorSegmentID = span?.lowerBound

        let seed = WordExplainTokenizer.pickedText(from: parsedSegments, span: span)
        let targetPhrase = seed.isEmpty ? initialText.trimmingCharacters(in: .whitespacesAndNewlines) : seed
        if !targetPhrase.isEmpty {
            startExplainTurn(phrase: targetPhrase, followUpQuestion: nil, replaceTurns: true)
        }
    }

    private func handleTapOnSegment(_ segment: ExplainTextSegment) {
        CuvenHaptics.selectionChanged()
        withAnimation(CuvenSprings.adaptive(CuvenSprings.pressBounce, reduceMotion: reduceMotion)) {
            if isRangeExtendMode, let anchor = anchorSegmentID {
                let lo = min(anchor, segment.id)
                let hi = max(anchor, segment.id)
                selectedSpan = lo...hi
            } else {
                anchorSegmentID = segment.id
                selectedSpan = segment.id...segment.id
            }
        }
    }

    private func submitFollowUpDraft() {
        let trimmed = String(followUpDraft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        guard !trimmed.isEmpty, !isStreaming else { return }
        CuvenHaptics.lightTap()
        followUpDraft = ""
        startExplainTurn(
            phrase: explainedPhrase.isEmpty ? currentPickedPhrase : explainedPhrase,
            followUpQuestion: trimmed,
            replaceTurns: false
        )
    }

    private func retryTurn(_ failedTurn: ExplainConversationTurn) {
        turns.removeAll { $0.id == failedTurn.id }
        startExplainTurn(
            phrase: failedTurn.subjectText,
            followUpQuestion: failedTurn.question,
            replaceTurns: false
        )
    }

    private func startExplainTurn(
        phrase: String,
        followUpQuestion: String?,
        replaceTurns: Bool,
        scrollProxy: ScrollViewProxy? = nil
    ) {
        activeStreamTask?.cancel()
        let cleanPhrase = String(phrase.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        guard !cleanPhrase.isEmpty else { return }

        explainedPhrase = cleanPhrase
        if replaceTurns {
            turns.removeAll()
        }

        let priorHistory: [(question: String, answer: String)] = turns
            .filter { $0.accumulator.isFinished && !$0.accumulator.answerMarkdown.isEmpty }
            .suffix(3)
            .map { item in
                let q = item.question ?? "What does “\(item.subjectText)” mean here?"
                return (question: q, answer: item.accumulator.answerMarkdown)
            }

        let newTurn = ExplainConversationTurn(
            subjectText: cleanPhrase,
            question: followUpQuestion
        )
        turns.append(newTurn)
        let turnID = newTurn.id
        isStreaming = true

        if let scrollProxy {
            withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
                scrollProxy.scrollTo(turnID, anchor: .top)
            }
        }

        let contextSnapshot = String(effectiveContext.prefix(1200))
        activeStreamTask = Task { @MainActor in
            do {
                let eventStream = store.streamExplainEvents(
                    selectedText: cleanPhrase,
                    context: contextSnapshot,
                    followUp: followUpQuestion,
                    history: priorHistory
                )
                for try await event in eventStream {
                    if Task.isCancelled { return }
                    if let idx = turns.firstIndex(where: { $0.id == turnID }) {
                        turns[idx].accumulator.ingestEvent(event)
                    }
                }
                if Task.isCancelled { return }
                if let idx = turns.firstIndex(where: { $0.id == turnID }) {
                    turns[idx].accumulator.finish(selectedText: cleanPhrase)
                    if turns[idx].accumulator.answerMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && turns[idx].accumulator.streamErrorMessage == nil
                    {
                        turns[idx].accumulator.markFailed("Couldn't write the answer")
                    }
                }
            } catch {
                if Task.isCancelled { return }
                if let idx = turns.firstIndex(where: { $0.id == turnID }) {
                    turns[idx].accumulator.markFailed(error.localizedDescription)
                }
            }
            isStreaming = false
        }
    }
}

// MARK: - Supporting Models & Flow Layout

private struct ExplainConversationTurn: Identifiable, Sendable {
    let id: UUID = UUID()
    let subjectText: String
    let question: String?
    var accumulator: ExplainStreamAccumulator = ExplainStreamAccumulator()
}

/// Custom SwiftUI `Layout` wrapping word tokens, search query badges, and follow-up chips smoothly across lines.
struct ExplainTokenFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 340
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        var totalHeight: CGFloat = 0
        var widestRow: CGFloat = 0

        for (index, row) in rows.enumerated() {
            widestRow = max(widestRow, row.width)
            totalHeight += row.height
            if index > 0 {
                totalHeight += verticalSpacing
            }
        }
        return CGSize(width: proposal.width ?? widestRow, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let yOffset = (row.height - item.size.height) * 0.5
                item.subview.place(
                    at: CGPoint(x: x, y: y + yOffset),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private struct RowItem {
        let subview: LayoutSubview
        let size: CGSize
    }

    private struct Row {
        var items: [RowItem] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for subview in subviews {
            let measured = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            let itemWidth = min(measured.width, maxWidth)
            let itemSize = CGSize(width: itemWidth, height: measured.height)
            let projectedWidth = current.items.isEmpty ? itemSize.width : (current.width + horizontalSpacing + itemSize.width)

            if !current.items.isEmpty && projectedWidth > maxWidth {
                rows.append(current)
                current = Row(items: [RowItem(subview: subview, size: itemSize)], width: itemSize.width, height: itemSize.height)
            } else {
                current.items.append(RowItem(subview: subview, size: itemSize))
                current.width = projectedWidth
                current.height = max(current.height, itemSize.height)
            }
        }

        if !current.items.isEmpty {
            rows.append(current)
        }
        return rows
    }
}

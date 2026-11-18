import CuvenCore
import SwiftUI

/// AI Long-Term Memory Inspector & Interactive 24-Hour Routine Activity Chart Sheet.
///
/// Grounded in:
/// - Apple HIG: *Charting Data*, *Privacy*, & *Sheets* (clear user-owned transparency & destructive confirmation)
/// - Cuven Web Reference: `src/memory.js`, `src/routine.js`, `public/js/views/memory.js`, `public/js/views/memory-model.js`, `public/css/memory.css`
public struct AIMemoryAndRoutineSheet: View {
    private let store: AppStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var animateBarsIn: Bool = false
    @State private var inspectedHour: Int?
    @State private var showTurnOffLearningConfirm: Bool = false
    @State private var showClearAllMemoryConfirm: Bool = false
    @State private var isClearingMemory: Bool = false

    public init(store: AppStore) {
        self.store = store
    }

    private var routineMetrics: RoutineSummaryMetrics {
        RoutineAnalyticsModel.summarize(
            buckets: store.aiRoutineBuckets,
            routineLearningEnabled: store.prefs.routineLearningEnabled,
            use24HourTime: store.prefs.use24HourTime
        )
    }

    private var groupedMemories: [AIMemoryCategoryGroup] {
        RoutineAnalyticsModel.groupMemories(store.aiMemories)
    }

    public var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    privacyPreambleBanner

                    routineChartSection

                    memoryInspectorSection

                    learningControlsCard

                    if !store.aiMemories.isEmpty {
                        clearMemoryFooterButton
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 36)
            }
            .background(CuvenColors.paperBackground.ignoresSafeArea())
            .navigationTitle("AI Memory & Routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        CuvenHaptics.lightTap()
                        dismiss()
                    }
                    .font(CuvenFonts.cappedSubheadline(weight: .semibold))
                    .foregroundStyle(CuvenColors.sidebarBlue)
                    .accessibilityIdentifier("aiMemory.done")
                }
            }
        }
        .accessibilityIdentifier("aiMemory.root")
        .onAppear {
            if reduceMotion {
                animateBarsIn = true
            } else {
                withAnimation(CuvenSprings.sheetPresent) {
                    animateBarsIn = true
                }
            }
        }
        .alert("Turn off routine learning?", isPresented: $showTurnOffLearningConfirm) {
            Button("Turn Off Learning", role: .destructive) {
                Task { await setRoutineLearning(false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Routine and activity habits learned so far are paused and omitted from smart suggestions.")
        }
        .alert("Clear all AI memory?", isPresented: $showClearAllMemoryConfirm) {
            Button("Clear All Memory", role: .destructive) {
                Task {
                    isClearingMemory = true
                    await store.clearAIMemory()
                    CuvenHaptics.success()
                    isClearingMemory = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every recurring style word, phrase ending, and conversation summary remembered is permanently deleted.")
        }
    }

    // MARK: - Privacy Transparency Preamble

    private var privacyPreambleBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(CuvenColors.sidebarBlue)
                .frame(width: 34, height: 34)
                .background(CuvenColors.sidebarBlue.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text("Learned strictly from your own messages")
                    .font(CuvenFonts.cappedSubheadline(weight: .semibold))
                    .foregroundStyle(CuvenColors.inkPrimary)
                Text("Peers' live typing previews are never read. Conversation digests never cross chats, and routine counts fade with a 45-day half-life.")
                    .font(CuvenFonts.cappedFootnote())
                    .foregroundStyle(CuvenColors.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(CuvenColors.elevatedSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(CuvenColors.cardLine, lineWidth: 1)
        }
    }

    // MARK: - Interactive 24-Hour Activity & Routine Bar Chart (`memory.js:63-107`)

    private var routineChartSection: some View {
        let metrics = routineMetrics

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("24-Hour Activity & Routine")
                    .font(CuvenFonts.cappedSubheadline(weight: .semibold))
                    .foregroundStyle(CuvenColors.inkPrimary)

                Spacer()

                Text(metrics.confidenceLabel)
                    .font(CuvenFonts.cappedCaption())
                    .foregroundStyle(CuvenColors.inkSecondary)
            }
            .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 12) {
                // Peak / Quiet / Inspected hour header callout row
                HStack(spacing: 8) {
                    if let selectedHr = inspectedHour,
                       selectedHr >= 0, selectedHr < metrics.normalizedBuckets.count {
                        let scorePct = Int((metrics.normalizedBuckets[selectedHr].activityScore * 100).rounded())
                        let span = RoutineAnalyticsModel.formatHourSpan(
                            startHour: selectedHr,
                            endHour: (selectedHr + 1) % 24,
                            use24HourTime: store.prefs.use24HourTime
                        )
                        let roleBadge = metrics.isHourInPeak(selectedHr)
                            ? " · Peak"
                            : (metrics.isHourInQuiet(selectedHr) ? " · Quiet" : "")
                        Label("\(span) · \(scorePct)%\(roleBadge)", systemImage: "clock.badge.checkmark")
                            .font(CuvenFonts.cappedCaption(weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(CuvenColors.sidebarBlue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .cuvenLiquidGlass(mode: store.prefs.glassMode, cornerRadius: 14)
                    } else if let peakText = metrics.peakCalloutText {
                        Label(peakText, systemImage: "sun.max.fill")
                            .font(CuvenFonts.cappedCaption(weight: .semibold))
                            .foregroundStyle(CuvenColors.inkPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(CuvenColors.fieldBackground, in: Capsule())
                    } else {
                        Text(store.prefs.routineLearningEnabled
                             ? "Tap or drag across bars to inspect hourly activity"
                             : "Routine learning is off — nothing is recorded")
                            .font(CuvenFonts.cappedCaption())
                            .foregroundStyle(CuvenColors.inkSecondary)
                    }

                    Spacer(minLength: 0)

                    if inspectedHour != nil {
                        Button("Reset") {
                            inspectedHour = nil
                        }
                        .font(CuvenFonts.cappedCaption(weight: .medium))
                        .foregroundStyle(CuvenColors.inkSecondary)
                        .buttonStyle(.plain)
                    }
                }

                // 24-Bar Interactive SwiftUI Chart
                GeometryReader { geo in
                    let totalWidth = max(1, geo.size.width)
                    let barSpacing: CGFloat = 3
                    let barWidth = max(4, (totalWidth - barSpacing * 23) / 24.0)
                    let maxBarHeight: CGFloat = 88

                    HStack(alignment: .bottom, spacing: barSpacing) {
                        ForEach(metrics.normalizedBuckets) { bucket in
                            let ratio = animateBarsIn ? CGFloat(bucket.activityScore) : 0
                            let barHeight = max(4, ratio * maxBarHeight)
                            let isCurrent = bucket.hour == metrics.currentHour
                            let isInspected = bucket.hour == inspectedHour
                            let isPeak = metrics.isHourInPeak(bucket.hour)
                            let isQuiet = metrics.isHourInQuiet(bucket.hour)

                            VStack(spacing: 4) {
                                Spacer(minLength: 0)

                                if isPeak && inspectedHour == nil && bucket.hour == metrics.peakThreeHourWindow?.startHour {
                                    Circle()
                                        .fill(CuvenColors.warningAmber)
                                        .frame(width: 5, height: 5)
                                }

                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(barColor(
                                        isCurrent: isCurrent,
                                        isInspected: isInspected,
                                        isPeak: isPeak,
                                        isQuiet: isQuiet
                                    ))
                                    .frame(width: barWidth, height: barHeight)
                                    .scaleEffect(y: isInspected ? 1.06 : 1.0, anchor: .bottom)
                            }
                            .frame(width: barWidth, height: maxBarHeight + 10, alignment: .bottom)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                CuvenHaptics.selectionChanged()
                                inspectedHour = (inspectedHour == bucket.hour) ? nil : bucket.hour
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(
                                "\(RoutineAnalyticsModel.formatHour(bucket.hour, use24HourTime: store.prefs.use24HourTime)), \(Int((bucket.activityScore * 100).rounded())) percent activity"
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                let fraction = min(0.999, max(0.0, value.location.x / totalWidth))
                                let hr = Int(fraction * 24.0)
                                if inspectedHour != hr {
                                    CuvenHaptics.selectionChanged()
                                    inspectedHour = hr
                                }
                            }
                    )
                }
                .frame(height: 100)

                // 0 · 6 · 12 · 18 · 24 Monospaced Tabular Axis (`memory.css:89`)
                HStack {
                    ForEach([0, 6, 12, 18, 24], id: \.self) { tick in
                        Text("\(tick)")
                            .font(CuvenFonts.cappedCaption2(weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(CuvenColors.inkTertiary)
                        if tick != 24 {
                            Spacer()
                        }
                    }
                }

                // Legend + Quiet Hours Summary
                HStack(spacing: 14) {
                    legendDot(color: CuvenColors.sidebarBlue, label: "Now")
                    legendDot(color: CuvenColors.inkPrimary, label: "Peak 3h")
                    legendDot(color: CuvenColors.inkTertiary.opacity(0.45), label: "Quiet")
                    Spacer()
                    if let quietText = metrics.quietCalloutText {
                        Text(quietText)
                            .font(CuvenFonts.cappedCaption())
                            .foregroundStyle(CuvenColors.inkSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(16)
            .background(CuvenColors.elevatedSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(CuvenColors.cardLine, lineWidth: 1)
            }
            .accessibilityIdentifier("aiMemory.routineChart")
        }
    }

    private func barColor(
        isCurrent: Bool,
        isInspected: Bool,
        isPeak: Bool,
        isQuiet: Bool
    ) -> Color {
        if isInspected { return CuvenColors.sidebarBlue }
        if isCurrent { return CuvenColors.sidebarBlue.opacity(0.92) }
        if isPeak { return CuvenColors.inkPrimary.opacity(0.88) }
        if isQuiet { return CuvenColors.inkTertiary.opacity(0.42) }
        return CuvenColors.inkSecondary.opacity(0.74)
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(CuvenFonts.cappedCaption2())
                .foregroundStyle(CuvenColors.inkSecondary)
        }
    }

    // MARK: - AI Long-Term Memory Inspector (`Your words`, `Endings`, `Digests`)

    @ViewBuilder
    private var memoryInspectorSection: some View {
        if groupedMemories.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "bubble.left.and.sparkles.fill")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(CuvenColors.inkTertiary)
                Text("Nothing remembered yet")
                    .font(CuvenFonts.cappedHeadline(weight: .semibold))
                    .foregroundStyle(CuvenColors.inkPrimary)
                Text("As you send messages in Cuven, writing suggestions remember recurring words and per-chat digests.")
                    .font(CuvenFonts.cappedFootnote())
                    .foregroundStyle(CuvenColors.inkSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .background(CuvenColors.elevatedSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(CuvenColors.cardLine, lineWidth: 1)
            }
            .accessibilityIdentifier("aiMemory.emptyState")
        } else {
            ForEach(groupedMemories) { group in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(group.title)
                            .font(CuvenFonts.cappedSubheadline(weight: .semibold))
                            .foregroundStyle(CuvenColors.inkPrimary)
                        Spacer()
                        Text(group.subtitle)
                            .font(CuvenFonts.cappedCaption())
                            .foregroundStyle(CuvenColors.inkTertiary)
                    }
                    .padding(.horizontal, 4)

                    if group.rendersAsChips {
                        FlowChipLayout(spacing: 8) {
                            ForEach(group.items) { item in
                                let displayDetail = group.key == "endings" && !item.detail.hasPrefix("…")
                                    ? "…\(item.detail)"
                                    : item.detail
                                Text(displayDetail)
                                    .font(CuvenFonts.cappedSubheadline())
                                    .foregroundStyle(group.key == "endings" ? CuvenColors.inkSecondary : CuvenColors.inkPrimary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(CuvenColors.elevatedSurface, in: Capsule())
                                    .overlay {
                                        Capsule().strokeBorder(CuvenColors.cardLine, lineWidth: 1)
                                    }
                            }
                        }
                    } else {
                        VStack(spacing: 8) {
                            ForEach(group.items) { item in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(item.category.capitalized)
                                            .font(CuvenFonts.cappedCaption(weight: .semibold))
                                            .foregroundStyle(CuvenColors.sidebarBlue)
                                        Spacer()
                                        Text(RoutineAnalyticsModel.relativeTimeString(fromEpochMillis: item.updatedAt))
                                            .font(CuvenFonts.cappedCaption())
                                            .foregroundStyle(CuvenColors.inkTertiary)
                                    }
                                    Text(item.detail)
                                        .font(CuvenFonts.cappedSubheadline())
                                        .foregroundStyle(CuvenColors.inkPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(CuvenColors.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .strokeBorder(CuvenColors.cardLine, lineWidth: 1)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Routine Learning Switch & Clear Memory Footer

    private var learningControlsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Learn routine and habits")
                        .font(CuvenFonts.cappedBody(weight: .medium))
                        .foregroundStyle(CuvenColors.inkPrimary)
                    Text("Counts active quarter-hours (04:00 day boundary) — never message content.")
                        .font(CuvenFonts.cappedCaption())
                        .foregroundStyle(CuvenColors.inkSecondary)
                }

                Spacer()

                Toggle(
                    "Learn routine and habits",
                    isOn: Binding(
                        get: { store.prefs.routineLearningEnabled },
                        set: { next in
                            if !next {
                                showTurnOffLearningConfirm = true
                            } else {
                                Task { await setRoutineLearning(true) }
                            }
                        }
                    )
                )
                .labelsHidden()
                .tint(CuvenColors.onlineGreen)
                .accessibilityIdentifier("aiMemory.routineLearningToggle")
            }
            .padding(16)
            .background(CuvenColors.elevatedSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(CuvenColors.cardLine, lineWidth: 1)
            }
        }
    }

    private var clearMemoryFooterButton: some View {
        HStack {
            Spacer()
            Button(role: .destructive) {
                CuvenHaptics.rigidImpact()
                showClearAllMemoryConfirm = true
            } label: {
                HStack(spacing: 8) {
                    if isClearingMemory {
                        ProgressView()
                    } else {
                        Image(systemName: "trash")
                    }
                    Text("Clear all memory")
                        .font(CuvenFonts.cappedSubheadline(weight: .semibold))
                }
                .foregroundStyle(CuvenColors.dangerRedText)
                .padding(.horizontal, 22)
                .frame(minHeight: 44)
                .background(CuvenColors.elevatedSurface, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(CuvenColors.dangerRed.opacity(0.35), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(isClearingMemory)
            .accessibilityIdentifier("aiMemory.clearButton")
            Spacer()
        }
        .padding(.top, 6)
    }

    private func setRoutineLearning(_ enabled: Bool) async {
        var next = store.prefs
        next.routineLearningEnabled = enabled
        CuvenHaptics.selectionChanged()
        await store.updatePreferences(next)
    }
}

/// Adaptive wrapping layout for learned style word & phrase ending chips (`memory.css:44` `.memory-tags`).
private struct FlowChipLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
    }
}

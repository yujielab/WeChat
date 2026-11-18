import Foundation
import Observation
import SwiftUI
import CuvenCore

// MARK: - Apple HIG & Cuven Web Traceability
// - Apple HIG › Onboarding & Modality: Brief, optional, contextual tips shown in-place without blocking
//   primary messaging workflows; one-tap "Got it" dismissal and full replay via "Show tips again".
// - Apple HIG › Designing for iPhone Duo: Teaches 4-column edge-swipe strip navigation (with stationary Back),
//   Duo fold/unfold continuity (zero reflow at 525pt), right-rail Pages capsule, and double-tap AI Explain.
// - Cuven Web Reference: `public/js/ui/guides.js` (`welcome()`, `tip()`, `resetGuides()`) &
//   `public/css/guides.css` (`.gd-welcome`, `.gd-orb`, `.gd-dots`, `.gd-tip`, `.gd-tip-arrow`, `.gd-tip-ok`).

/// Canonical contextual onboarding tip topics for Cuven on iPhone & iPhone Duo.
public enum GuideTipTopic: String, CaseIterable, Identifiable, Sendable {
    case swipeBackStrip
    case duoFoldContinuity
    case doubleTapAIExplain
    case duoPagesCapsule

    public var id: String { rawValue }

    public var symbolName: String {
        switch self {
        case .swipeBackStrip:
            return "hand.draw.fill"
        case .duoFoldContinuity:
            return "rectangle.split.2x1.fill"
        case .doubleTapAIExplain:
            return "sparkles"
        case .duoPagesCapsule:
            return "square.grid.2x2.fill"
        }
    }

    public var title: String {
        switch self {
        case .swipeBackStrip:
            return "Swipe along the strip"
        case .duoFoldContinuity:
            return "Fold & unfold continuity"
        case .doubleTapAIExplain:
            return "Double-tap AI Explain"
        case .duoPagesCapsule:
            return "Your places, always in reach"
        }
    }

    public var message: String {
        switch self {
        case .swipeBackStrip:
            return "Drag from the 40pt leading edge to glide across Home, Messages, Chat, and Details — Back stays pinned under your thumb."
        case .duoFoldContinuity:
            return "Open or fold iPhone Duo mid-chat: your scroll anchor, live draft, and 525pt thread stay intact with zero reflow."
        case .doubleTapAIExplain:
            return "Double-tap or select any word in a message to stream instant context, translation, and AI explanations."
        case .duoPagesCapsule:
            return "On iPhone Duo, the bottom-right Pages capsule switches Chats, Moments, Memories, and Friends in one tap."
        }
    }
}

/// Persistent `UserDefaults`-backed store mirroring `guide:<id>` state in `public/js/ui/guides.js`.
@MainActor
@Observable
public final class CuvenGuidesStore {
    public static let shared = CuvenGuidesStore()

    private let defaults: UserDefaults
    private let welcomeKey = "guide:welcome"
    private var dismissedTipIDs: Set<String>
    public private(set) var hasCompletedWelcome: Bool

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hasCompletedWelcome = defaults.string(forKey: welcomeKey) == "1"
        var initialDismissed: Set<String> = []
        for topic in GuideTipTopic.allCases {
            if defaults.string(forKey: "guide:tip:\(topic.rawValue)") == "1" {
                initialDismissed.insert(topic.rawValue)
            }
        }
        self.dismissedTipIDs = initialDismissed
    }

    public func isTipDismissed(_ topic: GuideTipTopic) -> Bool {
        dismissedTipIDs.contains(topic.rawValue)
    }

    public func activeTips(hasRightSystemColumn: Bool) -> [GuideTipTopic] {
        GuideTipTopic.allCases.filter { topic in
            if topic == .duoPagesCapsule && !hasRightSystemColumn {
                return false
            }
            return !dismissedTipIDs.contains(topic.rawValue)
        }
    }

    public func dismissTip(_ topic: GuideTipTopic) {
        dismissedTipIDs.insert(topic.rawValue)
        defaults.set("1", forKey: "guide:tip:\(topic.rawValue)")
    }

    public func markWelcomeCompleted() {
        hasCompletedWelcome = true
        defaults.set("1", forKey: welcomeKey)
    }

    /// Resets welcome cards and all one-time contextual tips (`Settings › Show tips again`, `guides.js:179`).
    public func resetAllGuides() {
        hasCompletedWelcome = false
        dismissedTipIDs.removeAll()
        defaults.removeObject(forKey: welcomeKey)
        for topic in GuideTipTopic.allCases {
            defaults.removeObject(forKey: "guide:tip:\(topic.rawValue)")
        }
    }
}

/// Inline dismissible contextual tip card deck matching `.gd-tip` (`public/css/guides.css:43-68`).
///
/// Displays one contextual tip at a time (swipe-back strip navigation, Duo fold/unfold continuity,
/// double-tap AI Explain, and Duo Pages capsule) with spring dismissal, horizontal swipe navigation,
/// Reduce Transparency / Increase Contrast compliance, and a quiet "Show tips again" action when completed.
public struct ContextualGuideTipDeckView: View {
    private let metrics: DuoLayoutMetrics
    private let guidesStore: CuvenGuidesStore
    private let onOpenWelcomeTour: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @State private var currentIndex: Int = 0

    public init(
        metrics: DuoLayoutMetrics,
        guidesStore: CuvenGuidesStore = .shared,
        onOpenWelcomeTour: (() -> Void)? = nil
    ) {
        self.metrics = metrics
        self.guidesStore = guidesStore
        self.onOpenWelcomeTour = onOpenWelcomeTour
    }

    private var availableTips: [GuideTipTopic] {
        guidesStore.activeTips(hasRightSystemColumn: metrics.hasRightSystemColumn)
    }

    public var body: some View {
        let tips = availableTips
        if let activeTopic = resolvedActiveTopic(in: tips) {
            tipCard(for: activeTopic, allTips: tips)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .scale(scale: 0.95).combined(with: .opacity)
                )
        } else {
            completedFooterRow
                .transition(.opacity)
        }
    }

    private func resolvedActiveTopic(in tips: [GuideTipTopic]) -> GuideTipTopic? {
        guard !tips.isEmpty else { return nil }
        let clamped = min(max(0, currentIndex), tips.count - 1)
        return tips[clamped]
    }

    private func tipCard(for topic: GuideTipTopic, allTips: [GuideTipTopic]) -> some View {
        let clampedIndex = allTips.firstIndex(of: topic) ?? 0
        let isDark = colorScheme == .dark
        let solidOpacity: Double = (reduceTransparency || colorSchemeContrast == .increased) ? 1.0 : 0.94
        let cardFill = isDark
            ? Color(red: 0.13, green: 0.13, blue: 0.16).opacity(solidOpacity)
            : Color(red: 0.06, green: 0.06, blue: 0.08).opacity(solidOpacity)
        let borderOpacity: Double = colorSchemeContrast == .increased ? 0.34 : 0.15

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 11) {
                ZStack {
                    Circle()
                        .fill(CuvenColors.sidebarBlue.opacity(0.24))
                        .frame(width: 34, height: 34)

                    Image(systemName: topic.symbolName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(red: 0.38, green: 0.70, blue: 1.0))
                }
                .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text(topic.title)
                        .font(CuvenFonts.cappedSubheadline(weight: .bold))
                        .foregroundStyle(Color.white)

                    Text(topic.message)
                        .font(CuvenFonts.cappedFootnote())
                        .foregroundStyle(Color.white.opacity(0.86))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                if allTips.count > 1 {
                    HStack(spacing: 5) {
                        ForEach(Array(allTips.enumerated()), id: \.element.id) { idx, _ in
                            Capsule(style: .continuous)
                                .fill(idx == clampedIndex ? Color.white : Color.white.opacity(0.28))
                                .frame(width: idx == clampedIndex ? 16 : 6, height: 6)
                                .animation(
                                    reduceMotion ? nil : CuvenSprings.pressBounce,
                                    value: clampedIndex
                                )
                        }
                    }
                    .accessibilityHidden(true)
                }

                if let onOpenWelcomeTour {
                    Button {
                        CuvenHaptics.lightTap()
                        onOpenWelcomeTour()
                    } label: {
                        Text("Tour")
                            .font(CuvenFonts.cappedFootnote(weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.78))
                            .padding(.horizontal, 8)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sidebar.guideTourButton")
                    .accessibilityLabel("Welcome tour")
                }

                Spacer(minLength: 4)

                // `.gd-tip-ok` "Got it" capsule (`guides.css:62`, expanded to >= 44×44pt HIG hit target)
                Button {
                    CuvenHaptics.lightTap()
                    withAnimation(CuvenSprings.adaptive(CuvenSprings.pressBounce, reduceMotion: reduceMotion)) {
                        guidesStore.dismissTip(topic)
                        currentIndex = 0
                    }
                } label: {
                    Text("Got it")
                        .font(CuvenFonts.cappedFootnote(weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.18))
                        )
                        .frame(minWidth: 64, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar.guideDismissButton")
                .accessibilityLabel("Got it")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(borderOpacity), lineWidth: colorSchemeContrast == .increased ? 1.0 : 0.5)
                )
        )
        .shadow(color: .black.opacity(isDark ? 0.45 : 0.20), radius: 14, x: 0, y: 6)
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard allTips.count > 1 else { return }
                    if value.translation.width < -36 && clampedIndex < allTips.count - 1 {
                        CuvenHaptics.selectionChanged()
                        withAnimation(CuvenSprings.adaptive(CuvenSprings.pressBounce, reduceMotion: reduceMotion)) {
                            currentIndex = clampedIndex + 1
                        }
                    } else if value.translation.width > 36 && clampedIndex > 0 {
                        CuvenHaptics.selectionChanged()
                        withAnimation(CuvenSprings.adaptive(CuvenSprings.pressBounce, reduceMotion: reduceMotion)) {
                            currentIndex = clampedIndex - 1
                        }
                    }
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.guideTipCard")
    }

    private var completedFooterRow: some View {
        HStack(spacing: 10) {
            Button {
                CuvenHaptics.selectionChanged()
                withAnimation(CuvenSprings.adaptive(CuvenSprings.pressBounce, reduceMotion: reduceMotion)) {
                    guidesStore.resetAllGuides()
                    currentIndex = 0
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CuvenColors.sidebarBlue)
                    Text("Show tips again")
                        .font(CuvenFonts.cappedFootnote(weight: .medium))
                        .foregroundStyle(CuvenColors.inkSecondary)
                }
                .padding(.horizontal, 12)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar.replayTipsButton")

            Spacer(minLength: 0)

            if let onOpenWelcomeTour {
                Button {
                    CuvenHaptics.lightTap()
                    onOpenWelcomeTour()
                } label: {
                    Text("Welcome guide")
                        .font(CuvenFonts.cappedFootnote(weight: .medium))
                        .foregroundStyle(CuvenColors.sidebarBlue)
                        .padding(.horizontal, 10)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar.welcomeGuideButton")
            }
        }
    }
}

/// Directional callout tip bubble with pointer diamond (`.gd-tip` + `.gd-tip-arrow` in `guides.js:117-176`).
public struct ContextualAnchorTipBubbleView: View {
    public enum ArrowEdge: String, Sendable {
        case top
        case bottom
        case leading
        case trailing
    }

    private let topic: GuideTipTopic
    private let arrowEdge: ArrowEdge
    private let onDismiss: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    public init(
        topic: GuideTipTopic,
        arrowEdge: ArrowEdge = .top,
        onDismiss: @escaping () -> Void
    ) {
        self.topic = topic
        self.arrowEdge = arrowEdge
        self.onDismiss = onDismiss
    }

    public var body: some View {
        let cardFill = (colorScheme == .dark
            ? Color(red: 0.14, green: 0.14, blue: 0.17)
            : Color(red: 0.06, green: 0.06, blue: 0.08)
        ).opacity(reduceTransparency ? 1.0 : 0.94)

        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(topic.title)
                    .font(CuvenFonts.cappedSubheadline(weight: .bold))
                    .foregroundStyle(Color.white)

                Text(topic.message)
                    .font(CuvenFonts.cappedFootnote())
                    .foregroundStyle(Color.white.opacity(0.84))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                CuvenHaptics.lightTap()
                onDismiss()
            } label: {
                Text("Got it")
                    .font(CuvenFonts.cappedFootnote(weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.18))
                    )
                    .frame(minWidth: 56, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Got it")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: 300)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(cardFill)
        )
        .overlay(alignment: arrowAlignment) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(cardFill)
                .frame(width: 13, height: 13)
                .rotationEffect(.degrees(45))
                .offset(arrowOffset)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.32), radius: 14, x: 0, y: 6)
    }

    private var arrowAlignment: Alignment {
        switch arrowEdge {
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }

    private var arrowOffset: CGSize {
        switch arrowEdge {
        case .top: return CGSize(width: 0, height: -6)
        case .bottom: return CGSize(width: 0, height: 6)
        case .leading: return CGSize(width: -6, height: 0)
        case .trailing: return CGSize(width: 6, height: 0)
        }
    }
}

/// 4-step first-run Welcome card tour matching `welcome()` in `public/js/ui/guides.js:27-76` & `guides.css:5-40`.
public struct WelcomeGuideSheetView: View {
    public struct StepItem: Identifiable, Sendable {
        public let id: Int
        public let symbolName: String
        public let title: String
        public let body: String
    }

    public static let canonicalSteps: [StepItem] = [
        StepItem(
            id: 0,
            symbolName: "bubble.left.and.bubble.right.fill",
            title: "Your chats",
            body: "Chat, call and draw with friends. A note up top lasts a day."
        ),
        StepItem(
            id: 1,
            symbolName: "photo.on.rectangle.angled",
            title: "Moments",
            body: "Share photos and videos. You choose who sees them."
        ),
        StepItem(
            id: 2,
            symbolName: "rectangle.stack.fill",
            title: "Memories",
            body: "Every photo and video from your chats, organized by month."
        ),
        StepItem(
            id: 3,
            symbolName: "rectangle.split.2x1.fill",
            title: "Always in reach",
            body: "On iPhone Duo, the capsule at the bottom right switches pages effortlessly."
        )
    ]

    private let guidesStore: CuvenGuidesStore
    private let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stepIndex: Int = 0

    public init(
        guidesStore: CuvenGuidesStore = .shared,
        onDismiss: @escaping () -> Void
    ) {
        self.guidesStore = guidesStore
        self.onDismiss = onDismiss
    }

    private var activeStep: StepItem {
        Self.canonicalSteps[min(max(0, stepIndex), Self.canonicalSteps.count - 1)]
    }

    private var isLastStep: Bool {
        stepIndex >= Self.canonicalSteps.count - 1
    }

    public var body: some View {
        VStack(spacing: 18) {
            // Floating radial orb (`.gd-orb` in `guides.css:14-28`), driven by `TimelineView` so no
            // `.repeatForever` transaction ever leaks into sheet presentation.
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { context in
                let wave: Double = reduceMotion
                    ? 0.0
                    : 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 2.0 * .pi / 9.0)

                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.56, green: 0.83, blue: 0.85),
                                    Color(red: 0.18, green: 0.56, blue: 0.61)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay {
                            Circle()
                                .fill(
                                    RadialGradient(
                                        colors: [Color.white.opacity(0.85), .clear],
                                        center: .init(x: 0.30, y: 0.22),
                                        startRadius: 2,
                                        endRadius: 56
                                    )
                                )
                        }
                        .overlay {
                            Circle()
                                .strokeBorder(Color.white.opacity(0.62), lineWidth: 1)
                        }
                        .frame(width: 96, height: 96)
                        .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 10)

                    Image(systemName: activeStep.symbolName)
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(Color(red: 0.05, green: 0.08, blue: 0.10))
                        .contentTransition(.symbolEffect(.replace))
                }
                .offset(y: -5.0 * wave)
                .rotationEffect(.degrees(-2.5 * wave))
            }
            .frame(height: 116)
            .padding(.top, 12)

            VStack(spacing: 10) {
                Text(activeStep.title)
                    .font(CuvenFonts.clarinettaDisplay(size: 28, weight: .bold, italic: false))
                    .foregroundStyle(CuvenColors.inkPrimary)
                    .multilineTextAlignment(.center)

                Text(activeStep.body)
                    .font(CuvenFonts.cappedBody())
                    .foregroundStyle(CuvenColors.inkSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 310, minHeight: 54)
            }
            .id(activeStep.id)
            .transition(
                reduceMotion
                    ? .opacity
                    : .asymmetric(
                        insertion: .opacity.combined(with: .offset(x: 16)),
                        removal: .opacity.combined(with: .offset(x: -16))
                    )
            )

            // Expanding step pill dots (`.gd-dots` in `guides.css:31-33`)
            HStack(spacing: 6) {
                ForEach(Self.canonicalSteps) { step in
                    let isOn = step.id == stepIndex
                    Capsule(style: .continuous)
                        .fill(isOn ? CuvenColors.inkPrimary : CuvenColors.inkSecondary.opacity(0.28))
                        .frame(width: isOn ? 20 : 7, height: 7)
                        .animation(
                            reduceMotion ? nil : CuvenSprings.pressBounce,
                            value: stepIndex
                        )
                }
            }
            .padding(.vertical, 4)
            .accessibilityHidden(true)

            HStack(spacing: 10) {
                if !isLastStep {
                    Button {
                        finishWelcome()
                    } label: {
                        Text("Skip")
                            .font(CuvenFonts.cappedBody(weight: .semibold))
                            .foregroundStyle(CuvenColors.inkPrimary)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(CuvenColors.elevatedSurface)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("welcome.skipButton")
                }

                Button {
                    if isLastStep {
                        finishWelcome()
                    } else {
                        CuvenHaptics.selectionChanged()
                        withAnimation(CuvenSprings.adaptive(CuvenSprings.pressBounce, reduceMotion: reduceMotion)) {
                            stepIndex += 1
                        }
                    }
                } label: {
                    Text(isLastStep ? "Get started" : "Next")
                        .font(CuvenFonts.cappedBody(weight: .semibold))
                        .foregroundStyle(CuvenColors.onCtaInk)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(
                            Capsule(style: .continuous)
                                .fill(CuvenColors.ctaInk)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("welcome.nextButton")
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    if value.translation.width < -40 && stepIndex < Self.canonicalSteps.count - 1 {
                        CuvenHaptics.selectionChanged()
                        withAnimation(CuvenSprings.adaptive(CuvenSprings.pressBounce, reduceMotion: reduceMotion)) {
                            stepIndex += 1
                        }
                    } else if value.translation.width > 40 && stepIndex > 0 {
                        CuvenHaptics.selectionChanged()
                        withAnimation(CuvenSprings.adaptive(CuvenSprings.pressBounce, reduceMotion: reduceMotion)) {
                            stepIndex -= 1
                        }
                    }
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("welcome.sheet")
    }

    private func finishWelcome() {
        CuvenHaptics.success()
        guidesStore.markWelcomeCompleted()
        onDismiss()
    }
}

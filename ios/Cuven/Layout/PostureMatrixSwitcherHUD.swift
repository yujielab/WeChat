//
//  PostureMatrixSwitcherHUD.swift
//  Cuven
//
//  Apple HIG & iOS 27.1 SDK Grounding:
//  - Human Interface Guidelines › Designing for iPhone Duo › Device poses
//    (`iPhoneCompact`, `iPhoneSplit`, `duoClosed` 466×678, `duoHalfBook` 462|hinge|461,
//     `duoHalfLaptop` tabletop, `duoOpen` 951×669 + `Auto` hardware sensor mode)
//  - Human Interface Guidelines › Materials › Liquid Glass & Accessibility (`>= 44×44pt` hit targets,
//    `shell.postureSwitcher` identifier)
//

import CuvenCore
import SwiftUI

/// Sleek collapsible Liquid Glass posture switcher pill (`shell.postureSwitcher`) allowing one-tap
/// live animated morphing between `Auto (Hardware)` and all six `DuoPosture` states for live inspection
/// and automated XCUITest verification across standard iPhone and iPhone Duo Simulators.
public struct PostureMatrixSwitcherHUD: View {
    private let store: AppStore
    public let metrics: DuoLayoutMetrics

    @State private var isExpanded: Bool = false
    @State private var dragTranslation: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    @Namespace private var activePostureNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    public struct PostureOption: Identifiable, Equatable {
        public let id: String
        public let posture: DuoPosture?
        public let shortLabel: String
        public let subtitle: String
        public let symbol: String
    }

    public static let options: [PostureOption] = [
        PostureOption(
            id: "auto",
            posture: nil,
            shortLabel: "Auto",
            subtitle: "Hardware traits",
            symbol: "sparkles.tv"
        ),
        PostureOption(
            id: DuoPosture.iPhoneCompact.rawValue,
            posture: .iPhoneCompact,
            shortLabel: "iPhone",
            subtitle: "393×852 · 1-col",
            symbol: "iphone"
        ),
        PostureOption(
            id: DuoPosture.iPhoneSplit.rawValue,
            posture: .iPhoneSplit,
            shortLabel: "Split",
            subtitle: "956×440 · 2-col",
            symbol: "iphone.landscape"
        ),
        PostureOption(
            id: DuoPosture.duoClosed.rawValue,
            posture: .duoClosed,
            shortLabel: "Duo Closed",
            subtitle: "466×678 · Rail",
            symbol: "rectangle.portrait.righthalf.inset.filled"
        ),
        PostureOption(
            id: DuoPosture.duoHalfBook.rawValue,
            posture: .duoHalfBook,
            shortLabel: "Duo Book",
            subtitle: "462 | fold | 461",
            symbol: "book.pages"
        ),
        PostureOption(
            id: DuoPosture.duoHalfLaptop.rawValue,
            posture: .duoHalfLaptop,
            shortLabel: "Duo Laptop",
            subtitle: "Tabletop split",
            symbol: "laptopcomputer"
        ),
        PostureOption(
            id: DuoPosture.duoOpen.rawValue,
            posture: .duoOpen,
            shortLabel: "Duo Open",
            subtitle: "951×669 · 525pt",
            symbol: "rectangle.split.2x1"
        )
    ]

    public init(store: AppStore, metrics: DuoLayoutMetrics) {
        self.store = store
        self.metrics = metrics
    }

    private var currentOption: PostureOption {
        guard let override = store.postureOverride else {
            return Self.options[0]
        }
        return Self.options.first(where: { $0.posture == override }) ?? Self.options[0]
    }

    /// Anchors the collapsed pill clear of Duo's right-edge status/rail column, `thread.backButton`,
    /// and `thread.headerPill` so zero primary controls are obscured.
    private var trailingAnchorPadding: CGFloat {
        if metrics.hasRightSystemColumn {
            return max(metrics.safeAreaRight, metrics.posture == .duoClosed ? 91 : 84) + 10
        }
        return metrics.safeAreaRight + 12
    }

    private var topAnchorPadding: CGFloat {
        max(metrics.safeAreaTop, 10) + 4
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            collapsedTogglePill

            if isExpanded {
                expandedMatrixCard
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.92, anchor: .topTrailing))
                    )
            }
        }
        .padding(.top, topAnchorPadding)
        .padding(.trailing, trailingAnchorPadding)
        .offset(
            x: committedOffset.width + dragTranslation.width,
            y: committedOffset.height + dragTranslation.height
        )
        .frame(
            width: metrics.viewportSize.width,
            height: metrics.viewportSize.height,
            alignment: .topTrailing
        )
        .cuvenCappedDynamicType()
    }

    // MARK: - Collapsed `>= 44×44pt` Liquid Glass Pill (`shell.postureSwitcher`)

    private var collapsedTogglePill: some View {
        Button {
            CuvenHaptics.selectionChanged()
            withAnimation(CuvenSprings.adaptive(CuvenSprings.pressBounce, reduceMotion: reduceMotion)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: currentOption.symbol)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(store.postureOverride != nil ? CuvenColors.sidebarBlue : CuvenColors.inkPrimary)

                Text(store.postureOverride == nil ? activePostureBadgeLabel : currentOption.shortLabel)
                    .font(CuvenFonts.cappedCaption(weight: .semibold))
                    .foregroundStyle(CuvenColors.inkPrimary)
                    .lineLimit(1)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(CuvenColors.inkSecondary)
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Capsule())
            .cuvenLiquidGlass(
                mode: store.prefs.glassMode,
                cornerRadius: 22,
                interactiveBounce: true
            )
        }
        .buttonStyle(.plain)
        .simultaneousGesture(repositionDragGesture)
        .accessibilityIdentifier("shell.postureSwitcher")
        .accessibilityLabel("Posture switcher, current: \(currentOption.shortLabel)")
        .accessibilityValue(metrics.posture.rawValue)
        .accessibilityHint("Tap to switch between iPhone and iPhone Duo postures")
    }

    // MARK: - Expanded 7-Option Posture Matrix Card

    private var expandedMatrixCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("POSTURE MATRIX")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(CuvenColors.inkSecondary)

                Spacer(minLength: 8)

                Text("\(Int(metrics.viewportSize.width))×\(Int(metrics.viewportSize.height))")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(CuvenColors.inkTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)

            ForEach(Self.options) { option in
                postureRowButton(for: option)
            }
        }
        .padding(6)
        .frame(width: 214)
        .cuvenLiquidGlass(
            mode: store.prefs.glassMode,
            cornerRadius: 22,
            interactiveBounce: false
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shell.postureSwitcher.menu")
    }

    @ViewBuilder
    private func postureRowButton(for option: PostureOption) -> some View {
        let isSelected = (store.postureOverride == option.posture)

        Button {
            CuvenHaptics.selectionChanged()
            withAnimation(CuvenSprings.adaptive(CuvenSprings.railMorph, reduceMotion: reduceMotion)) {
                store.postureOverride = option.posture
                isExpanded = false
            }
        } label: {
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            colorScheme == .dark
                                ? Color.white.opacity(0.14)
                                : Color.black.opacity(0.07)
                        )
                        .matchedGeometryEffect(id: "posture.selectedRow", in: activePostureNamespace)
                }

                HStack(spacing: 10) {
                    Image(systemName: option.symbol)
                        .font(.system(size: 15, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? CuvenColors.sidebarBlue : CuvenColors.inkPrimary)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.shortLabel)
                            .font(CuvenFonts.cappedFootnote(weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(CuvenColors.inkPrimary)
                            .lineLimit(1)

                        Text(option.subtitle)
                            .font(.system(size: 10.5, weight: .regular).monospacedDigit())
                            .foregroundStyle(CuvenColors.inkSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(CuvenColors.sidebarBlue)
                    }
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("shell.postureSwitcher.\(option.id)")
        .accessibilityLabel("\(option.shortLabel), \(option.subtitle)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var activePostureBadgeLabel: String {
        switch metrics.posture {
        case .iPhoneCompact: return "Auto · iPhone"
        case .iPhoneSplit: return "Auto · Split"
        case .duoClosed: return "Auto · Closed"
        case .duoHalfBook: return "Auto · Book"
        case .duoHalfLaptop: return "Auto · Laptop"
        case .duoOpen: return "Auto · Open"
        }
    }

    private var repositionDragGesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                dragTranslation = value.translation
            }
            .onEnded { value in
                let maxDx = max(0, metrics.viewportSize.width * 0.45)
                let maxDy = max(0, metrics.viewportSize.height * 0.65)
                let nextX = min(60, max(-maxDx, committedOffset.width + value.translation.width))
                let nextY = min(maxDy, max(-8, committedOffset.height + value.translation.height))
                withAnimation(CuvenSprings.adaptive(CuvenSprings.pressBounce, reduceMotion: reduceMotion)) {
                    committedOffset = CGSize(width: nextX, height: nextY)
                    dragTranslation = .zero
                }
            }
    }
}

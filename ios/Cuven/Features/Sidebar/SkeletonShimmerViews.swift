import SwiftUI
import CuvenCore

// MARK: - Apple HIG & Cuven Web Traceability
// - Apple HIG › Loading & Motion: Structural placeholders match real row geometry so arrival never jumps;
//   driven by `TimelineView(.animation(..., paused: reduceMotion))` so every skeleton bar breathes in unison
//   without leaking `.repeatForever` transactions and pauses instantaneously under Reduce Motion.
// - Apple HIG › Accessibility: Skeleton placeholders are marked `.accessibilityHidden(true)` and inert
//   (`.allowsHitTesting(false)`) so VoiceOver never reads placeholder bars.
// - Cuven Web Reference: `public/js/ui/skeleton.js` (`WORDS = [3,5,4,7,2,6,4,8,3,5,6,4]`) &
//   `public/css/skeleton.css` (`1.15s` synchronized breath + `220ms` arrival cross-fade).

/// Seeded word-length generator mirroring `public/js/ui/skeleton.js:17-24` so skeleton bars never flicker.
public enum CuvenSkeletonMetrics: Sendable {
    private static let wordUnits: [CGFloat] = [3, 5, 4, 7, 2, 6, 4, 8, 3, 5, 6, 4]

    /// Computes a deterministic width in points for `wordCount` seeded words.
    public static func seededBarWidth(wordCount: Int = 3, seed: Int = 0, unitScale: CGFloat = 7.5) -> CGFloat {
        let clampedCount = max(1, wordCount)
        var units: CGFloat = 0
        for index in 0..<clampedCount {
            let slot = abs(seed + index * 5) % wordUnits.count
            units += wordUnits[slot]
        }
        let spaces = CGFloat(max(0, clampedCount - 1)) * 4.5
        return units * unitScale + spaces
    }
}

/// Phase-animated shimmer + synchronized `1.15s` breathing modifier for Cuven skeleton placeholders.
public struct CuvenSkeletonShimmerModifier: ViewModifier {
    private let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    public init(isActive: Bool = true) {
        self.isActive = isActive
    }

    public func body(content: Content) -> some View {
        if !isActive {
            content
        } else if reduceMotion {
            content
                .opacity(0.78)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion || !isActive)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                // Synchronized 1.15s half-period (`2.30s` full cycle) matching `skeleton.css:51` `sk-breathe`
                let breathWave = 0.5 + 0.5 * cos(t * .pi / 1.15)
                let breathOpacity = 0.52 + 0.44 * breathWave
                // Continuous 1.65s specular sweep (`-0.8 ... 1.25`)
                let sweepProgress = (t / 1.65).truncatingRemainder(dividingBy: 1.0)
                let shimmerPhase = CGFloat(-0.8 + 2.05 * sweepProgress)

                content
                    .opacity(breathOpacity)
                    .overlay {
                        GeometryReader { proxy in
                            let width = max(proxy.size.width, 1)
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(
                                        color: Color.white.opacity(colorScheme == .dark ? 0.10 : 0.42),
                                        location: 0.5
                                    ),
                                    .init(color: .clear, location: 1.0)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            .frame(width: width * 0.65)
                            .offset(x: shimmerPhase * width * 1.8)
                        }
                        .clipped()
                        .allowsHitTesting(false)
                    }
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
    }
}

extension View {
    /// Applies Cuven's silky phase-animated skeleton shimmer & breathing placeholder treatment.
    public func cuvenSkeletonShimmer(active: Bool = true) -> some View {
        modifier(CuvenSkeletonShimmerModifier(isActive: active))
    }
}

/// Seeded text-bar placeholder matching the exact height and rounded geometry of `.sk-t` (`skeleton.css:15-23`).
public struct SkeletonTextBarView: View {
    private let width: CGFloat
    private let height: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    public init(wordCount: Int = 3, seed: Int = 0, height: CGFloat = 13, unitScale: CGFloat = 7.5) {
        self.width = CuvenSkeletonMetrics.seededBarWidth(wordCount: wordCount, seed: seed, unitScale: unitScale)
        self.height = height
    }

    public init(width: CGFloat, height: CGFloat = 13) {
        self.width = width
        self.height = height
    }

    private var barFill: Color {
        CuvenColors.inkPrimary.opacity(colorScheme == .dark ? 0.13 : 0.09)
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: height * 0.45, style: .continuous)
            .fill(barFill)
            .frame(width: width, height: height)
    }
}

/// Column 0 (`SidebarColumnView`) structural skeleton placeholder displayed during `store.isBootstrapping`.
public struct SidebarSkeletonPlaceholderView: View {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    private var blockFill: Color {
        CuvenColors.inkPrimary.opacity(colorScheme == .dark ? 0.13 : 0.09)
    }

    private var softSurfaceFill: Color {
        CuvenColors.inkPrimary.opacity(colorScheme == .dark ? 0.06 : 0.04)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Profile header card placeholder (`.side-me` 74pt)
            HStack(spacing: 12) {
                Circle()
                    .fill(blockFill)
                    .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 7) {
                    SkeletonTextBarView(wordCount: 2, seed: 1, height: 15, unitScale: 9.0)
                    SkeletonTextBarView(wordCount: 4, seed: 3, height: 12, unitScale: 6.8)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(minHeight: 74)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(softSurfaceFill)
            )

            // 4 Chat Scope row placeholders (`All`, `Unread`, `Direct`, `Groups`)
            VStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { index in
                    skeletonScopeRow(seed: index * 2 + 1, showTrailingPill: index == 1)
                }
            }

            // 4 Social & Discover row placeholders (`Moments`, `Memories`, `Friends`, `Settings`)
            VStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { index in
                    skeletonScopeRow(seed: index * 3 + 6, showTrailingPill: false)
                }
            }
        }
        .cuvenSkeletonShimmer(active: true)
        .accessibilityIdentifier("sidebar.skeleton")
    }

    private func skeletonScopeRow(seed: Int, showTrailingPill: Bool) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(blockFill)
                .frame(width: 30, height: 30)

            SkeletonTextBarView(wordCount: 2, seed: seed, height: 14, unitScale: 8.5)

            Spacer(minLength: 8)

            if showTrailingPill {
                Capsule(style: .continuous)
                    .fill(blockFill)
                    .frame(width: 26, height: 20)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(seed == 1 ? softSurfaceFill : .clear)
        )
    }
}

/// Reusable 6-row conversation skeleton placeholder matching Cuven's `76pt` chat row rhythm.
public struct ChatListSkeletonPlaceholderView: View {
    private let rowCount: Int
    @Environment(\.colorScheme) private var colorScheme

    public init(rowCount: Int = 6) {
        self.rowCount = max(1, rowCount)
    }

    private var blockFill: Color {
        CuvenColors.inkPrimary.opacity(colorScheme == .dark ? 0.13 : 0.09)
    }

    public var body: some View {
        VStack(spacing: 6) {
            ForEach(0..<rowCount, id: \.self) { index in
                HStack(spacing: 12) {
                    Circle()
                        .fill(blockFill)
                        .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SkeletonTextBarView(wordCount: 2, seed: index + 2, height: 15, unitScale: 8.5)
                            Spacer(minLength: 12)
                            SkeletonTextBarView(width: 36, height: 11)
                        }
                        SkeletonTextBarView(wordCount: 4, seed: index * 3 + 1, height: 13, unitScale: 7.0)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 74)
            }
        }
        .cuvenSkeletonShimmer(active: true)
    }
}

//
//  ComposerGlowView.swift
//  Cuven
//
//  Apple HIG Grounding:
//  - Human Interface Guidelines › Materials & Motion (ambient non-distracting aura; static under Reduce Motion;
//    suppressed under Reduce Transparency so input contrast stays crisp)
//  - Cuven Web Parity: `public/css/thread.css:1167-1220` (`data-glow="ocean|dawn|aurora"`, 4 drifting radial
//    blobs on `17s / 23s / 29s / 19s` drift + `9s / 11s / 13s / 15s` breathe cycles, `1.25x` dark multiplier)
//

import CuvenCore
import SwiftUI

/// 60–120fps `TimelineView` + `Canvas` blurred ambient drifting aura behind the message composer.
///
/// Faithfully implements the 4-blob radial light field from `public/css/thread.css:1177-1219` across
/// `ocean` (default), `dawn`, `aurora`, and `off` styles, with optional live `audioLevel` (`0...1`) reactive bloom.
public struct ComposerGlowView: View {
    public let style: ComposerGlowStyle
    public let audioLevel: CGFloat
    public let isFocused: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Canonical `PROJECT.md § 5.3` initializer.
    public init(style: ComposerGlowStyle, audioLevel: CGFloat = 0) {
        self.style = style
        self.audioLevel = audioLevel
        self.isFocused = false
    }

    /// Extended initializer allowing the composer to brighten slightly while focused (`thread.css:1198`).
    public init(style: ComposerGlowStyle, audioLevel: CGFloat = 0, isFocused: Bool) {
        self.style = style
        self.audioLevel = audioLevel
        self.isFocused = isFocused
    }

    public var body: some View {
        if style == .off || reduceTransparency {
            EmptyView()
        } else {
            let currentStyle = style
            let currentAudio = audioLevel
            let isDark = (colorScheme == .dark)
            let isReducedMotion = reduceMotion

            TimelineView(.animation(paused: isReducedMotion)) { timeline in
                let elapsed = isReducedMotion ? 0.0 : timeline.date.timeIntervalSinceReferenceDate
                Canvas(rendersAsynchronously: true) { context, size in
                    Self.drawAmbientBlobs(
                        in: &context,
                        size: size,
                        time: elapsed,
                        style: currentStyle,
                        audioLevel: currentAudio,
                        isDark: isDark,
                        reduceMotion: isReducedMotion
                    )
                }
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black.opacity(0.45), location: 0.36),
                        .init(color: .black, location: 0.62),
                        .init(color: .black, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .opacity(isFocused ? 1.0 : 0.90)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: - 4-Blob Drift & Breathe Renderer (`thread.css:1177-1217`)

    private struct BlobSpec: Sendable {
        let color: Color
        let baseAlpha: Double
        let anchorX: CGFloat
        let widthFraction: CGFloat
        let bottomOffsetFraction: CGFloat
        let driftPeriod: Double
        let driftDelay: Double
        let breathePeriod: Double
        let breatheDelay: Double
        let startOffset: CGSize
        let midOffset: CGSize
        let endOffset: CGSize
        let startScale: CGFloat
        let midScale: CGFloat
        let endScale: CGFloat
    }

    nonisolated private static func drawAmbientBlobs(
        in context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        style: ComposerGlowStyle,
        audioLevel: CGFloat,
        isDark: Bool,
        reduceMotion: Bool
    ) {
        guard size.width > 1, size.height > 1 else { return }
        let specs = palette(for: style)
        guard !specs.isEmpty else { return }

        let darkMultiplier: Double = isDark ? 1.25 : 1.0
        let clampedAudio = Double(min(max(audioLevel, 0.0), 1.0))
        let audioLiftScale = CGFloat(1.0 + clampedAudio * 0.18)
        let audioAlphaBoost = 1.0 + clampedAudio * 0.28

        for spec in specs {
            // Alternating ping-pong cycle in [0, 1] matching CSS `ease-in-out infinite alternate`.
            let driftPhase = reduceMotion ? 0.35 : pingPongEaseInOut(time: time - spec.driftDelay, period: spec.driftPeriod)
            let breathePhase = reduceMotion ? 0.50 : pingPongEaseInOut(time: time - spec.breatheDelay, period: spec.breathePeriod)

            let offset = interpolateThreePointOffset(
                start: spec.startOffset,
                mid: spec.midOffset,
                end: spec.endOffset,
                t: CGFloat(driftPhase)
            )
            let scale = interpolateThreePointScalar(
                start: spec.startScale,
                mid: spec.midScale,
                end: spec.endScale,
                t: CGFloat(driftPhase)
            ) * audioLiftScale

            // `glow-breathe` oscillates between 0.45 * k and 0.95 * k (`thread.css:1217`).
            let breatheMultiplier = (0.45 + 0.50 * breathePhase) * darkMultiplier * audioAlphaBoost
            let effectiveAlpha = min(1.0, spec.baseAlpha * breatheMultiplier)

            let blobWidth = size.width * spec.widthFraction * scale
            let blobHeight = (blobWidth / 1.6) * (1.0 + CGFloat(clampedAudio) * 0.14)

            let baseX = size.width * spec.anchorX + blobWidth * offset.width
            let baseY = size.height * (1.0 - spec.bottomOffsetFraction) - blobHeight * 0.5 + blobHeight * offset.height - CGFloat(clampedAudio) * 14.0

            let rect = CGRect(x: baseX, y: baseY, width: blobWidth, height: blobHeight)
            let center = CGPoint(x: rect.midX, y: rect.midY)

            context.drawLayer { layer in
                // Transform unit circle into 1.6:1 horizontal ellipse (`aspect-ratio: 1.6`, `thread.css:1203`).
                layer.translateBy(x: center.x, y: center.y)
                layer.scaleBy(x: 1.0, y: blobHeight / max(blobWidth, 1.0))

                let ellipseRadius = blobWidth * 0.5
                let localRect = CGRect(
                    x: -ellipseRadius,
                    y: -ellipseRadius,
                    width: ellipseRadius * 2.0,
                    height: ellipseRadius * 2.0
                )
                let gradient = Gradient(stops: [
                    .init(color: spec.color.opacity(effectiveAlpha), location: 0.0),
                    .init(color: spec.color.opacity(effectiveAlpha * 0.52), location: 0.45),
                    .init(color: spec.color.opacity(0.0), location: 1.0)
                ])
                layer.fill(
                    Path(ellipseIn: localRect),
                    with: .radialGradient(
                        gradient,
                        center: .zero,
                        startRadius: 0,
                        endRadius: max(ellipseRadius, 1.0)
                    )
                )
            }
        }
    }

    /// Exact RGBA palettes and drift/breathe keyframes from `public/css/thread.css:1177-1216`.
    nonisolated private static func palette(for style: ComposerGlowStyle) -> [BlobSpec] {
        let colors: [(Color, Double)]
        switch style {
        case .off:
            return []
        case .ocean:
            // `--glow-a: rgb(38 128 140 / .7); --glow-b: rgb(96 176 198 / .6); --glow-c: rgb(150 210 212 / .5); --glow-d: rgb(70 120 200 / .45)`
            colors = [
                (Color(.sRGB, red: 38.0 / 255.0, green: 128.0 / 255.0, blue: 140.0 / 255.0, opacity: 1.0), 0.70),
                (Color(.sRGB, red: 96.0 / 255.0, green: 176.0 / 255.0, blue: 198.0 / 255.0, opacity: 1.0), 0.60),
                (Color(.sRGB, red: 150.0 / 255.0, green: 210.0 / 255.0, blue: 212.0 / 255.0, opacity: 1.0), 0.50),
                (Color(.sRGB, red: 70.0 / 255.0, green: 120.0 / 255.0, blue: 200.0 / 255.0, opacity: 1.0), 0.45)
            ]
        case .dawn:
            // `--glow-a: rgb(255 118 92 / .62); --glow-b: rgb(255 186 104 / .56); --glow-c: rgb(255 160 186 / .45); --glow-d: rgb(240 120 170 / .4)`
            colors = [
                (Color(.sRGB, red: 255.0 / 255.0, green: 118.0 / 255.0, blue: 92.0 / 255.0, opacity: 1.0), 0.62),
                (Color(.sRGB, red: 255.0 / 255.0, green: 186.0 / 255.0, blue: 104.0 / 255.0, opacity: 1.0), 0.56),
                (Color(.sRGB, red: 255.0 / 255.0, green: 160.0 / 255.0, blue: 186.0 / 255.0, opacity: 1.0), 0.45),
                (Color(.sRGB, red: 240.0 / 255.0, green: 120.0 / 255.0, blue: 170.0 / 255.0, opacity: 1.0), 0.40)
            ]
        case .aurora:
            // `--glow-a: rgb(102 90 255 / .58); --glow-b: rgb(56 206 168 / .55); --glow-c: rgb(184 110 255 / .42); --glow-d: rgb(60 170 255 / .4)`
            colors = [
                (Color(.sRGB, red: 102.0 / 255.0, green: 90.0 / 255.0, blue: 255.0 / 255.0, opacity: 1.0), 0.58),
                (Color(.sRGB, red: 56.0 / 255.0, green: 206.0 / 255.0, blue: 168.0 / 255.0, opacity: 1.0), 0.55),
                (Color(.sRGB, red: 184.0 / 255.0, green: 110.0 / 255.0, blue: 255.0 / 255.0, opacity: 1.0), 0.42),
                (Color(.sRGB, red: 60.0 / 255.0, green: 170.0 / 255.0, blue: 255.0 / 255.0, opacity: 1.0), 0.40)
            ]
        }

        return [
            BlobSpec(
                color: colors[0].0, baseAlpha: colors[0].1,
                anchorX: 0.42, widthFraction: 0.70, bottomOffsetFraction: -0.18,
                driftPeriod: 17.0, driftDelay: 0.0, breathePeriod: 9.0, breatheDelay: 0.0,
                startOffset: CGSize(width: -0.18, height: 0.06),
                midOffset: CGSize(width: 0.06, height: -0.10),
                endOffset: CGSize(width: -0.30, height: -0.02),
                startScale: 0.92, midScale: 1.08, endScale: 1.00
            ),
            BlobSpec(
                color: colors[1].0, baseAlpha: colors[1].1,
                anchorX: -0.12, widthFraction: 0.70, bottomOffsetFraction: -0.22,
                driftPeriod: 23.0, driftDelay: -6.0, breathePeriod: 11.0, breatheDelay: -3.0,
                startOffset: .zero,
                midOffset: CGSize(width: 0.34, height: -0.14),
                endOffset: CGSize(width: 0.58, height: 0.04),
                startScale: 1.00, midScale: 1.12, endScale: 0.94
            ),
            BlobSpec(
                color: colors[2].0, baseAlpha: colors[2].1,
                anchorX: 0.14, widthFraction: 0.90, bottomOffsetFraction: -0.28,
                driftPeriod: 29.0, driftDelay: -11.0, breathePeriod: 13.0, breatheDelay: -7.0,
                startOffset: CGSize(width: -0.10, height: 0.04),
                midOffset: CGSize(width: 0.12, height: -0.08),
                endOffset: CGSize(width: -0.04, height: -0.14),
                startScale: 1.04, midScale: 0.92, endScale: 1.10
            ),
            BlobSpec(
                color: colors[3].0, baseAlpha: colors[3].1,
                anchorX: 0.60, widthFraction: 0.55, bottomOffsetFraction: -0.14,
                driftPeriod: 19.0, driftDelay: -4.0, breathePeriod: 15.0, breatheDelay: -9.0,
                startOffset: .zero,
                midOffset: CGSize(width: -0.48, height: -0.12),
                endOffset: CGSize(width: -0.80, height: 0.02),
                startScale: 0.90, midScale: 1.10, endScale: 1.00
            )
        ]
    }

    nonisolated private static func pingPongEaseInOut(time: Double, period: Double) -> Double {
        guard period > 0 else { return 0.5 }
        let raw = ((time / period).truncatingRemainder(dividingBy: 2.0) + 2.0).truncatingRemainder(dividingBy: 2.0)
        let linear = raw <= 1.0 ? raw : (2.0 - raw)
        return 0.5 - 0.5 * cos(linear * .pi)
    }

    nonisolated private static func interpolateThreePointOffset(start: CGSize, mid: CGSize, end: CGSize, t: CGFloat) -> CGSize {
        if t <= 0.5 {
            let u = t * 2.0
            return CGSize(
                width: start.width + (mid.width - start.width) * u,
                height: start.height + (mid.height - start.height) * u
            )
        } else {
            let u = (t - 0.5) * 2.0
            return CGSize(
                width: mid.width + (end.width - mid.width) * u,
                height: mid.height + (end.height - mid.height) * u
            )
        }
    }

    nonisolated private static func interpolateThreePointScalar(start: CGFloat, mid: CGFloat, end: CGFloat, t: CGFloat) -> CGFloat {
        if t <= 0.5 {
            return start + (mid - start) * (t * 2.0)
        } else {
            return mid + (end - mid) * ((t - 0.5) * 2.0)
        }
    }
}

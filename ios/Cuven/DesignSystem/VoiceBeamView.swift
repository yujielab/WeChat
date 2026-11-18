//
//  VoiceBeamView.swift
//  Cuven
//
//  Apple HIG Grounding:
//  - Human Interface Guidelines › Motion & Feedback (immediate voice-reactive energy envelope, calm floor under Reduce Motion)
//  - Cuven Web Parity: `public/js/ui/voice-beam.js:1-305` (7-lobe additive bloom + bright edge core band +
//    travelling processing beam across 8 palettes) & `public/js/ui/voice-level.js:14-26` (`shapeLevel` gate + attack/release)
//

import SwiftUI

/// Color palettes matching `PALETTES` in `public/js/ui/voice-beam.js:25-34`.
public enum VoiceBeamPalette: String, CaseIterable, Sendable {
    case colorful
    case mono
    case ocean
    case sunset
    case forest
    case candy
    case ice
    case gold

    public var hexStops: [String] {
        switch self {
        case .colorful: return ["#5B8CFF", "#8A5BFF", "#D14BFF", "#FF4BB0", "#FF7A45", "#FFD24B", "#4BFFD2"]
        case .mono:     return ["#FFFFFF", "#DFE7FF", "#BCD0FF", "#9FBCFF", "#CDD9FF", "#EAF0FF", "#FFFFFF"]
        case .ocean:    return ["#2BD2FF", "#2B9BFF", "#2B6BFF", "#51E0C6", "#2BD2FF", "#6FB8FF", "#9FF0FF"]
        case .sunset:   return ["#FF5E62", "#FF9966", "#FFC371", "#FF6B9D", "#FF5E62", "#FFD16B", "#FF8E53"]
        case .forest:   return ["#5DDF7A", "#39C16A", "#2EA36B", "#7EF0A0", "#39C16A", "#BDF0A0", "#2EA36B"]
        case .candy:    return ["#FF8FE0", "#FF6FD8", "#C08CFF", "#8CB8FF", "#FF8FE0", "#FFC0EC", "#B8A0FF"]
        case .ice:      return ["#AEE9FF", "#8FD6FF", "#BCD0FF", "#DFF2FF", "#AEE9FF", "#E8F6FF", "#9FE0FF"]
        case .gold:     return ["#FFD76B", "#FFC24B", "#FFAC3B", "#FFE29A", "#FFD76B", "#FFF0C0", "#FFB85C"]
        }
    }
}

/// Pure signal envelope shaper matching `shapeLevel` in `public/js/ui/voice-level.js:14-26`.
public enum VoiceBeamLevelShaper: Sendable {
    public static func shapeLevel(
        raw: CGFloat,
        previous: CGFloat = 0,
        dt: TimeInterval = 0.016,
        sensitivity: CGFloat = 1.6,
        threshold: CGFloat = 0.04,
        attack: CGFloat = 0.6,
        release: CGFloat = 0.12
    ) -> CGFloat {
        let safeRaw = raw.isFinite ? min(max(raw, 0.0), 4.0) : 0.0
        var v = safeRaw * sensitivity
        if v <= threshold {
            v = 0.0
        } else {
            v = (v - threshold) / max(1.0 - threshold, 0.001)
        }
        v = min(max(v, 0.0), 1.0)

        let rising = v > previous
        let clampedDt = CGFloat(min(max(dt, 0.0), 0.1))
        let rate = rising ? attack : release
        let coef = 1.0 - exp(-clampedDt * rate * 12.0)
        return min(max(previous + (v - previous) * coef, 0.0), 1.0)
    }
}

/// Microphone RMS-reactive multi-lobe & multi-wave bloom rendered at 60–120fps during Whisper voice dictation.
///
/// Matches `public/js/ui/voice-beam.js:176-250` while adding crisp harmonic ribbon waves along the active edge.
public struct VoiceBeamView: View {
    public let rmsLevel: CGFloat
    public let isRecording: Bool
    public let isProcessing: Bool
    public let palette: VoiceBeamPalette

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Canonical `PROJECT.md § 5.3` initializer.
    public init(rmsLevel: CGFloat, isRecording: Bool) {
        self.rmsLevel = rmsLevel
        self.isRecording = isRecording
        self.isProcessing = false
        self.palette = .colorful
    }

    /// Extended initializer supporting Whisper transcription `isProcessing` travelling beam and 8 palette presets.
    public init(
        rmsLevel: CGFloat,
        isRecording: Bool,
        isProcessing: Bool,
        palette: VoiceBeamPalette = .colorful
    ) {
        self.rmsLevel = rmsLevel
        self.isRecording = isRecording
        self.isProcessing = isProcessing
        self.palette = palette
    }

    private var isActive: Bool {
        isRecording || isProcessing
    }

    public var body: some View {
        let active = isActive
        let currentRMS = rmsLevel
        let processing = isProcessing
        let isDark = (colorScheme == .dark)
        let isReducedMotion = reduceMotion
        let paletteColors = palette.hexStops.map { CuvenColors.color(hex: $0) }

        TimelineView(.animation(paused: !active)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            Canvas(rendersAsynchronously: true) { context, size in
                guard active, size.width > 1, size.height > 1 else { return }
                Self.drawVoiceBeam(
                    in: &context,
                    size: size,
                    time: now,
                    rmsLevel: currentRMS,
                    isProcessing: processing,
                    isDark: isDark,
                    reduceMotion: isReducedMotion,
                    colors: paletteColors
                )
            }
        }
        .opacity(active ? 1.0 : 0.0)
        .animation(isReducedMotion ? CuvenSprings.reducedMotionFade : CuvenSprings.smooth, value: active)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Multi-Lobe + Harmonic Multi-Wave Canvas Renderer (`voice-beam.js:176-250`)

    nonisolated private static func drawVoiceBeam(
        in context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        rmsLevel: CGFloat,
        isProcessing: Bool,
        isDark: Bool,
        reduceMotion: Bool,
        colors: [Color]
    ) {
        let shaped = VoiceBeamLevelShaper.shapeLevel(raw: rmsLevel, previous: rmsLevel * 0.82, dt: 1.0 / 60.0)
        let lobeCount = colors.count
        guard lobeCount > 0 else { return }

        let flow: Double = reduceMotion ? 0.0 : 1.0
        let spread: CGFloat = 0.76
        let bend: CGFloat = 0.30
        let idleFloor: CGFloat = 0.06
        let edgeY = size.height
        let maxReach = size.height * 0.94

        // When transcribing (`isProcessing`), gather lobes toward a travelling focal beam (`voice-beam.js:193`).
        let travelPhase = (time * 0.6).truncatingRemainder(dividingBy: 1.0)
        let beamX: CGFloat = isProcessing
            ? (reduceMotion ? 0.5 : CGFloat(0.12 + 0.76 * (0.5 - 0.5 * cos(travelPhase * .pi * 2.0))))
            : 0.5

        context.drawLayer { additiveLayer in
            additiveLayer.blendMode = .plusLighter
            additiveLayer.opacity = isDark ? 1.0 : 0.90

            // 1. Seven coloured vertical radial-ellipse lobes (`paintLobe`, `voice-beam.js:195-236`)
            for index in 0..<lobeCount {
                let f = lobeCount > 1 ? CGFloat(index) / CGFloat(lobeCount - 1) : 0.5
                let drift = CGFloat(sin(time * flow * (0.7 + Double(f)) + Double(index))) * 0.03 * spread
                let home = 0.5 + (f - 0.5) * spread + drift
                let normalizedX = isProcessing ? (home + (beamX - home) * 0.82) : home
                let cx = normalizedX * size.width

                let centerBias = 1.0 - abs(f - 0.5) * 2.0 * bend
                let shimmer = CGFloat(0.5 + 0.5 * sin(time * flow * 1.7 + Double(index) * 1.3))
                let amp = min(max(shaped * centerBias + idleFloor * shimmer * 0.6, 0.0), 1.0)

                let peak = max(4.0, maxReach * (0.18 + amp * 0.82) * (isProcessing ? 1.15 : 1.0))
                let halfW = max(6.0, size.width * (0.06 + 0.10 * spread) * (isProcessing ? 0.60 : 1.0))

                additiveLayer.drawLayer { lobeLayer in
                    lobeLayer.translateBy(x: cx, y: edgeY)
                    lobeLayer.scaleBy(x: halfW / peak, y: 1.0)

                    let lobeRect = CGRect(x: -peak, y: -peak, width: peak * 2.0, height: peak)
                    let baseColor = colors[index]
                    let lobeGradient = Gradient(stops: [
                        .init(color: baseColor.opacity(Double(0.90 * (0.50 + amp * 0.50))), location: 0.0),
                        .init(color: baseColor.opacity(Double(0.50 * (0.40 + amp * 0.60))), location: 0.35),
                        .init(color: baseColor.opacity(0.0), location: 1.0)
                    ])
                    lobeLayer.fill(
                        Path(ellipseIn: CGRect(x: -peak, y: -peak, width: peak * 2.0, height: peak * 2.0))
                            .intersection(Path(lobeRect)),
                        with: .radialGradient(
                            lobeGradient,
                            center: .zero,
                            startRadius: 0,
                            endRadius: peak
                        )
                    )
                }
            }

            // 2. Multi-wave RMS-reactive harmonic voice ribbons along the edge
            if !isProcessing {
                drawHarmonicWaves(
                    in: &additiveLayer,
                    size: size,
                    level: shaped,
                    time: time * flow,
                    colors: colors
                )
            }

            // 3. Luminous core band hugging the bottom edge (`paintBand`, `voice-beam.js:238-250`)
            let bandHeight = max(6.0, (2.0 + shaped * 10.0) * 3.0)
            let bandRect = CGRect(
                x: size.width * 0.08,
                y: edgeY - bandHeight,
                width: size.width * 0.84,
                height: bandHeight
            )
            let bandGradient = Gradient(stops: [
                .init(color: .white.opacity(0.0), location: 0.0),
                .init(color: .white.opacity(0.55), location: 0.50),
                .init(color: .white.opacity(0.95), location: 0.82),
                .init(color: .white.opacity(isDark ? 0.95 : 0.32), location: 1.0)
            ])
            additiveLayer.opacity = Double(0.50 + shaped * 0.50)
            additiveLayer.fill(
                Path(roundedRect: bandRect, cornerRadius: bandHeight * 0.5),
                with: .linearGradient(
                    bandGradient,
                    startPoint: CGPoint(x: size.width * 0.5, y: edgeY - bandHeight),
                    endPoint: CGPoint(x: size.width * 0.5, y: edgeY)
                )
            )
        }
    }

    nonisolated private static func drawHarmonicWaves(
        in context: inout GraphicsContext,
        size: CGSize,
        level: CGFloat,
        time: Double,
        colors: [Color]
    ) {
        let waveCount = 3
        let stepCount = 48
        let usableWidth = size.width * 0.88
        let startX = (size.width - usableWidth) * 0.5
        let baselineY = size.height - 2.0

        for wave in 0..<waveCount {
            var path = Path()
            let frequency = 2.2 + Double(wave) * 1.15
            let phaseSpeed = 3.4 + Double(wave) * 1.35
            let maxWaveAmp = size.height * (0.28 - CGFloat(wave) * 0.06) * (0.12 + level * 0.88)

            for step in 0...stepCount {
                let u = CGFloat(step) / CGFloat(stepCount)
                let envelope = CGFloat(0.5 * (1.0 - cos(2.0 * .pi * Double(u))))
                let oscillation = CGFloat(sin(Double(u) * .pi * 2.0 * frequency - time * phaseSpeed + Double(wave) * 0.9))
                let x = startX + u * usableWidth
                let y = baselineY - abs(oscillation) * maxWaveAmp * envelope - CGFloat(wave) * 1.5
                if step == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            let strokeColor = colors[wave % colors.count].opacity(Double(0.32 + level * 0.45))
            context.stroke(
                path,
                with: .color(strokeColor),
                style: StrokeStyle(lineWidth: 1.6 - CGFloat(wave) * 0.25, lineCap: .round, lineJoin: .round)
            )
        }
    }
}

//
//  LiquidGlassModifiers.swift
//  Cuven
//
//  Apple HIG & iOS 27.1 SDK Grounding:
//  - Human Interface Guidelines › Materials › Liquid Glass (floating functional controls only; never message rows)
//  - Apple Developer Documentation › Adopting Liquid Glass (`Glass`, `View.glassEffect(_:in:)`, `GlassEffectContainer`)
//  - Human Interface Guidelines › Accessibility › Reduce Transparency & Increase Contrast (opaque solid fallback)
//  - Cuven Web Parity: `public/css/glass.css:17-214`, `public/css/liquid.css:16-245`,
//    `public/js/ui/liquid-glass/buttons.js:44-66`, `public/js/ui/liquid-glass/tone.js:18-29`
//

import CuvenCore
import SwiftUI

// MARK: - Canonical View.cuvenLiquidGlass Modifier (`PROJECT.md § 5.3`)

extension View {
    /// Applies Cuven's refractive Liquid Glass material to floating chrome controls (docks, vertical DuoRail,
    /// `Pages` capsule, header pills, and overlay action buttons).
    ///
    /// - Uses native iOS 26 / iOS 27.1 SDK `View.glassEffect(_:in:)` with chainable `Glass.interactive(_:)` and
    ///   `Glass.tint(_:)`, enhanced with Cuven's diagonal upper-left specular glare, multi-stop `0.5pt` rim catchlight,
    ///   and subtle contact lift shadow.
    /// - Automatically falls back to a crisp solid opaque surface (`--glass-solid` + `1pt` hairline) when
    ///   `@Environment(\.accessibilityReduceTransparency)` orIncreased Contrast is enabled (`glass.css:185-213`).
    public func cuvenLiquidGlass(
        mode: GlassAppearanceMode = .clear,
        cornerRadius: CGFloat = 28,
        interactiveBounce: Bool = false
    ) -> some View {
        modifier(
            CuvenLiquidGlassModifier(
                mode: mode,
                tintColor: nil,
                cornerRadius: cornerRadius,
                interactiveBounce: interactiveBounce
            )
        )
    }

    /// Tinted Liquid Glass overload chaining `.tint(_:)` and `.interactive(_:)` directly on `Glass`.
    public func cuvenLiquidGlass(
        mode: GlassAppearanceMode = .clear,
        tint: Color,
        cornerRadius: CGFloat = 28,
        interactiveBounce: Bool = false
    ) -> some View {
        modifier(
            CuvenLiquidGlassModifier(
                mode: mode,
                tintColor: tint,
                cornerRadius: cornerRadius,
                interactiveBounce: interactiveBounce
            )
        )
    }

    /// Applies Cuven's non-refractive frosted pane (`liquid.css:203-244` `--frost`) used on the message composer
    /// field, dictation mic button, and jump-to-latest pill, with focus/dictation rings and Reduce Transparency fallback.
    public func cuvenComposerFrost(
        cornerRadius: CGFloat = 24,
        isFocused: Bool = false,
        isDictating: Bool = false
    ) -> some View {
        modifier(
            CuvenComposerFrostModifier(
                cornerRadius: cornerRadius,
                isFocused: isFocused,
                isDictating: isDictating
            )
        )
    }
}

private struct CuvenLiquidGlassModifier: ViewModifier {
    let mode: GlassAppearanceMode
    let tintColor: Color?
    let cornerRadius: CGFloat
    let interactiveBounce: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    private var prefersSolidSurface: Bool {
        reduceTransparency || colorSchemeContrast == .increased
    }

    private var hairlineWidth: CGFloat {
        displayScale >= 2.0 ? (1.0 / displayScale) : 1.0
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if prefersSolidSurface {
            content
                .background(CuvenColors.glassSolidFallback, in: shape)
                .overlay {
                    shape.strokeBorder(
                        colorSchemeContrast == .increased ? CuvenColors.inkTertiary : CuvenColors.cardLine,
                        lineWidth: 1.0
                    )
                }
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? 0.36 : 0.08),
                    radius: 8,
                    x: 0,
                    y: 3
                )
        } else {
            glassBase(for: content, shape: shape)
                .overlay {
                    specularSurfaceHighlight(shape: shape)
                        .allowsHitTesting(false)
                }
                .overlay {
                    specularRimStroke(shape: shape)
                        .allowsHitTesting(false)
                }
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? 0.34 : 0.10),
                    radius: 9,
                    x: 0,
                    y: 4
                )
        }
    }

    @ViewBuilder
    private func glassBase(for content: Content, shape: RoundedRectangle) -> some View {
        let effectiveBounce = interactiveBounce && !reduceMotion

        if #available(iOS 26.0, *) {
            let baseGlass: Glass = (mode == .clear ? Glass.clear : Glass.regular)
            let tintedGlass: Glass = tintColor.map { baseGlass.tint($0) } ?? baseGlass

            content
                .background {
                    // Cuven's signature 50% frosted base under Liquid Glass (`tokens.css:101`, `liquid.css:180-193`)
                    shape.fill(
                        CuvenColors.glassFrostBase.opacity(mode == .clear ? 0.55 : 0.85)
                    )
                }
                .glassEffect(
                    tintedGlass.interactive(effectiveBounce),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        } else {
            content
                .background(
                    mode == .clear ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.thinMaterial),
                    in: shape
                )
                .background(
                    CuvenColors.glassFrostBase.opacity(mode == .clear ? 0.45 : 0.80),
                    in: shape
                )
        }
    }

    /// Upper-left diagonal glare streak + subtle lower-right caustic (`liquid.css:29-34`, `glass.css:32-43`).
    private func specularSurfaceHighlight(shape: RoundedRectangle) -> some View {
        let isDark = colorScheme == .dark
        let glareOpacity: Double = isDark ? 0.14 : (mode == .clear ? 0.38 : 0.48)
        let causticOpacity: Double = isDark ? 0.04 : 0.12

        return shape.fill(
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(glareOpacity), location: 0.0),
                    .init(color: .white.opacity(glareOpacity * 0.25), location: 0.18),
                    .init(color: .clear, location: 0.46),
                    .init(color: .white.opacity(causticOpacity), location: 1.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    /// Multi-stop specular rim catchlight (`tokens.css:113-115` `--glass-rim`, `--glass-rim-low`, `--glass-edge-dark`).
    private func specularRimStroke(shape: RoundedRectangle) -> some View {
        let isDark = colorScheme == .dark
        let topRim = Color.white.opacity(isDark ? 0.24 : 0.92)
        let midRim = Color.white.opacity(isDark ? 0.10 : 0.48)
        let bottomEdge = isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.06)

        return shape.strokeBorder(
            LinearGradient(
                stops: [
                    .init(color: topRim, location: 0.0),
                    .init(color: midRim, location: 0.42),
                    .init(color: bottomEdge, location: 0.82),
                    .init(color: midRim.opacity(0.75), location: 1.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            lineWidth: max(0.5, hairlineWidth)
        )
    }
}

// MARK: - Composer Frosted Pane Modifier (`liquid.css:203-244`)

private struct CuvenComposerFrostModifier: ViewModifier {
    let cornerRadius: CGFloat
    let isFocused: Bool
    let isDictating: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let isSolid = reduceTransparency || colorSchemeContrast == .increased

        content
            .background {
                if isSolid {
                    shape.fill(CuvenColors.glassSolidFallback)
                } else {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(CuvenColors.composerFrost)
                    }
                }
            }
            .overlay {
                if isFocused || isDictating {
                    shape
                        .strokeBorder(
                            isDictating ? CuvenColors.systemBlue.opacity(0.55) : CuvenColors.inkTertiary,
                            lineWidth: 1.0
                        )
                        .padding(-0.5)
                } else {
                    shape.strokeBorder(
                        isSolid
                            ? CuvenColors.cardLine
                            : Color.white.opacity(colorScheme == .dark ? 0.12 : 0.68),
                        lineWidth: isSolid ? 1.0 : 0.5
                    )
                }
            }
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.45 : 0.12),
                radius: 12,
                x: 0,
                y: 5
            )
    }
}

// MARK: - Liquid Glass Pill & Bead Button Style (`CuvenGlassPillButtonStyle`)

/// Interactive Liquid Glass pill/bead button style with `0.96 -> 1.0` spring press bounce,
/// touch-contact bloom (`glass.css:46-56`), `>= 44×44pt` HIG hit region, and Reduce Motion / Reduce Transparency compliance.
public struct CuvenGlassPillButtonStyle: ButtonStyle {
    public var mode: GlassAppearanceMode
    public var cornerRadius: CGFloat
    public var triggersHaptic: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var isEnabled

    public init(
        mode: GlassAppearanceMode = .clear,
        cornerRadius: CGFloat = 28,
        triggersHaptic: Bool = false
    ) {
        self.mode = mode
        self.cornerRadius = cornerRadius
        self.triggersHaptic = triggersHaptic
    }

    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        configuration.label
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(shape)
            .cuvenLiquidGlass(
                mode: mode,
                cornerRadius: cornerRadius,
                interactiveBounce: !reduceMotion
            )
            .overlay {
                if pressed && !reduceTransparency {
                    shape
                        .fill(
                            RadialGradient(
                                colors: [.white.opacity(0.32), .clear],
                                center: .center,
                                startRadius: 2,
                                endRadius: 36
                            )
                        )
                        .allowsHitTesting(false)
                }
            }
            .scaleEffect(pressed && !reduceMotion ? 0.96 : 1.0)
            .opacity(!isEnabled ? 0.42 : (pressed && reduceMotion ? 0.82 : 1.0))
            .animation(
                reduceMotion ? CuvenSprings.reducedMotionFade : CuvenSprings.pressBounce,
                value: pressed
            )
            .onChange(of: pressed) { _, isNowPressed in
                if isNowPressed && triggersHaptic {
                    CuvenHaptics.lightTap()
                }
            }
    }
}

extension ButtonStyle where Self == CuvenGlassPillButtonStyle {
    /// Default Cuven Liquid Glass pill button style (`mode: .clear`, `cornerRadius: 28`).
    public static var cuvenGlassPill: CuvenGlassPillButtonStyle {
        CuvenGlassPillButtonStyle()
    }

    /// Parameterized Cuven Liquid Glass pill button style.
    public static func cuvenGlassPill(
        mode: GlassAppearanceMode = .clear,
        cornerRadius: CGFloat = 28,
        triggersHaptic: Bool = false
    ) -> CuvenGlassPillButtonStyle {
        CuvenGlassPillButtonStyle(
            mode: mode,
            cornerRadius: cornerRadius,
            triggersHaptic: triggersHaptic
        )
    }
}

// MARK: - Morphing Liquid Glass Group Container (`GlassEffectContainer` Wrapper)

/// Groups adjacent Liquid Glass controls so iOS 26 / iOS 27.1 SDK seamlessly merges and separates
/// neighboring glass beads (`liquid.css:55-79` `.lg-group`), degrading cleanly under Reduce Transparency.
public struct CuvenGlassGroup<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(spacing: CGFloat? = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        if reduceTransparency {
            content
        } else if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

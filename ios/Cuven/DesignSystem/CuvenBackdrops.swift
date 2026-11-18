//
//  CuvenBackdrops.swift
//  Cuven
//
//  Apple HIG Grounding:
//  - Human Interface Guidelines › Color & Dark Mode (distinct Light & Dark atmospheric backdrops +
//    theme paper wash over custom photos so foreground message bubbles maintain WCAG contrast)
//  - Cuven Web Parity: `public/css/backdrops.css:6-105`, `public/js/ui/backdrops.js:7-58`
//    (`mist`, `dawn`, `mint`, `sand` ["Dune"], `ocean`, `dusk`, `dots`, `night` + custom photo wash)
//

import CuvenCore
import SwiftUI
import UIKit

extension BackdropPreset {
    /// Human-readable label matching `PRESETS` in `public/js/ui/backdrops.js:7-16` (`sand` displays as `"Dune"`).
    public var displayName: String {
        switch self {
        case .mist:  return "Mist"
        case .dawn:  return "Dawn"
        case .mint:  return "Mint"
        case .sand:  return "Dune"
        case .ocean: return "Ocean"
        case .dusk:  return "Dusk"
        case .dots:  return "Dots"
        case .night: return "Night"
        }
    }
}

// MARK: - Canonical CuvenBackdropView (`PROJECT.md § 5.3`)

/// Renders all 8 Cuven built-in Light/Dark atmospheric backdrops (`mist`, `dawn`, `mint`, `sand`, `ocean`,
/// `dusk`, `dots`, `night`) and optional custom photo backdrop with theme readability wash.
public struct CuvenBackdropView: View {
    public let preset: BackdropPreset
    public let customImageURL: String?
    public let forceDark: Bool

    @State private var loadedCustomPhoto: UIImage?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Canonical `PROJECT.md § 5.3` initializer.
    public init(preset: BackdropPreset, customImageURL: String? = nil) {
        self.preset = preset
        self.customImageURL = customImageURL
        self.forceDark = false
    }

    /// Extended initializer supporting Call screens, which always render the dark variant (`backdrops.css:4,67`).
    public init(preset: BackdropPreset, customImageURL: String? = nil, forceDark: Bool) {
        self.preset = preset
        self.customImageURL = customImageURL
        self.forceDark = forceDark
    }

    private var isDarkTheme: Bool {
        forceDark || colorScheme == .dark
    }

    private var effectivePhoto: UIImage? {
        if let loadedCustomPhoto {
            return loadedCustomPhoto
        }
        return CuvenDesignMediaLoader.shared.cachedImage(for: customImageURL)
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                presetLayer(size: proxy.size, isDark: isDarkTheme)

                // Custom photo appears only once fully decoded (`backdrops.js:36-57`), washed for bubble contrast (`backdrops.css:8-9`).
                if let uiImage = effectivePhoto {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .overlay {
                            (isDarkTheme ? Color.black.opacity(0.42) : Color.white.opacity(0.30))
                        }
                        .transition(.opacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: customImageURL) {
            await loadCustomPhotoIfNeeded()
        }
    }

    // MARK: - 8 Built-In Preset Renderers (`public/css/backdrops.css:73-104`)

    @ViewBuilder
    private func presetLayer(size: CGSize, isDark: Bool) -> some View {
        switch preset {
        case .mist:
            // `linear-gradient(180deg, #eef2f7, #dde6f0)` / `linear-gradient(180deg, #161b23, #0c1016)`
            LinearGradient(
                colors: isDark
                    ? [Color(cuvenHex: "#161B23"), Color(cuvenHex: "#0C1016")]
                    : [Color(cuvenHex: "#EEF2F7"), Color(cuvenHex: "#DDE6F0")],
                startPoint: .top,
                endPoint: .bottom
            )

        case .dawn:
            // `linear-gradient(160deg, #ffe4d4, #fbd3de 48%, #e4d9f6)` / `linear-gradient(160deg, #3a2028, #2a1d33 50%, #17182b)`
            LinearGradient(
                stops: isDark
                    ? [
                        .init(color: Color(cuvenHex: "#3A2028"), location: 0.0),
                        .init(color: Color(cuvenHex: "#2A1D33"), location: 0.50),
                        .init(color: Color(cuvenHex: "#17182B"), location: 1.0)
                    ]
                    : [
                        .init(color: Color(cuvenHex: "#FFE4D4"), location: 0.0),
                        .init(color: Color(cuvenHex: "#FBD3DE"), location: 0.48),
                        .init(color: Color(cuvenHex: "#E4D9F6"), location: 1.0)
                    ],
                startPoint: Self.unitPoint(cssAngleDegrees: 160).start,
                endPoint: Self.unitPoint(cssAngleDegrees: 160).end
            )

        case .mint:
            // `linear-gradient(165deg, #dcf5ea, #cfeef0 55%, #e6f3fa)` / `linear-gradient(165deg, #0f2a24, #0d2329 55%, #0e1822)`
            LinearGradient(
                stops: isDark
                    ? [
                        .init(color: Color(cuvenHex: "#0F2A24"), location: 0.0),
                        .init(color: Color(cuvenHex: "#0D2329"), location: 0.55),
                        .init(color: Color(cuvenHex: "#0E1822"), location: 1.0)
                    ]
                    : [
                        .init(color: Color(cuvenHex: "#DCF5EA"), location: 0.0),
                        .init(color: Color(cuvenHex: "#CFEEF0"), location: 0.55),
                        .init(color: Color(cuvenHex: "#E6F3FA"), location: 1.0)
                    ],
                startPoint: Self.unitPoint(cssAngleDegrees: 165).start,
                endPoint: Self.unitPoint(cssAngleDegrees: 165).end
            )

        case .sand:
            // `linear-gradient(170deg, #f7efe3, #eee0cc)` / `linear-gradient(170deg, #2a241b, #1a1611)`
            LinearGradient(
                colors: isDark
                    ? [Color(cuvenHex: "#2A241B"), Color(cuvenHex: "#1A1611")]
                    : [Color(cuvenHex: "#F7EFE3"), Color(cuvenHex: "#EEE0CC")],
                startPoint: Self.unitPoint(cssAngleDegrees: 170).start,
                endPoint: Self.unitPoint(cssAngleDegrees: 170).end
            )

        case .ocean:
            // `radial-gradient(120% 80% at 15% 0%, #cfe2ff, transparent 62%), linear-gradient(180deg, #e3eefc, #c9dbf4)`
            ZStack {
                LinearGradient(
                    colors: isDark
                        ? [Color(cuvenHex: "#0C1A30"), Color(cuvenHex: "#060D19")]
                        : [Color(cuvenHex: "#E3EEFC"), Color(cuvenHex: "#C9DBF4")],
                    startPoint: .top,
                    endPoint: .bottom
                )
                RadialGradient(
                    stops: [
                        .init(color: Color(cuvenHex: isDark ? "#1B3A6B" : "#CFE2FF"), location: 0.0),
                        .init(color: .clear, location: 0.62)
                    ],
                    center: UnitPoint(x: 0.15, y: 0.0),
                    startRadius: 0,
                    endRadius: max(size.width * 1.1, size.height * 0.85)
                )
            }

        case .dusk:
            // `linear-gradient(170deg, #f1dcef, #f8e2d0 60%, #fdf0dd)` / `linear-gradient(170deg, #2b1838, #38201f 60%, #1d140f)`
            LinearGradient(
                stops: isDark
                    ? [
                        .init(color: Color(cuvenHex: "#2B1838"), location: 0.0),
                        .init(color: Color(cuvenHex: "#38201F"), location: 0.60),
                        .init(color: Color(cuvenHex: "#1D140F"), location: 1.0)
                    ]
                    : [
                        .init(color: Color(cuvenHex: "#F1DCEF"), location: 0.0),
                        .init(color: Color(cuvenHex: "#F8E2D0"), location: 0.60),
                        .init(color: Color(cuvenHex: "#FDF0DD"), location: 1.0)
                    ],
                startPoint: Self.unitPoint(cssAngleDegrees: 170).start,
                endPoint: Self.unitPoint(cssAngleDegrees: 170).end
            )

        case .dots:
            // `radial-gradient(circle, rgb(0 0 0 / 0.11) 1.2px, transparent 1.8px) 0 0 / 16px 16px, #f4f4f7`
            ZStack {
                Color(cuvenHex: isDark ? "#0B0B0D" : "#F4F4F7")
                Canvas(rendersAsynchronously: true) { context, canvasSize in
                    Self.drawDotLattice(
                        in: &context,
                        size: canvasSize,
                        step: 16.0,
                        offset: CGPoint(x: 8.0, y: 8.0),
                        dotRadius: 1.25,
                        color: isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.11)
                    )
                }
            }

        case .night:
            // Deep twilight gradient + upper-right nebula glow + 46px & 71px dual starfield lattice (`backdrops.css:101-104`)
            ZStack {
                LinearGradient(
                    colors: isDark
                        ? [Color(cuvenHex: "#0B0F24"), Color(cuvenHex: "#05060F")]
                        : [Color(cuvenHex: "#EBEAF6"), Color(cuvenHex: "#DCDCEE")],
                    startPoint: .top,
                    endPoint: .bottom
                )
                RadialGradient(
                    stops: [
                        .init(color: Color(cuvenHex: isDark ? "#1D2350" : "#E7E4FB"), location: 0.0),
                        .init(color: .clear, location: 0.60)
                    ],
                    center: UnitPoint(x: 0.80, y: 0.0),
                    startRadius: 0,
                    endRadius: max(size.width * 1.15, size.height * 0.90)
                )
                Canvas(rendersAsynchronously: true) { context, canvasSize in
                    if isDark {
                        Self.drawDotLattice(
                            in: &context,
                            size: canvasSize,
                            step: 46.0,
                            offset: CGPoint(x: 46.0 * 0.30, y: 46.0 * 0.30),
                            dotRadius: 0.95,
                            color: Color.white.opacity(0.50)
                        )
                        Self.drawDotLattice(
                            in: &context,
                            size: canvasSize,
                            step: 71.0,
                            offset: CGPoint(x: 71.0 * 0.70, y: 71.0 * 0.60),
                            dotRadius: 0.80,
                            color: Color.white.opacity(0.30)
                        )
                    } else {
                        Self.drawDotLattice(
                            in: &context,
                            size: canvasSize,
                            step: 46.0,
                            offset: CGPoint(x: 46.0 * 0.30, y: 46.0 * 0.30),
                            dotRadius: 1.05,
                            color: Color(.sRGB, red: 90.0 / 255.0, green: 80.0 / 255.0, blue: 170.0 / 255.0, opacity: 0.16)
                        )
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    nonisolated private static func drawDotLattice(
        in context: inout GraphicsContext,
        size: CGSize,
        step: CGFloat,
        offset: CGPoint,
        dotRadius: CGFloat,
        color: Color
    ) {
        guard step > 2, size.width > 0, size.height > 0 else { return }
        var path = Path()
        let diameter = dotRadius * 2.0

        var y = offset.y
        while y < size.height + step {
            var x = offset.x
            while x < size.width + step {
                path.addEllipse(in: CGRect(x: x - dotRadius, y: y - dotRadius, width: diameter, height: diameter))
                x += step
            }
            y += step
        }
        context.fill(path, with: .color(color))
    }

    private static func unitPoint(cssAngleDegrees: Double) -> (start: UnitPoint, end: UnitPoint) {
        let radians = (cssAngleDegrees - 90.0) * .pi / 180.0
        let dx = cos(radians) * 0.5
        let dy = sin(radians) * 0.5
        return (
            start: UnitPoint(x: 0.5 - dx, y: 0.5 - dy),
            end: UnitPoint(x: 0.5 + dx, y: 0.5 + dy)
        )
    }

    @MainActor
    private func loadCustomPhotoIfNeeded() async {
        guard let raw = customImageURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            loadedCustomPhoto = nil
            return
        }
        if let cached = CuvenDesignMediaLoader.shared.cachedImage(for: raw) {
            loadedCustomPhoto = cached
            return
        }
        let fetched = await CuvenDesignMediaLoader.shared.loadImage(for: raw)
        guard !Task.isCancelled else { return }
        if reduceMotion {
            loadedCustomPhoto = fetched
        } else {
            withAnimation(.easeOut(duration: 0.24)) {
                loadedCustomPhoto = fetched
            }
        }
    }
}

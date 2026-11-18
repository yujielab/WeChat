//
//  HingeBookCreaseOverlay.swift
//  Cuven
//
//  Apple HIG & iOS 27.1 SDK Grounding:
//  - Human Interface Guidelines › Designing for iPhone Duo › Device poses & Reserved regions
//  - Apple Developer Documentation › `DeviceHinge.angle` (`onHingeChange` continuous optical shading)
//  - Cuven Web Parity: `public/css/base.css:157-193` (`26pt` soft gutter shade on each side of crease,
//    `--gutter-shade`: `rgb(0 0 0 / 0.05)` Light, `rgb(0 0 0 / 0.38)` Dark) & `public/css/posture.css:26-50`
//

import CuvenCore
import SwiftUI

/// Renders the optical book-spine binding depth shadow and non-interactive hinge exclusion zone
/// for `duoHalfBook` (vertical fold `462 | 28..40pt | 461pt`) and `duoHalfLaptop` (horizontal tabletop fold).
public struct HingeBookCreaseOverlay: View {
    public let metrics: DuoLayoutMetrics
    public let hingeAngleDegrees: Double?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Width of the soft ambient falloff gradient on each side of the physical fold (`base.css:168` `26px`).
    private static let gutterFalloffSpan: CGFloat = 26

    public init(metrics: DuoLayoutMetrics, hingeAngleDegrees: Double? = nil) {
        self.metrics = metrics
        self.hingeAngleDegrees = hingeAngleDegrees
    }

    /// Modulates the spine crease depth dynamically when physical `DeviceHinge.angle` is streaming
    /// (`180°` flat -> `0.0`, `115°` book/laptop -> `1.0`), defaulting to `1.0` in deterministic simulation.
    private var creaseIntensity: Double {
        guard metrics.posture == .duoHalfBook || metrics.posture == .duoHalfLaptop else {
            return 0
        }
        guard let angle = hingeAngleDegrees else {
            return 1.0
        }
        // Normalize hinge bend between 178° (almost flat) and 115° (pronounced book/tabletop fold).
        let clamped = min(178.0, max(90.0, angle))
        let progress = (178.0 - clamped) / (178.0 - 115.0)
        return min(1.0, max(0.25, progress))
    }

    private var peakGutterAlpha: Double {
        let baseAlpha = (colorScheme == .dark) ? 0.38 : 0.065
        return baseAlpha * creaseIntensity
    }

    public var body: some View {
        if let divisionRect = metrics.hingeDivisionRect,
           metrics.posture == .duoHalfBook || metrics.posture == .duoHalfLaptop {
            ZStack(alignment: .topLeading) {
                if metrics.posture == .duoHalfBook {
                    verticalBookSpineView(divisionRect: divisionRect)
                } else {
                    horizontalLaptopCreaseView(divisionRect: divisionRect)
                }
            }
            .frame(
                width: metrics.viewportSize.width,
                height: metrics.viewportSize.height,
                alignment: .topLeading
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Vertical Book Fold (`462 | 28..40pt | 461pt`)

    @ViewBuilder
    private func verticalBookSpineView(divisionRect: CGRect) -> some View {
        let falloff = Self.gutterFalloffSpan
        let bandMinX = max(0, divisionRect.minX - falloff)
        let bandMaxX = min(metrics.viewportSize.width, divisionRect.maxX + falloff)
        let bandWidth = max(1, bandMaxX - bandMinX)
        let leftStop = min(0.48, max(0.05, (divisionRect.minX - bandMinX) / bandWidth))
        let rightStop = max(0.52, min(0.95, (divisionRect.maxX - bandMinX) / bandWidth))

        ZStack {
            // Soft bilateral book-gutter gradient (`base.css:169`)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black.opacity(peakGutterAlpha), location: leftStop),
                    .init(color: .black.opacity(peakGutterAlpha * 1.28), location: 0.5),
                    .init(color: .black.opacity(peakGutterAlpha), location: rightStop),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: bandWidth, height: metrics.viewportSize.height)
            .offset(x: bandMinX, y: 0)

            // Hinge exclusion gutter surface + subtle specular binding seam so zero text straddles the fold
            Rectangle()
                .fill(
                    reduceTransparency
                        ? CuvenColors.elevatedSurface
                        : CuvenColors.elevatedSurface.opacity(colorScheme == .dark ? 0.92 : 0.86)
                )
                .frame(width: divisionRect.width, height: divisionRect.height)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(CuvenColors.hairlineSeparator)
                        .frame(width: 0.5)
                }
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(CuvenColors.hairlineSeparator)
                        .frame(width: 0.5)
                }
                .overlay {
                    // Subtle center spine crease highlight/shadow pair
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.black.opacity(colorScheme == .dark ? 0.45 : 0.09))
                            .frame(width: 1)
                        Rectangle()
                            .fill(Color.white.opacity(colorScheme == .dark ? 0.07 : 0.55))
                            .frame(width: 0.5)
                    }
                }
                .offset(x: divisionRect.minX, y: divisionRect.minY)
        }
    }

    // MARK: - Horizontal Tabletop / Laptop Crease

    @ViewBuilder
    private func horizontalLaptopCreaseView(divisionRect: CGRect) -> some View {
        let falloff = Self.gutterFalloffSpan
        let bandMinY = max(0, divisionRect.minY - falloff)
        let bandMaxY = min(metrics.viewportSize.height, divisionRect.maxY + falloff)
        let bandHeight = max(1, bandMaxY - bandMinY)
        let topStop = min(0.48, max(0.05, (divisionRect.minY - bandMinY) / bandHeight))
        let bottomStop = max(0.52, min(0.95, (divisionRect.maxY - bandMinY) / bandHeight))

        ZStack(alignment: .topLeading) {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black.opacity(peakGutterAlpha), location: topStop),
                    .init(color: .black.opacity(peakGutterAlpha * 1.25), location: 0.5),
                    .init(color: .black.opacity(peakGutterAlpha), location: bottomStop),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: metrics.viewportSize.width, height: bandHeight)
            .offset(x: 0, y: bandMinY)

            Rectangle()
                .fill(
                    reduceTransparency
                        ? CuvenColors.elevatedSurface
                        : CuvenColors.elevatedSurface.opacity(colorScheme == .dark ? 0.94 : 0.90)
                )
                .frame(width: divisionRect.width, height: divisionRect.height)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(CuvenColors.hairlineSeparator)
                        .frame(height: 0.5)
                }
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(CuvenColors.hairlineSeparator)
                        .frame(height: 0.5)
                }
                .overlay {
                    Capsule(style: .continuous)
                        .fill(CuvenColors.inkSecondary.opacity(0.28))
                        .frame(width: 44, height: 3)
                }
                .offset(x: divisionRect.minX, y: divisionRect.minY)
        }
    }
}

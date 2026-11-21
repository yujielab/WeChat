import SwiftUI

/// Four soft lights drifting on their own paths behind a call. Still when
/// Reduce Motion is on.
struct GlowField: View {
    var palette: String = "ocean"
    var intensity: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    static func colors(_ palette: String) -> [Color] {
        switch palette {
        case "dawn": return [Color(hex: 0xff7aa8), Color(hex: 0xffb35c), Color(hex: 0xff8f6b), Color(hex: 0xb58cff)]
        case "aurora": return [Color(hex: 0x3ee6a8), Color(hex: 0x2fc6e8), Color(hex: 0x8f7bff), Color(hex: 0x5ad1ff)]
        default: return [Color(hex: 0x1877f2), Color(hex: 0x3fc8ff), Color(hex: 0x6a5cff), Color(hex: 0x2ad4c4)]
        }
    }

    var body: some View {
        if palette == "off" {
            Color.clear
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { tl in
                let t = reduceMotion ? 0 : tl.date.timeIntervalSinceReferenceDate
                Canvas { ctx, size in
                    let cols = Self.colors(palette)
                    let periods: [Double] = [11, 14, 17, 13]
                    for i in 0..<4 {
                        let p = periods[i]
                        let a = t / p * .pi * 2 + Double(i) * 1.7
                        let x = size.width * (0.2 + 0.6 * (0.5 + 0.5 * sin(a)))
                        let y = size.height * (0.35 + 0.4 * (0.5 + 0.5 * cos(a * 0.8 + Double(i))))
                        let r = min(size.width, 420) * (0.28 + 0.06 * sin(a * 1.3))
                        let pulse = 0.55 + 0.45 * (0.5 + 0.5 * sin(a * 0.7 + Double(i) * 2))
                        let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                        ctx.opacity = (scheme == .dark ? 0.32 : 0.22) * pulse * intensity
                        ctx.fill(Path(ellipseIn: rect), with: .radialGradient(
                            Gradient(colors: [cols[i], cols[i].opacity(0)]),
                            center: CGPoint(x: rect.midX, y: rect.midY), startRadius: 0, endRadius: r))
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

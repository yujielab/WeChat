import SwiftUI
import UIKit

// The web app's design tokens (public/css/tokens.css, chat.css), value for
// value, light and dark, so the two clients look the same side by side.

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: alpha)
    }

    /// A token with a light and a dark value (hex + alpha each).
    static func token(_ light: UInt32, _ dark: UInt32, _ la: Double = 1, _ da: Double = 1) -> Color {
        Color(UIColor { t in
            let dark0 = t.userInterfaceStyle == .dark
            let hex = dark0 ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: dark0 ? da : la)
        })
    }

    /// hsl(h s% l%) as CSS computes it.
    static func hsl(_ h: Double, _ s: Double, _ l: Double, _ a: Double = 1) -> Color {
        let s = s / 100, l = l / 100
        let c = (1 - abs(2 * l - 1)) * s
        let hp = h / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        var (r, g, b) = (0.0, 0.0, 0.0)
        switch hp {
        case 0..<1: (r, g, b) = (c, x, 0)
        case 1..<2: (r, g, b) = (x, c, 0)
        case 2..<3: (r, g, b) = (0, c, x)
        case 3..<4: (r, g, b) = (0, x, c)
        case 4..<5: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        let m = l - c / 2
        return Color(.sRGB, red: r + m, green: g + m, blue: b + m, opacity: a)
    }
}

enum Theme {
    // Surfaces
    static let bg = Color.token(0xffffff, 0x000000)
    static let paper = Color.token(0xf5f5f7, 0x000000)
    static let surface = Color.token(0xffffff, 0x0f0f11)
    /// Cards on the grouped background (Apple's secondary grouped background in the dark).
    static let elevated = Color.token(0xffffff, 0x1c1c1e)
    static let grouped = Color.token(0xf5f5f7, 0x000000)
    static let grouped2 = Color.token(0xffffff, 0x1c1c1e)
    static let field = Color.token(0xf2f2f5, 0x111113)
    static let line = Color.token(0xe5e5ea, 0xf0f0fa, 1, 0.13)

    // Labels
    static let label = Color.token(0x0b0b0d, 0xf5f5fa)
    static let label2 = Color.token(0x6e6e73, 0xf0f0fa, 1, 0.6)
    static let label3 = Color.token(0x8e8e93, 0xf0f0fa, 1, 0.34)
    static let label4 = Color.token(0x3c3c43, 0xf0f0fa, 0.18, 0.16)
    static let separator = Color.token(0x3c3c43, 0xf0f0fa, 0.22, 0.16)

    // Fills
    static let fill = Color.token(0x787880, 0x787880, 0.2, 0.36)
    static let fill2 = Color.token(0x787880, 0x787880, 0.16, 0.32)
    static let fill3 = Color.token(0x767680, 0x767680, 0.12, 0.24)
    static let fill4 = Color.token(0x747480, 0x767680, 0.08, 0.18)

    // Colors
    /// The one accent: your messages, what's selected, what's new. Blue is
    /// status and selection; actions are ink.
    static let accent = Color.token(0x1877f2, 0x2d88ff)
    static var blue: Color { accent }
    static let blueText = Color.token(0x0062cc, 0x0a84ff)
    static let red = Color.token(0xff3b30, 0xff453a)
    static let redText = Color.token(0xd70015, 0xff453a)
    static let green = Color.token(0x34c759, 0x30d158)
    static let orange = Color.token(0xff9500, 0xff9f0a)
    static let orangeText = Color.token(0xc93400, 0xff9f0a)
    static let indigo = Color.token(0x5856d6, 0x5e5ce6)
    static let brand = Color(hex: 0x00ad59)
    static let brandText = Color.token(0x007a4d, 0x00c357)
    static let brandStrong = Color.token(0x007a4d, 0x00c357)
    static let onBrand = Color.token(0xffffff, 0x000000)
    static let fbBlue = Color(hex: 0x1877f2)
    static var fbBlueTitle: Color { accent }
    static var skyTitle: Color { accent }
    static let mention = Color.token(0x0062cc, 0x409cff)
    static var tickRead: Color { accent }

    // Ink: primary actions are ink, not blue.
    static let ink = Color.token(0x000000, 0xf5f5fa)
    static let onInk = Color.token(0xffffff, 0x000000)

    // Messages (chat.css: your messages are Facebook blue in the conversation)
    static let bubbleOut = fbBlue
    static let bubbleOutText = Color.white
    static let bubbleIn = Color.token(0xf0f0f2, 0x232626)
    static let bubbleInText = Color.token(0x111b21, 0xe9edef)
    static let bubbleCard = Color.token(0xffffff, 0x1c1c1e)
    static let linkIn = Color.token(0x0062cc, 0x5eb0ff)

    static let scrim = Color.token(0x000000, 0x000000, 0.32, 0.6)
    static let imageOutline = Color.token(0x000000, 0xffffff, 0.08, 0.12)
    static let glassSolid = Color.token(0xffffff, 0x121214)
    static let glassRim = Color.token(0xffffff, 0xffffff, 0.95, 0.2)

    // Legacy names used across the app
    static var fillQuiet: Color { fill4 }
    static var systemBlue: Color { blue }
    static var sky: Color { skyTitle }

    /// The web's monogram colors: one of five hues from the name.
    static func avatarHue(_ name: String) -> Double {
        var h: UInt32 = 0
        for scalar in name.unicodeScalars { h = h &* 31 &+ scalar.value }
        return [27, 75, 145, 205, 265][Int(h % 5)]
    }

    static func avatarColors(_ name: String) -> (bg: Color, fg: Color) {
        let hue = avatarHue(name)
        let bg = Color(UIColor { t in
            UIColor(t.userInterfaceStyle == .dark ? Color.hsl(hue, 15, 23) : Color.hsl(hue, 20, 90))
        })
        let fg = Color(UIColor { t in
            UIColor(t.userInterfaceStyle == .dark ? Color.hsl(hue, 22, 78) : Color.hsl(hue, 20, 34))
        })
        return (bg, fg)
    }

    /// Initials as the web makes them (ui/format.js): a CJK character alone,
    /// two letters from two words that start with letters, else the first.
    static func initials(_ name: String) -> String {
        let s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        if let cjk = s.unicodeScalars.first(where: { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }) {
            return String(Character(cjk))
        }
        let words = s.split(whereSeparator: { $0.isWhitespace })
        if words.count > 1, let a = words[0].first, let b = words[1].first, a.isLetter, b.isLetter {
            return (String(a) + String(b)).uppercased()
        }
        return String(s.first!).uppercased()
    }
}

// MARK: - Type: Clarinetta everywhere, sized like the web's rem scale

enum AppFont {
    /// CSS weights map onto the faces the web ships: 300 Light, 400 Regular,
    /// 500 Medium; 550–700 Bold (the browser picks the next heavier face);
    /// 800 ExtraBold; 900 Black.
    static func face(_ weight: Font.Weight) -> String {
        switch weight {
        case .light, .thin, .ultraLight: return "Clarinetta-Light"
        case .medium: return "Clarinetta-Medium"
        case .semibold, .bold: return "Clarinetta-Bold"
        case .heavy: return "Clarinetta-ExtraBold"
        case .black: return "Clarinetta-Black"
        default: return "Clarinetta-Regular"
        }
    }

    static func make(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        Font.custom(face(weight), size: size, relativeTo: style)
    }

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> UIFont {
        UIFont(name: face(weight), size: size) ?? .systemFont(ofSize: size)
    }
}

extension Font {
    // tokens.css type scale (rem = 17px)
    static let largeTitleC = AppFont.make(34, .bold, relativeTo: .largeTitle)
    static let title1C = AppFont.make(28, .bold, relativeTo: .title)
    static let title2C = AppFont.make(22, .bold, relativeTo: .title2)
    static let title3C = AppFont.make(20, .semibold, relativeTo: .title3)
    static let headlineC = AppFont.make(17, .semibold, relativeTo: .headline)
    static let bodyC = AppFont.make(17, .regular, relativeTo: .body)
    static let calloutC = AppFont.make(16, .regular, relativeTo: .callout)
    static let subheadC = AppFont.make(15, .regular, relativeTo: .subheadline)
    static let subheadMediumC = AppFont.make(15, .medium, relativeTo: .subheadline)
    static let subheadBoldC = AppFont.make(15, .semibold, relativeTo: .subheadline)
    static let footnoteC = AppFont.make(13, .regular, relativeTo: .footnote)
    static let captionC = AppFont.make(12, .regular, relativeTo: .caption)
    static let caption2C = AppFont.make(11, .medium, relativeTo: .caption2)
}

// MARK: - Motion (tokens.css: durations and the sampled springs)

/// One small vocabulary: springs for whatever the finger moved or a place you
/// go to, short ease-outs for colour and opacity (exits faster than entries).
enum Motion {
    /// Settling (pushes, columns, sheets, surfaces): 400ms, no overshoot.
    static let move = Animation.spring(duration: 0.4, bounce: 0)
    /// Arrival (a new message, a new post): 480ms, one soft overshoot.
    static let soft = Animation.spring(duration: 0.48, bounce: 0.18)
    /// --spring-snappy: 266ms, a hair of overshoot.
    static let ui = Animation.spring(duration: 0.266, bounce: 0.05)
    /// --spring-bouncy: 403ms.
    static let bouncy = Animation.spring(duration: 0.403, bounce: 0.15)
    /// --spring-gentle: 490ms.
    static let gentle = Animation.spring(duration: 0.49, bounce: 0)
    /// Morphs from a source (the "+" panel, the viewer): --ease-morph.
    static let morph = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.36)
    /// Press: in at once (100ms), out from wherever it got to (190ms).
    static let pressIn = Animation.easeOut(duration: 0.1)
    static let pressOut = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.19)
    /// --dur-quick: colour and opacity state changes, 160ms.
    static let quick = Animation.easeOut(duration: 0.16)
    /// A new message: 170ms, no scale, blur or bounce.
    static let message = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.17)
    /// --dur-fade: scrims and overlays.
    static let fade = Animation.easeOut(duration: 0.2)
    /// --dur-burst: the double-tap heart.
    static let burst = Animation.spring(duration: 0.56, bounce: 0.35)
    static let pressScale: CGFloat = 0.98
}

// MARK: - Haptics

enum Haptics {
    static var enabled = true
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let softGen = UIImpactFeedbackGenerator(style: .soft)
    private static let note = UINotificationFeedbackGenerator()
    private static let select = UISelectionFeedbackGenerator()

    static func tap() { if enabled { light.impactOccurred() } }
    static func press() { if enabled { rigid.impactOccurred(intensity: 0.6) } }
    static func soft() { if enabled { softGen.impactOccurred() } }
    static func selection() { if enabled { select.selectionChanged() } }
    static func success() { if enabled { note.notificationOccurred(.success) } }
    static func warning() { if enabled { note.notificationOccurred(.warning) } }
    static func error() { if enabled { note.notificationOccurred(.error) } }
}

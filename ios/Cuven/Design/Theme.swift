import SwiftUI
import UIKit

// The web app's tokens (public/css/tokens.css) as native colors: paper white
// and near-black ink, Facebook blue for your messages and live things, cool
// neutral greys, and glass only on the floating controls.

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: alpha)
    }

    /// A color with a light and a dark value.
    static func dynamic(_ light: UInt32, _ dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(UIColor { t in
            let hex = t.userInterfaceStyle == .dark ? dark : light
            let a = t.userInterfaceStyle == .dark ? darkAlpha : lightAlpha
            return UIColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: a)
        })
    }
}

enum Theme {
    static let bg = Color.dynamic(0xffffff, 0x000000)
    static let paper = Color.dynamic(0xf5f5f7, 0x0d0d0f)
    static let elevated = Color.dynamic(0xffffff, 0x1c1c1e)
    static let grouped = Color.dynamic(0xf2f2f7, 0x000000)
    static let groupedCell = Color.dynamic(0xffffff, 0x1c1c1e)
    static let label = Color.dynamic(0x0b0b0d, 0xf5f5f7)
    static let label2 = Color.dynamic(0x6e6e73, 0xa1a1a6)
    static let label3 = Color.dynamic(0x8e8e93, 0x7c7c80)
    static let line = Color.dynamic(0xe5e5ea, 0x2c2c2e)
    static let separator = Color.dynamic(0x3c3c43, 0x545458, lightAlpha: 0.22, darkAlpha: 0.6)
    static let field = Color.dynamic(0xf2f2f5, 0x1c1c1e)
    static let fillQuiet = Color.dynamic(0xececf0, 0x1f1f22)
    static let fill = Color.dynamic(0x787880, 0x787880, lightAlpha: 0.16, darkAlpha: 0.32)

    static let blue = Color.dynamic(0x1877f2, 0x2d88ff)          // Facebook blue: your messages, titles
    static let sky = Color.dynamic(0x0099ff, 0x34adff)           // Moments
    static let systemBlue = Color.dynamic(0x007aff, 0x0a84ff)
    static let red = Color.dynamic(0xff3b30, 0xff453a)
    static let redText = Color.dynamic(0xd70015, 0xff6961)
    static let green = Color.dynamic(0x34c759, 0x30d158)
    static let orange = Color.dynamic(0xff9500, 0xff9f0a)
    static let ink = Color.dynamic(0x000000, 0xffffff)
    static let onInk = Color.dynamic(0xffffff, 0x000000)

    static let bubbleOut = blue
    static let bubbleOutText = Color.white
    static let bubbleIn = Color.dynamic(0xf0f0f2, 0x262628)
    static let bubbleInText = Color.dynamic(0x111b21, 0xf2f2f5)
    static let keyHighlight = Color.dynamic(0xfff1a8, 0x5a4a00, lightAlpha: 0.9, darkAlpha: 0.6)

    static let scrim = Color.black.opacity(0.32)
    static let glassFrost = Color.dynamic(0xececf0, 0x2a2a2e, lightAlpha: 0.5, darkAlpha: 0.5)

    /// Avatar tints for people without a photo, chosen from their id.
    static let avatarTints: [(Color, Color)] = [
        (Color.dynamic(0xe6dff0, 0x3a3346), Color.dynamic(0x5b4b78, 0xd6c8f0)),
        (Color.dynamic(0xdcefe4, 0x26392e), Color.dynamic(0x2f6b4a, 0xb8e6cb)),
        (Color.dynamic(0xe1e7f0, 0x2b3240), Color.dynamic(0x3c5478, 0xc5d5f0)),
        (Color.dynamic(0xf0e6dc, 0x40362c), Color.dynamic(0x7a5634, 0xf0d6bd)),
        (Color.dynamic(0xf0dfe3, 0x40303a), Color.dynamic(0x7a3c4f, 0xf0c5d3)),
        (Color.dynamic(0xdff0ef, 0x283c3b), Color.dynamic(0x2f6b68, 0xb8e6e3))
    ]

    static func tint(for id: String) -> (Color, Color) {
        var h: UInt32 = 5381
        for b in id.utf8 { h = (h &* 33) &+ UInt32(b) }
        return avatarTints[Int(h % UInt32(avatarTints.count))]
    }
}

// MARK: - Type (Clarinetta, sized with Dynamic Type; CJK falls back to PingFang)

enum AppFont {
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
}

extension Font {
    static let largeTitleC = AppFont.make(34, .bold, relativeTo: .largeTitle)
    static let title1C = AppFont.make(28, .bold, relativeTo: .title)
    static let title2C = AppFont.make(22, .bold, relativeTo: .title2)
    static let title3C = AppFont.make(20, .semibold, relativeTo: .title3)
    static let headlineC = AppFont.make(17, .semibold, relativeTo: .headline)
    static let bodyC = AppFont.make(17, .regular, relativeTo: .body)
    static let calloutC = AppFont.make(16, .regular, relativeTo: .callout)
    static let subheadC = AppFont.make(15, .regular, relativeTo: .subheadline)
    static let subheadMediumC = AppFont.make(15, .medium, relativeTo: .subheadline)
    static let footnoteC = AppFont.make(13, .regular, relativeTo: .footnote)
    static let captionC = AppFont.make(12, .regular, relativeTo: .caption)
    static let caption2C = AppFont.make(11, .medium, relativeTo: .caption2)
}

// MARK: - Motion (the web app's sampled springs, as native springs)

enum Motion {
    /// Columns and surfaces: about half a second, no overshoot.
    static let move = Animation.spring(response: 0.42, dampingFraction: 0.92)
    /// Small moves: indicators, toggles.
    static let ui = Animation.spring(response: 0.3, dampingFraction: 0.86)
    /// Things that grow from where they were touched.
    static let morph = Animation.spring(response: 0.36, dampingFraction: 0.8)
    /// A press: in at once, out gently.
    static let pressIn = Animation.easeOut(duration: 0.1)
    static let pressOut = Animation.spring(response: 0.28, dampingFraction: 0.62)
    /// Frequent, light: a new message, switching chats.
    static let quick = Animation.easeOut(duration: 0.17)
    static let bouncy = Animation.spring(response: 0.38, dampingFraction: 0.62)
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

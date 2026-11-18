import SwiftUI
import CuvenCore

// MARK: - Curved iMessage / Cuven Vector Bubble Shape

/// Renders Cuven's signature message bubble silhouette:
/// - `22pt` outer corners (`--r-bubble: 22px` in `chat.css:13`).
/// - Run-interior corners facing the sender's edge pinch to `8pt` (`thread.css:877-880`)
///   so consecutive bubbles from one person read as a cohesive stack.
/// - On the final bubble of a run (`showTail == true`), draws a smooth cubic-Bezier
///   curved vector tail extending `6.5pt` toward the sender's margin (`chat.css:113-125`).
public struct BubbleTailShape: Shape, Sendable {
    public var isOutgoing: Bool
    public var isFirstInRun: Bool
    public var isLastInRun: Bool
    public var showTail: Bool

    public init(
        isOutgoing: Bool,
        isFirstInRun: Bool = true,
        isLastInRun: Bool = true,
        showTail: Bool = true
    ) {
        self.isOutgoing = isOutgoing
        self.isFirstInRun = isFirstInRun
        self.isLastInRun = isLastInRun
        self.showTail = showTail
    }

    public func path(in rect: CGRect) -> Path {
        let tailOutreach: CGFloat = showTail ? 6.5 : 0
        let bodyRect: CGRect
        if isOutgoing {
            bodyRect = CGRect(
                x: rect.minX,
                y: rect.minY,
                width: max(16, rect.width - tailOutreach),
                height: rect.height
            )
        } else {
            bodyRect = CGRect(
                x: rect.minX + tailOutreach,
                y: rect.minY,
                width: max(16, rect.width - tailOutreach),
                height: rect.height
            )
        }

        let fullRadius: CGFloat = min(22, min(bodyRect.width, bodyRect.height) * 0.48)
        let pinchedRadius: CGFloat = min(8, fullRadius)

        let topLeft: CGFloat = (!isOutgoing && !isFirstInRun) ? pinchedRadius : fullRadius
        let topRight: CGFloat = (isOutgoing && !isFirstInRun) ? pinchedRadius : fullRadius
        let bottomLeft: CGFloat = (!isOutgoing && (!isLastInRun || showTail)) ? pinchedRadius : fullRadius
        let bottomRight: CGFloat = (isOutgoing && (!isLastInRun || showTail)) ? pinchedRadius : fullRadius

        var path = Path()
        let minX = bodyRect.minX
        let maxX = bodyRect.maxX
        let minY = bodyRect.minY
        let maxY = bodyRect.maxY

        // Start along top edge after top-left corner
        path.move(to: CGPoint(x: minX + topLeft, y: minY))
        path.addLine(to: CGPoint(x: maxX - topRight, y: minY))

        // Top-right corner
        path.addArc(
            center: CGPoint(x: maxX - topRight, y: minY + topRight),
            radius: topRight,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )

        if isOutgoing && showTail {
            // Right edge down to curved foot tail (`M0 0 C0 8 4.5 14 12 16 L0 16 Z` scaled to crisp vector)
            let tailStartY = max(minY + topRight, maxY - 16)
            path.addLine(to: CGPoint(x: maxX, y: tailStartY))
            let tipX = rect.maxX
            path.addCurve(
                to: CGPoint(x: tipX, y: maxY),
                control1: CGPoint(x: maxX, y: maxY - 7.5),
                control2: CGPoint(x: maxX + tailOutreach * 0.52, y: maxY - 1.5)
            )
            // Sweep back into bottom edge of bubble
            path.addCurve(
                to: CGPoint(x: maxX - 10, y: maxY),
                control1: CGPoint(x: maxX + tailOutreach * 0.15, y: maxY + 0.4),
                control2: CGPoint(x: maxX - 4, y: maxY)
            )
        } else {
            path.addLine(to: CGPoint(x: maxX, y: maxY - bottomRight))
            path.addArc(
                center: CGPoint(x: maxX - bottomRight, y: maxY - bottomRight),
                radius: bottomRight,
                startAngle: .degrees(0),
                endAngle: .degrees(90),
                clockwise: false
            )
        }

        if !isOutgoing && showTail {
            // Bottom edge over to incoming left curved foot tail
            path.addLine(to: CGPoint(x: minX + 10, y: maxY))
            let tipX = rect.minX
            path.addCurve(
                to: CGPoint(x: tipX, y: maxY),
                control1: CGPoint(x: minX + 4, y: maxY),
                control2: CGPoint(x: minX - tailOutreach * 0.15, y: maxY + 0.4)
            )
            let tailEndY = max(minY + topLeft, maxY - 16)
            path.addCurve(
                to: CGPoint(x: minX, y: tailEndY),
                control1: CGPoint(x: minX - tailOutreach * 0.52, y: maxY - 1.5),
                control2: CGPoint(x: minX, y: maxY - 7.5)
            )
        } else {
            path.addLine(to: CGPoint(x: minX + bottomLeft, y: maxY))
            path.addArc(
                center: CGPoint(x: minX + bottomLeft, y: maxY - bottomLeft),
                radius: bottomLeft,
                startAngle: .degrees(90),
                endAngle: .degrees(180),
                clockwise: false
            )
        }

        // Left edge up to top-left corner
        path.addLine(to: CGPoint(x: minX, y: minY + topLeft))
        path.addArc(
            center: CGPoint(x: minX + topLeft, y: minY + topLeft),
            radius: topLeft,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )

        path.closeSubpath()
        return path
    }
}

// MARK: - Bubble Ink & Surface Palette Helper

enum ThreadSurfaceTokens {
    /// Outgoing bubble surface from canonical `DesignSystem` (`CuvenColors.outgoingBubble`).
    static var outgoingFill: Color { CuvenColors.outgoingBubble }
    static var outgoingForeground: Color { CuvenColors.outgoingBubbleText }

    /// Incoming paper-zinc bubble surface (`#F4F4F5` light / `#18181B`–`#232626` dark via `CuvenColors.incomingBubble`).
    static var incomingFill: Color { CuvenColors.incomingBubble }
    static var incomingForeground: Color { CuvenColors.incomingBubbleText }

    /// Facebook / Cuven accent blue (`#1877F2` light / `#2D88FF` dark) for header `(i)` & active links.
    static func headerInfoBlue(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0x2D / 255.0, green: 0x88 / 255.0, blue: 0xFF / 255.0)
            : Color(red: 0x18 / 255.0, green: 0x77 / 255.0, blue: 0xF2 / 255.0)
    }

    /// Quiet tabular timestamp ink (`#6B7280` light / `#A1A1AA` dark from `chat-time.css:10-14`).
    static func timestampInk(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0xA1 / 255.0, green: 0xA1 / 255.0, blue: 0xAA / 255.0)
            : Color(red: 0x6B / 255.0, green: 0x72 / 255.0, blue: 0x80 / 255.0)
    }

    /// Warm system-notice chip plate (`#FFEFD1` / `#6B5525` light, `#232626` dark from `tokens.css`).
    static func systemNoticeFill(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0x23 / 255.0, green: 0x26 / 255.0, blue: 0x26 / 255.0).opacity(0.9)
            : Color(red: 0xFF / 255.0, green: 0xEF / 255.0, blue: 0xD1 / 255.0).opacity(0.94)
    }

    static func systemNoticeForeground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0xE9 / 255.0, green: 0xED / 255.0, blue: 0xEF / 255.0).opacity(0.8)
            : Color(red: 0x6B / 255.0, green: 0x55 / 255.0, blue: 0x25 / 255.0)
    }
}

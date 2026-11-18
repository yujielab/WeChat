import SwiftUI
import UIKit
import CuvenCore

// MARK: - Apple HIG & Cuven Web Inbox Tokens
//
// Grounding References:
// - Apple Human Interface Guidelines: Color & Accessibility (WCAG AA >= 4.5:1 text contrast,
//   Increase Contrast / UIAccessibility.isDarkerSystemColorsEnabled support)
// - Apple Human Interface Guidelines: Typography & Dynamic Type (capped chrome text <= 21pt)
// - Apple Human Interface Guidelines: Motion & Gestures (Designing Fluid Interfaces — rubberband
//   resistance & momentum velocity projection)
// - Cuven Web Reference: `public/css/tokens.css`, `public/css/list.css`, `public/css/people.css`,
//   `public/css/insights.css`, `docs/hig-audit.md` (P0-1, P0-2, P1-6, P2-2)

enum ChatListPalette {
    /// `"Messages"` large title color (`--fb-blue-title`: `#1877F2` light / `#2D88FF` dark).
    static let messagesTitleBlue = Color(UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 0x2D / 255.0, green: 0x88 / 255.0, blue: 0xFF / 255.0, alpha: 1.0)
        }
        return UIColor(red: 0x18 / 255.0, green: 0x77 / 255.0, blue: 0xF2 / 255.0, alpha: 1.0)
    })

    /// Active filter thumb & Duo header frosted search circle (`color-mix(in srgb, #1877F2 82%, transparent)`).
    static let filterGlassBlue = Color(UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 0x2D / 255.0, green: 0x88 / 255.0, blue: 0xFF / 255.0, alpha: 0.84)
        }
        return UIColor(red: 0x18 / 255.0, green: 0x77 / 255.0, blue: 0xF2 / 255.0, alpha: 0.84)
    })

    /// Solid Facebook Blue accent (`#1877F2`) for leading-swipe Pin action and scope glyphs.
    static let facebookBlue = Color(red: 0x18 / 255.0, green: 0x77 / 255.0, blue: 0xF2 / 255.0)

    /// WCAG AA >= 5.4:1 unread badge background (`#007A4D` light / `#00C357` dark, `tokens.css:108`).
    static let unreadBadgeBackground = Color(UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 0x00 / 255.0, green: 0xC3 / 255.0, blue: 0x57 / 255.0, alpha: 1.0)
        }
        return UIColor(red: 0x00 / 255.0, green: 0x7A / 255.0, blue: 0x4D / 255.0, alpha: 1.0)
    })

    /// WCAG AA unread badge foreground (`#FFFFFF` on `#007A4D` light; `#000000` on `#00C357` dark).
    static let unreadBadgeForeground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? .black : .white
    })

    /// WCAG AA >= 5.8:1 accessible blue text (`--blue-text`: `#0062CC` light / `#0A84FF` dark)
    /// used for `<mark>` search highlights, `"See all"`, `"Start"`, and Honk live typing text.
    static let accessibleBlueText = Color(UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0, alpha: 1.0)
        }
        return UIColor(red: 0x00 / 255.0, green: 0x62 / 255.0, blue: 0xCC / 255.0, alpha: 1.0)
    })

    /// WCAG AA accessible red text (`--red-text`: `#D70015` light / `#FF453A` dark) for `[Draft]` / `[Not sent]`.
    static let accessibleRedText = Color(UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 0xFF / 255.0, green: 0x45 / 255.0, blue: 0x3A / 255.0, alpha: 1.0)
        }
        return UIColor(red: 0xD7 / 255.0, green: 0x00 / 255.0, blue: 0x15 / 255.0, alpha: 1.0)
    })

    /// Tertiary label honoring Increase Contrast (`#8E8E93` -> `#6C6C70` light; `34%` -> `60%` dark).
    static let tertiaryInk = Color(UIColor { traits in
        let highContrast = traits.accessibilityContrast == .high
        if traits.userInterfaceStyle == .dark {
            return UIColor(white: 0.96, alpha: highContrast ? 0.62 : 0.40)
        }
        return highContrast
            ? UIColor(red: 0x6C / 255.0, green: 0x6C / 255.0, blue: 0x70 / 255.0, alpha: 1.0)
            : UIColor(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0, alpha: 1.0)
    })

    /// Subtle pill/chip fill (`--fill-3` / `--fill-2`).
    static let subtleChipFill = Color(UIColor { traits in
        let highContrast = traits.accessibilityContrast == .high
        if traits.userInterfaceStyle == .dark {
            return UIColor(white: 1.0, alpha: highContrast ? 0.18 : 0.11)
        }
        return UIColor(red: 0x78 / 255.0, green: 0x78 / 255.0, blue: 0x80 / 255.0, alpha: highContrast ? 0.22 : 0.12)
    })

    /// Smart Insights card surface (`color-mix(in srgb, var(--label) 5%, var(--bg))`).
    static let insightCardSurface = Color(UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 0x15 / 255.0, green: 0x15 / 255.0, blue: 0x18 / 255.0, alpha: 1.0)
        }
        return UIColor(red: 0xF6 / 255.0, green: 0xF6 / 255.0, blue: 0xF8 / 255.0, alpha: 1.0)
    })

    /// Gliding active-room selection capsule fill in split mode (`list.css:235`).
    static let splitSelectionFill = Color(UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(white: 1.0, alpha: 0.08)
        }
        return UIColor(red: 0x0B / 255.0, green: 0x0B / 255.0, blue: 0x0D / 255.0, alpha: 0.055)
    })
}

// MARK: - Concentric Corner Radii (`docs/hig-audit.md` P2-2)

enum ChatListRadii {
    static let xs: CGFloat = 8
    static let small: CGFloat = 12
    static let row: CGFloat = 18
    static let bubble: CGFloat = 23
    static let insightCard: CGFloat = 24
    static let contextPreview: CGFloat = 26
}

// MARK: - Spatial Right-Edge Clearance Helper (`DuoLayoutMetrics` & `AdaptiveActionBars` Parity)

enum ChatListSpatialMetrics {
    /// Effective trailing clearance when `ChatList` occupies a single-column iPhone Duo viewport
    /// (`duoClosed` `91pt` or upright 1-column `duoOpen` `84pt`), honoring both hardware `safeAreaRight`
    /// and simulated `--uitest-posture` overrides where `safeAreaRight == 0`.
    /// Returns `0` in 2-column split (`duoOpen` / `duoHalfBook` / `iPhoneSplit`) where `ChatList` sits on the leading pane.
    static func trailingSystemColumnInset(for metrics: DuoLayoutMetrics) -> CGFloat {
        guard metrics.hasRightSystemColumn && metrics.visibleColumnCount == 1 else {
            return 0
        }
        let fallbackReserve: CGFloat = metrics.posture == .duoClosed ? 91 : 84
        return max(metrics.safeAreaRight, fallbackReserve)
    }

    /// Effective usable width of the `ChatList` column.
    static func effectiveColumnWidth(for metrics: DuoLayoutMetrics) -> CGFloat {
        if metrics.visibleColumnCount >= 2 {
            return max(metrics.leadingColumnWidth, 280)
        }
        let rightInset = trailingSystemColumnInset(for: metrics)
        return max(metrics.viewportSize.width - metrics.safeAreaLeft - rightInset, 280)
    }
}

// MARK: - Timestamp & Relative Duration Formatting (`public/js/ui/format.js`, `people.js`)

enum ChatListTimeFormatter {
    static let noteTTLSeconds: TimeInterval = 24 * 3600

    /// Normalizes Unix timestamps regardless of whether stored in milliseconds (`Date.now()`) or seconds.
    static func date(from rawTimestamp: Int64) -> Date {
        if rawTimestamp > 10_000_000_000 {
            return Date(timeIntervalSince1970: TimeInterval(rawTimestamp) / 1000.0)
        }
        return Date(timeIntervalSince1970: TimeInterval(rawTimestamp))
    }

    /// Returns whether a 24h Note is still within its active 24-hour TTL window.
    static func isNoteActive(_ note: UserNote, now: Date = Date()) -> Bool {
        guard note.createdAt > 0 else { return false }
        let created = date(from: note.createdAt)
        let age = now.timeIntervalSince(created)
        return age < noteTTLSeconds
    }

    /// Compact relative age matching `people.js` `since(ts)` (`"now"`, `"5m"`, `"3h"`).
    static func noteAgeString(from rawTimestamp: Int64, now: Date = Date()) -> String {
        guard rawTimestamp > 0 else { return "now" }
        let seconds = max(0, now.timeIntervalSince(date(from: rawTimestamp)))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        return "\(max(1, Int(seconds / 3600)))h"
    }

    /// Conversation row timestamp matching `format.js` `listTime(ts)` + user 12h/24h preference.
    static func listTime(from rawTimestamp: Int64, use24Hour: Bool = true, now: Date = Date()) -> String {
        guard rawTimestamp > 0 else { return "" }
        let target = date(from: rawTimestamp)
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTarget = calendar.startOfDay(for: target)
        let dayDiff = calendar.dateComponents([.day], from: startOfTarget, to: startOfToday).day ?? 0

        if dayDiff <= 0 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = use24Hour ? "HH:mm" : "h:mm a"
            return formatter.string(from: target)
        }
        if dayDiff == 1 {
            return "Yesterday"
        }
        if dayDiff < 7 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEEE"
            return formatter.string(from: target)
        }
        let nowYear = calendar.component(.year, from: now)
        let targetYear = calendar.component(.year, from: target)
        let month = calendar.component(.month, from: target)
        let day = calendar.component(.day, from: target)
        if nowYear == targetYear {
            return "\(month)/\(day)"
        }
        return "\(month)/\(day)/\(targetYear)"
    }
}

// MARK: - 1:1 Swipe Physics Math (`public/js/ui/spring.js` & `chatList.js:616-733`)

enum ChatListSwipeMath {
    static let trailingDeleteRevealWidth: CGFloat = 82
    static let leadingActionsRevealWidth: CGFloat = 152
    static let fullSwipeRatio: CGFloat = 0.55

    /// Progressive resistance past boundaries (`spring.js:98-102`).
    static func rubberband(overshoot: CGFloat, dimension: CGFloat, coefficient: CGFloat = 0.55) -> CGFloat {
        CuvenSprings.rubberBand(overshoot: overshoot, dimension: dimension, resistance: coefficient)
    }

    /// Apple Fluid Interfaces momentum projection (`spring.js:93-95`).
    static func project(velocityPointsPerSecond: CGFloat, decelerationRate: CGFloat = VelocityProjector.normalDecelerationRate) -> CGFloat {
        VelocityProjector.project(velocity: velocityPointsPerSecond, decelerationRate: decelerationRate)
    }

    /// Computes instantaneous 1:1 finger-tracked horizontal offset with rubber-band stretch.
    static func interactiveOffset(
        startOffset: CGFloat,
        translationX: CGFloat,
        rowWidth: CGFloat
    ) -> CGFloat {
        let width = max(rowWidth, 240)
        let raw = startOffset + translationX

        // Trailing swipe (negative): uncovers Delete up to 85% freely, then rubber-bands.
        if raw < -width * 0.85 {
            let extra = raw + width * 0.85
            return -width * 0.85 + rubberband(overshoot: extra, dimension: width, coefficient: 0.55)
        }

        // Leading swipe (positive): uncovers Pin + Unread up to leadingActionsRevealWidth, then rubber-bands gently.
        if raw > leadingActionsRevealWidth {
            let extra = raw - leadingActionsRevealWidth
            return leadingActionsRevealWidth + rubberband(overshoot: extra, dimension: width, coefficient: 0.42)
        }

        return raw
    }

    enum SettleOutcome: Equatable {
        case closed
        case openTrailingDelete
        case fullSwipeDelete
        case openLeadingActions
        case fullSwipeToggleUnread
    }

    /// Resolves release target from current offset + finger velocity (`chatList.js:717-727`).
    static func resolveRelease(
        currentOffset: CGFloat,
        velocityX: CGFloat,
        rowWidth: CGFloat
    ) -> SettleOutcome {
        let fullThreshold = max(rowWidth, 240) * fullSwipeRatio
        if currentOffset < -fullThreshold {
            return .fullSwipeDelete
        }
        if currentOffset > fullThreshold {
            return .fullSwipeToggleUnread
        }

        let projected = currentOffset + project(velocityPointsPerSecond: velocityX, decelerationRate: 0.997)
        if projected < -fullThreshold * 1.15 && currentOffset < -trailingDeleteRevealWidth * 0.9 {
            return .fullSwipeDelete
        }
        if projected < -trailingDeleteRevealWidth * 0.5 {
            return .openTrailingDelete
        }
        if projected > leadingActionsRevealWidth * 0.45 {
            return .openLeadingActions
        }
        return .closed
    }
}

// MARK: - Highlighted Search Substring Builder (`chatList.js:857-861`)

enum ChatListSearchHighlighter {
    /// Builds an `AttributedString` highlighting all case-insensitive occurrences of `query`
    /// in WCAG AA accessible blue (`--blue-text`) matching `<mark>` in `list.css:177`.
    static func highlighted(
        _ source: String,
        query: String,
        baseColor: Color,
        highlightColor: Color = ChatListPalette.accessibleBlueText
    ) -> AttributedString {
        var attributed = AttributedString(source)
        attributed.foregroundColor = baseColor
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return attributed }

        var searchStart = source.startIndex
        while searchStart < source.endIndex,
              let range = source.range(
                  of: trimmed,
                  options: [.caseInsensitive, .diacriticInsensitive],
                  range: searchStart..<source.endIndex
              ) {
            if let attrStart = AttributedString.Index(range.lowerBound, within: attributed),
               let attrEnd = AttributedString.Index(range.upperBound, within: attributed) {
                attributed[attrStart..<attrEnd].foregroundColor = highlightColor
                attributed[attrStart..<attrEnd].inlinePresentationIntent = .stronglyEmphasized
            }
            searchStart = range.upperBound
        }
        return attributed
    }
}

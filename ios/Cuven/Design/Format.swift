import Foundation

enum Fmt {
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    private static let fullDate: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("yMMMd")
        return f
    }()

    private static let dayHeader: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEMMMd")
        return f
    }()

    private static let monthYear: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("yMMMM")
        return f
    }()

    /// As the conversation list shows it: 07:33, Yesterday, Mon, 12 Mar, 12 Mar 2024.
    static func listTime(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return clock(d) }
        if cal.isDateInYesterday(d) { return String(localized: "Yesterday") }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day, days < 7 {
            return weekday.string(from: d)
        }
        if cal.component(.year, from: d) == cal.component(.year, from: Date()) { return shortDate.string(from: d) }
        return fullDate.string(from: d)
    }

    /// The floating day between messages: Today 07:33, Yesterday 21:02, Monday 3 March 09:10.
    static func dayStamp(_ d: Date) -> String {
        let cal = Calendar.current
        let t = clock(d)
        if cal.isDateInToday(d) { return String(localized: "Today \(t)") }
        if cal.isDateInYesterday(d) { return String(localized: "Yesterday \(t)") }
        if cal.component(.year, from: d) == cal.component(.year, from: Date()) { return "\(dayHeader.string(from: d)) \(t)" }
        return "\(fullDate.string(from: d)) \(t)"
    }

    // MARK: time in a conversation (ui/chat-time.js)

    /// Five minutes of quiet start a new stretch.
    static let gap: Int = 5 * 60 * 1000

    private static func daysAgo(_ d: Date) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day ?? 0
    }

    private static let weekdayLong: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f
    }()

    private static let weekdayMonthDay: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return f
    }()

    private static let longDay: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return f
    }()

    /// A mark's day: Today · Yesterday · Thursday (this week) · Sat, Nov 7 · Nov 7, 2025.
    static func markDay(_ d: Date) -> String {
        let n = daysAgo(d)
        if n <= 0 { return String(localized: "Today") }
        if n == 1 { return String(localized: "Yesterday") }
        if n < 7 { return weekdayLong.string(from: d) }
        if Calendar.current.component(.year, from: d) == Calendar.current.component(.year, from: Date()) { return weekdayMonthDay.string(from: d) }
        return fullDate.string(from: d)
    }

    /// The date that floats while you scroll back.
    static func historyDate(_ d: Date) -> String {
        let n = daysAgo(d)
        if n <= 0 { return String(localized: "Today") }
        if n == 1 { return String(localized: "Yesterday") }
        return longDay.string(from: d)
    }

    /// When a message was sent, in full, for the top of its menu.
    static func fullTime(_ d: Date) -> String {
        let n = daysAgo(d)
        let t = clock(d)
        if n <= 0 { return String(localized: "Today at \(t)") }
        if n == 1 { return String(localized: "Yesterday at \(t)") }
        return String(localized: "\(historyDate(d)) at \(t)")
    }

    /// A time said briefly after a word ("Read 10:28", "Read Yesterday").
    static func briefly(_ d: Date) -> String {
        let n = daysAgo(d)
        if n <= 0 { return clock(d) }
        if n == 1 { return String(localized: "Yesterday") }
        if n < 7 { return weekdayLong.string(from: d) }
        return shortDate.string(from: d)
    }

    private static let h12: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f
    }()

    private static let h24: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// 09:41, or 9:41 AM: the device's way unless Settings › Time format says.
    static func clock(_ d: Date) -> String {
        switch UserDefaults.standard.string(forKey: "ui:time-format") {
        case "12": return h12.string(from: d)
        case "24": return h24.string(from: d)
        default: return time.string(from: d)
        }
    }
    static func month(_ d: Date) -> String { monthYear.string(from: d) }
    static func date(_ d: Date) -> String { fullDate.string(from: d) }

    static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        if Date().timeIntervalSince(d) < 60 { return String(localized: "Just now") }
        return f.localizedString(for: d, relativeTo: Date())
    }

    static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func fileSize(_ bytes: Double?) -> String {
        guard let bytes else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// One to three emoji and nothing else: shown large, without a bubble.
    static func isJumboEmoji(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 3 else { return false }
        return t.unicodeScalars.allSatisfy { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x238C || $0.value == 0x200D || $0.value == 0xFE0F }
    }
}

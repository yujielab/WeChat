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
        if cal.isDateInToday(d) { return time.string(from: d) }
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
        let t = time.string(from: d)
        if cal.isDateInToday(d) { return String(localized: "Today \(t)") }
        if cal.isDateInYesterday(d) { return String(localized: "Yesterday \(t)") }
        if cal.component(.year, from: d) == cal.component(.year, from: Date()) { return "\(dayHeader.string(from: d)) \(t)" }
        return "\(fullDate.string(from: d)) \(t)"
    }

    static func clock(_ d: Date) -> String { time.string(from: d) }
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

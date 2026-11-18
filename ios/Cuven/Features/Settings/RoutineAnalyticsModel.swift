import CuvenCore
import Foundation

/// Half-open `[startHour, endHour)` span on the 24-hour clock (may wrap across midnight when `startHour > endHour`).
public struct RoutineHourSpan: Codable, Equatable, Hashable, Sendable {
    public let startHour: Int
    public let endHour: Int

    public init(startHour: Int, endHour: Int) {
        self.startHour = startHour
        self.endHour = endHour
    }
}

/// Summary of a user's 24-hour activity rhythm and long-term AI writing memory.
///
/// Grounded in:
/// - Cuven Web Reference: `src/routine.js`, `src/memory.js`, `public/js/views/memory-model.js`, `public/js/views/memory.js`
/// - Apple HIG: *Charting Data* & *Privacy* (transparent, user-owned usage visualization with 1-tap clear)
public struct RoutineSummaryMetrics: Equatable, Sendable {
    public let normalizedBuckets: [AIRoutineHourBucket] // Always 24 buckets (0..<24), clamped 0...1
    public let peakThreeHourWindow: RoutineHourSpan?
    public let quietHourWindow: RoutineHourSpan?
    public let peakCalloutText: String?
    public let quietCalloutText: String?
    public let confidenceLabel: String
    public let activeHoursCount: Int
    public let currentHour: Int

    public func isHourInPeak(_ hour: Int) -> Bool {
        guard let peak = peakThreeHourWindow else { return false }
        return RoutineAnalyticsModel.isHour(hour, withinSpanFrom: peak.startHour, to: peak.endHour)
    }

    public func isHourInQuiet(_ hour: Int) -> Bool {
        guard let quiet = quietHourWindow else { return false }
        return RoutineAnalyticsModel.isHour(hour, withinSpanFrom: quiet.startHour, to: quiet.endHour)
    }
}

public struct AIMemoryCategoryGroup: Identifiable, Equatable, Sendable {
    public var id: String { key }
    public let key: String
    public let title: String
    public let subtitle: String
    public let items: [AIMemoryItem]
    public let rendersAsChips: Bool
}

public enum RoutineAnalyticsModel: Sendable {
    /// Normalizes arbitrary `AIRoutineHourBucket` arrays into a dense 24-hour (`0..<24`) sequence
    /// scaled into `0.0...1.0`, then derives peak 3-hour window and quiet rest stretch (`routine.js:250-273`).
    public static func summarize(
        buckets: [AIRoutineHourBucket],
        routineLearningEnabled: Bool,
        use24HourTime: Bool,
        currentHour: Int = Calendar.current.component(.hour, from: Date())
    ) -> RoutineSummaryMetrics {
        var scoresByHour = Array(repeating: 0.0, count: 24)
        for bucket in buckets where (0..<24).contains(bucket.hour) {
            if bucket.activityScore.isFinite {
                scoresByHour[bucket.hour] = max(scoresByHour[bucket.hour], max(0.0, bucket.activityScore))
            }
        }

        let maxScore = scoresByHour.max() ?? 0.0
        let normalizedScores: [Double] = scoresByHour.map { raw in
            guard maxScore > 0 else { return 0.0 }
            return min(1.0, max(0.0, (raw / maxScore * 100.0).rounded() / 100.0))
        }

        let normalizedBuckets = (0..<24).map { hr in
            AIRoutineHourBucket(hour: hr, activityScore: normalizedScores[hr])
        }

        let activeHoursCount = normalizedScores.filter { $0 > 0.05 }.count

        guard routineLearningEnabled, maxScore > 0 else {
            return RoutineSummaryMetrics(
                normalizedBuckets: normalizedBuckets.map {
                    AIRoutineHourBucket(hour: $0.hour, activityScore: routineLearningEnabled ? $0.activityScore : 0.0)
                },
                peakThreeHourWindow: nil,
                quietHourWindow: nil,
                peakCalloutText: nil,
                quietCalloutText: nil,
                confidenceLabel: routineLearningEnabled ? "Still getting to know you" : "Learning paused",
                activeHoursCount: 0,
                currentHour: ((currentHour % 24) + 24) % 24
            )
        }

        // Busiest 3-hour rolling window (`routine.js:254-261`)
        var peakWindow: RoutineHourSpan?
        if activeHoursCount >= 2 {
            var bestSum = -1.0
            for h in 0..<24 {
                let sum3 = normalizedScores[h] + normalizedScores[(h + 1) % 24] + normalizedScores[(h + 2) % 24]
                if sum3 > bestSum {
                    bestSum = sum3
                    peakWindow = RoutineHourSpan(startHour: h, endHour: (h + 3) % 24)
                }
            }
        }

        // Longest stretch of quiet hours (`<= 10%` of top for `>= 3` hours, `routine.js:262-273`)
        var quietWindow: RoutineHourSpan?
        let isLow = normalizedScores.map { $0 <= 0.10 }
        var bestQuietLen = 0
        for h in 0..<24 {
            if !isLow[h] || isLow[(h + 23) % 24] { continue }
            var length = 0
            while length < 24 && isLow[(h + length) % 24] {
                length += 1
            }
            if length > bestQuietLen {
                bestQuietLen = length
                quietWindow = RoutineHourSpan(startHour: h, endHour: (h + length) % 24)
            }
        }
        if bestQuietLen < 3 || bestQuietLen >= 24 {
            quietWindow = nil
        }

        let confidence: String
        if activeHoursCount >= 12 {
            confidence = "Knows it well"
        } else if activeHoursCount >= 6 {
            confidence = "Knows some of your routine"
        } else if activeHoursCount >= 2 {
            confidence = "Starting to know you"
        } else {
            confidence = "Still getting to know you"
        }

        let peakText = peakWindow.map {
            "Most active \(formatHourSpan(startHour: $0.startHour, endHour: $0.endHour, use24HourTime: use24HourTime))"
        }
        let quietText = quietWindow.map {
            "Rarely online \(formatHourSpan(startHour: $0.startHour, endHour: $0.endHour, use24HourTime: use24HourTime))"
        }

        return RoutineSummaryMetrics(
            normalizedBuckets: normalizedBuckets,
            peakThreeHourWindow: peakWindow,
            quietHourWindow: quietWindow,
            peakCalloutText: peakText,
            quietCalloutText: quietText,
            confidenceLabel: confidence,
            activeHoursCount: activeHoursCount,
            currentHour: ((currentHour % 24) + 24) % 24
        )
    }

    /// Checks whether `hour` falls inside `[start, end)` which may wrap past midnight (`memory-model.js:131-133`).
    public static func isHour(_ hour: Int, withinSpanFrom start: Int, to end: Int) -> Bool {
        let hr = ((hour % 24) + 24) % 24
        if start <= end {
            return hr >= start && hr < end
        } else {
            return hr >= start || hr < end
        }
    }

    public static func formatHour(_ hour: Int, use24HourTime: Bool) -> String {
        let normalized = ((hour % 24) + 24) % 24
        if use24HourTime {
            return String(format: "%02d:00", normalized)
        }
        let period = normalized >= 12 ? "PM" : "AM"
        let h12 = normalized % 12 == 0 ? 12 : normalized % 12
        return "\(h12) \(period)"
    }

    public static func formatHourSpan(startHour: Int, endHour: Int, use24HourTime: Bool) -> String {
        if use24HourTime {
            let endDisplay = endHour == 0 ? "24:00" : String(format: "%02d:00", ((endHour % 24) + 24) % 24)
            return "\(String(format: "%02d:00", ((startHour % 24) + 24) % 24))–\(endDisplay)"
        }
        return "\(formatHour(startHour, use24HourTime: false))–\(formatHour(endHour, use24HourTime: false))"
    }

    /// Relative human-readable timestamp matching `memory-model.js:29-38`.
    public static func relativeTimeString(
        fromEpochMillis timestampMillis: Int64,
        nowMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> String {
        guard timestampMillis > 0 else { return "" }
        // Accept both seconds and milliseconds gracefully
        let normalizedTS = timestampMillis < 10_000_000_000 ? timestampMillis * 1000 : timestampMillis
        let diff = max(0, nowMillis - normalizedTS)
        let minute: Int64 = 60_000
        let hour: Int64 = 3_600_000
        let day: Int64 = 86_400_000
        if diff < minute { return "Just now" }
        if diff < hour { return "\(diff / minute) min ago" }
        if diff < day { return "\(diff / hour) hr ago" }
        if diff < 30 * day { return "\(diff / day) days ago" }
        let date = Date(timeIntervalSince1970: TimeInterval(normalizedTS) / 1000.0)
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Groups `AIMemoryItem` entries into Cuven's 3-layer memory presentation (`Your words`, `Phrase endings`, `Conversation digests`, & `Habits / Facts`).
    public static func groupMemories(_ memories: [AIMemoryItem]) -> [AIMemoryCategoryGroup] {
        guard !memories.isEmpty else { return [] }

        var styleWords: [AIMemoryItem] = []
        var endings: [AIMemoryItem] = []
        var digests: [AIMemoryItem] = []
        var habitsAndFacts: [AIMemoryItem] = []

        for item in memories {
            let cat = item.category.lowercased()
            if cat.contains("word") || cat.contains("style") || cat.contains("vocab") {
                styleWords.append(item)
            } else if cat.contains("end") || cat.contains("phrase") || cat.contains("tone") {
                endings.append(item)
            } else if cat.contains("digest") || cat.contains("chat") || cat.contains("thread") || cat.contains("summary") {
                digests.append(item)
            } else {
                habitsAndFacts.append(item)
            }
        }

        var groups: [AIMemoryCategoryGroup] = []
        if !styleWords.isEmpty {
            groups.append(AIMemoryCategoryGroup(
                key: "words",
                title: "Your words",
                subtitle: "Recurring phrases across chats",
                items: styleWords,
                rendersAsChips: true
            ))
        }
        if !endings.isEmpty {
            groups.append(AIMemoryCategoryGroup(
                key: "endings",
                title: "How you often phrase things",
                subtitle: "Habitual sentence cadences",
                items: endings,
                rendersAsChips: true
            ))
        }
        if !habitsAndFacts.isEmpty {
            groups.append(AIMemoryCategoryGroup(
                key: "habits",
                title: "Learned habits & preferences",
                subtitle: "Derived solely from your own usage",
                items: habitsAndFacts,
                rendersAsChips: false
            ))
        }
        if !digests.isEmpty {
            groups.append(AIMemoryCategoryGroup(
                key: "digests",
                title: "Earlier in each chat",
                subtitle: "Scoped strictly per conversation",
                items: digests,
                rendersAsChips: false
            ))
        }
        return groups
    }
}

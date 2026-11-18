import Foundation
import CoreGraphics
import CuvenCore

// MARK: - Timestamp & Formatting Utilities

public enum ThreadTimeFormatter {
    /// Normalizes backend epoch timestamps whether stored in milliseconds (`Date.now()`) or seconds.
    public static func date(from rawTimestamp: Int64) -> Date {
        if rawTimestamp > 10_000_000_000 {
            return Date(timeIntervalSince1970: TimeInterval(rawTimestamp) / 1000.0)
        } else {
            return Date(timeIntervalSince1970: TimeInterval(rawTimestamp))
        }
    }

    public static func clockString(from rawTimestamp: Int64, use24Hour: Bool, calendar: Calendar = .current) -> String {
        let date = Self.date(from: rawTimestamp)
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0

        if use24Hour {
            return String(format: "%02d:%02d", hour, minute)
        } else {
            let period = hour >= 12 ? "PM" : "AM"
            let hour12 = hour % 12 == 0 ? 12 : hour % 12
            return String(format: "%d:%02d %@", hour12, minute, period)
        }
    }

    /// Formats conversation stretch marks (`"Today 09:41"`, `"Yesterday 18:20"`, or `"10:26"` within the same day).
    public static func separatorMark(
        from rawTimestamp: Int64,
        opensNewDay: Bool,
        use24Hour: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let target = date(from: rawTimestamp)
        let clock = clockString(from: rawTimestamp, use24Hour: use24Hour, calendar: calendar)
        guard opensNewDay else { return clock }

        if calendar.isDateInToday(target) {
            return "Today \(clock)"
        } else if calendar.isDateInYesterday(target) {
            return "Yesterday \(clock)"
        } else {
            let formatter = DateFormatter()
            let sameYear = calendar.component(.year, from: target) == calendar.component(.year, from: now)
            formatter.dateFormat = sameYear ? "EEE, MMM d" : "MMM d, yyyy"
            return "\(formatter.string(from: target)) \(clock)"
        }
    }

    public static func fullContextTimestamp(
        from rawTimestamp: Int64,
        editHistory: [MessageEditEntry],
        editCount: Int,
        use24Hour: Bool,
        calendar: Calendar = .current
    ) -> String {
        let sentText = separatorMark(from: rawTimestamp, opensNewDay: true, use24Hour: use24Hour, calendar: calendar)
        if editCount > 0 {
            if let lastEdit = editHistory.last {
                let editedClock = clockString(from: lastEdit.editedAt, use24Hour: use24Hour, calendar: calendar)
                return "\(sentText) · Edited \(editedClock)"
            }
            return "\(sentText) · Edited (\(editCount)/\(MessageEditRules.maxEdits))"
        }
        return sentText
    }

    public static func historyFloatingDate(from rawTimestamp: Int64, now: Date = Date(), calendar: Calendar = .current) -> String {
        let target = date(from: rawTimestamp)
        if calendar.isDateInToday(target) {
            return "Today"
        } else if calendar.isDateInYesterday(target) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            let sameYear = calendar.component(.year, from: target) == calendar.component(.year, from: now)
            formatter.dateFormat = sameYear ? "EEEE, MMM d" : "MMM d, yyyy"
            return formatter.string(from: target)
        }
    }

    public static func durationString(seconds: Double) -> String {
        let clamped = max(1, Int(seconds.rounded()))
        let mins = clamped / 60
        let secs = clamped % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Edit & Revoke Governance Rules (src/store.js editProblem parity)

public enum MessageEditEligibility: Equatable, Sendable {
    case editable(remainingEdits: Int)
    case limitReached
    case windowExpired
    case notApplicable
}

public enum MessageEditRules {
    /// Sender can rewrite their own text message within 15 minutes (`src/store.js:14-26`).
    public static let editWindowSeconds: TimeInterval = 15 * 60
    /// At most 5 edits per message (`src/store.js:14-26`).
    public static let maxEdits: Int = 5

    public static func eligibility(
        for message: Message,
        currentUserID: String?,
        now: Date = Date()
    ) -> MessageEditEligibility {
        guard let currentUserID,
              message.senderID == currentUserID,
              message.kind == .text,
              message.deliveryState != .revoked,
              message.deliveryState != .sending,
              message.deliveryState != .queued,
              message.deliveryState != .failed
        else {
            return .notApplicable
        }

        if message.editCount >= maxEdits {
            return .limitReached
        }

        let createdDate = ThreadTimeFormatter.date(from: message.createdAt)
        let age = now.timeIntervalSince(createdDate)
        if age > editWindowSeconds {
            return .windowExpired
        }

        return .editable(remainingEdits: max(0, maxEdits - message.editCount))
    }

    public static func canEdit(message: Message, currentUserID: String?, now: Date = Date()) -> Bool {
        if case .editable = eligibility(for: message, currentUserID: currentUserID, now: now) {
            return true
        }
        return false
    }

    public static func canUnsend(message: Message, currentUserID: String?) -> Bool {
        guard let currentUserID else { return false }
        return message.senderID == currentUserID && message.deliveryState != .revoked
    }
}

// MARK: - Thread Display & Consecutive Sender Run Models

public struct MessageRunItem: Identifiable, Equatable, Sendable {
    public var id: String { message.id }
    public let message: Message
    public let isOutgoing: Bool
    public let isFirstInRun: Bool
    public let isLastInRun: Bool
    public let hasTail: Bool
    public let showGroupSenderName: Bool
    public let showGroupAvatar: Bool
    public let isLatestOutgoingStatusTarget: Bool

    public init(
        message: Message,
        isOutgoing: Bool,
        isFirstInRun: Bool,
        isLastInRun: Bool,
        hasTail: Bool,
        showGroupSenderName: Bool,
        showGroupAvatar: Bool,
        isLatestOutgoingStatusTarget: Bool
    ) {
        self.message = message
        self.isOutgoing = isOutgoing
        self.isFirstInRun = isFirstInRun
        self.isLastInRun = isLastInRun
        self.hasTail = hasTail
        self.showGroupSenderName = showGroupSenderName
        self.showGroupAvatar = showGroupAvatar
        self.isLatestOutgoingStatusTarget = isLatestOutgoingStatusTarget
    }
}

public enum ThreadDisplayItem: Identifiable, Equatable, Sendable {
    case timestampSeparator(id: String, label: String, rawTimestamp: Int64)
    case unreadDivider(count: Int)
    case systemNotice(id: String, text: String, rawTimestamp: Int64, isRevoked: Bool)
    case callGroup(id: String, messages: [Message], isOutgoing: Bool)
    case photoStack(
        id: String,
        messages: [Message],
        allMediaURLs: [String],
        isOutgoing: Bool,
        senderDisplay: String,
        senderID: String,
        isLatestOutgoingStatusTarget: Bool
    )
    case bubble(MessageRunItem)

    public var id: String {
        switch self {
        case .timestampSeparator(let id, _, _):
            return "sep-\(id)"
        case .unreadDivider:
            return "unread-divider"
        case .systemNotice(let id, _, _, _):
            return "sys-\(id)"
        case .callGroup(let id, _, _):
            return "calls-\(id)"
        case .photoStack(let id, _, _, _, _, _, _):
            return "stack-\(id)"
        case .bubble(let item):
            return item.id
        }
    }

    public var primaryMessage: Message? {
        switch self {
        case .timestampSeparator, .unreadDivider, .systemNotice:
            return nil
        case .callGroup(_, let messages, _):
            return messages.last
        case .photoStack(_, let messages, _, _, _, _, _):
            return messages.last
        case .bubble(let item):
            return item.message
        }
    }
}

public enum ThreadGroupingEngine {
    /// Five-minute stretch threshold matching `public/js/views/thread.js` (`TS_GAP = 5 * 60 * 1000`).
    public static let stretchGapSeconds: TimeInterval = 5 * 60
    /// Adjacent photos sent within 60s by the same person form a 3D `PhotoStackFanView` (`thread.js:833`).
    public static let photoStackWindowSeconds: TimeInterval = 60
    /// Consecutive unanswered calls within 60m fold into an expandable call log group (`thread.js:701`).
    public static let callGroupWindowSeconds: TimeInterval = 60 * 60

    public static func buildDisplayItems(
        messages: [Message],
        currentUserID: String?,
        roomKind: RoomKind,
        unreadCount: Int,
        use24HourTime: Bool,
        expandedPhotoStackIDs: Set<String> = [],
        calendar: Calendar = .current
    ) -> [ThreadDisplayItem] {
        guard !messages.isEmpty else { return [] }

        let ordered = messages.enumerated().sorted { lhs, rhs in
            let lDate = ThreadTimeFormatter.date(from: lhs.element.createdAt)
            let rDate = ThreadTimeFormatter.date(from: rhs.element.createdAt)
            if lDate == rDate {
                return lhs.offset < rhs.offset
            }
            return lDate < rDate
        }.map(\.element)

        // Identify the first unread incoming message if unreadCount > 0
        var firstUnreadMessageID: String?
        if unreadCount > 0 {
            let incomingCandidates = ordered.filter { msg in
                !isOutgoing(msg, currentUserID: currentUserID)
                    && msg.kind != .system
                    && msg.deliveryState != .revoked
            }
            if !incomingCandidates.isEmpty {
                let targetIndex = max(0, incomingCandidates.count - unreadCount)
                firstUnreadMessageID = incomingCandidates[targetIndex].id
            }
        }

        // Identify the latest non-system outgoing message for delivery/read receipt line
        let nonSystemMessages = ordered.filter { !isSystemLike($0) }
        let latestNonSystem = nonSystemMessages.last
        let latestOutgoingID: String? = {
            if let lastOut = nonSystemMessages.last(where: { isOutgoing($0, currentUserID: currentUserID) }) {
                if lastOut.deliveryState == .sending
                    || lastOut.deliveryState == .queued
                    || lastOut.deliveryState == .failed
                    || latestNonSystem?.id == lastOut.id
                {
                    return lastOut.id
                }
            }
            return nil
        }()

        // Step 1: Collapse multi-photo runs & consecutive missed-call runs into logical entries
        enum LogicalEntry {
            case system(Message)
            case callGroup([Message])
            case photoStack([Message], [String])
            case single(Message)

            var firstMessage: Message {
                switch self {
                case .system(let m), .single(let m): return m
                case .callGroup(let list), .photoStack(let list, _): return list[0]
                }
            }

            var lastMessage: Message {
                switch self {
                case .system(let m), .single(let m): return m
                case .callGroup(let list), .photoStack(let list, _): return list[list.count - 1]
                }
            }

            func contains(messageID: String) -> Bool {
                switch self {
                case .system(let m), .single(let m):
                    return m.id == messageID
                case .callGroup(let list), .photoStack(let list, _):
                    return list.contains(where: { $0.id == messageID })
                }
            }
        }

        var logicalEntries: [LogicalEntry] = []
        var index = 0
        while index < ordered.count {
            let current = ordered[index]

            if isSystemLike(current) {
                logicalEntries.append(.system(current))
                index += 1
                continue
            }

            // Single Message carrying multiple mediaURLs as a PhotoStack (unless expanded)
            if current.kind == .image,
               current.mediaURLs.count > 1,
               !expandedPhotoStackIDs.contains(current.id)
            {
                logicalEntries.append(.photoStack([current], current.mediaURLs))
                index += 1
                continue
            }

            // Consecutive single-image messages from same sender within 60s -> PhotoStack
            if isGroupablePhotoMessage(current, expandedIDs: expandedPhotoStackIDs) {
                var photoRun: [Message] = [current]
                var cursor = index + 1
                while photoRun.count < 10 && cursor < ordered.count {
                    let candidate = ordered[cursor]
                    let prevPhoto = photoRun[photoRun.count - 1]
                    let dt = ThreadTimeFormatter.date(from: candidate.createdAt)
                        .timeIntervalSince(ThreadTimeFormatter.date(from: prevPhoto.createdAt))
                    if isGroupablePhotoMessage(candidate, expandedIDs: expandedPhotoStackIDs),
                       candidate.senderID == current.senderID,
                       dt <= photoStackWindowSeconds
                    {
                        photoRun.append(candidate)
                        cursor += 1
                    } else {
                        break
                    }
                }
                if photoRun.count > 1 {
                    let urls = photoRun.flatMap(\.mediaURLs)
                    let stackKey = photoRun[photoRun.count - 1].id
                    if !expandedPhotoStackIDs.contains(stackKey) && urls.count > 1 {
                        logicalEntries.append(.photoStack(photoRun, urls))
                        index = cursor
                        continue
                    }
                }
            }

            // Consecutive missed/unanswered call messages within 60m -> CallGroup
            if isGroupableMissedCall(current) {
                var callRun: [Message] = [current]
                var cursor = index + 1
                while callRun.count < 20 && cursor < ordered.count {
                    let candidate = ordered[cursor]
                    let prevCall = callRun[callRun.count - 1]
                    let stepGap = ThreadTimeFormatter.date(from: candidate.createdAt)
                        .timeIntervalSince(ThreadTimeFormatter.date(from: prevCall.createdAt))
                    let spanGap = ThreadTimeFormatter.date(from: candidate.createdAt)
                        .timeIntervalSince(ThreadTimeFormatter.date(from: current.createdAt))
                    if isGroupableMissedCall(candidate),
                       isOutgoing(candidate, currentUserID: currentUserID) == isOutgoing(current, currentUserID: currentUserID),
                       stepGap <= stretchGapSeconds,
                       spanGap <= callGroupWindowSeconds
                    {
                        callRun.append(candidate)
                        cursor += 1
                    } else {
                        break
                    }
                }
                if callRun.count > 1 {
                    logicalEntries.append(.callGroup(callRun))
                    index = cursor
                    continue
                }
            }

            // Expanded multi-URL single message splits into virtual per-photo bubbles
            if current.kind == .image,
               current.mediaURLs.count > 1,
               expandedPhotoStackIDs.contains(current.id)
            {
                for (photoIndex, url) in current.mediaURLs.enumerated() {
                    var copy = current
                    copy.id = "\(current.id)#photo-\(photoIndex)"
                    copy.mediaURLs = [url]
                    if photoIndex > 0 {
                        copy.text = ""
                        copy.replyToMessageID = nil
                    }
                    logicalEntries.append(.single(copy))
                }
                index += 1
                continue
            }

            logicalEntries.append(.single(current))
            index += 1
        }

        // Step 2: Emit timestamp separators, unread divider, and run-decorated display items
        var output: [ThreadDisplayItem] = []
        var unreadInserted = false

        for i in 0..<logicalEntries.count {
            let entry = logicalEntries[i]
            let prevEntry: LogicalEntry? = i > 0 ? logicalEntries[i - 1] : nil
            let nextEntry: LogicalEntry? = (i + 1 < logicalEntries.count) ? logicalEntries[i + 1] : nil

            let firstMsg = entry.firstMessage
            let prevLastMsg = prevEntry?.lastMessage

            let needsTimeSep = shouldInsertTimestampMark(before: firstMsg, after: prevLastMsg, calendar: calendar)
            if needsTimeSep {
                let opensDay = shouldOpenNewDay(before: firstMsg, after: prevLastMsg, calendar: calendar)
                let label = ThreadTimeFormatter.separatorMark(
                    from: firstMsg.createdAt,
                    opensNewDay: opensDay,
                    use24Hour: use24HourTime,
                    calendar: calendar
                )
                output.append(.timestampSeparator(id: firstMsg.id, label: label, rawTimestamp: firstMsg.createdAt))
            }

            if !unreadInserted,
               let firstUnreadMessageID,
               entry.contains(messageID: firstUnreadMessageID)
            {
                output.append(.unreadDivider(count: unreadCount))
                unreadInserted = true
            }

            switch entry {
            case .system(let msg):
                let outgoing = isOutgoing(msg, currentUserID: currentUserID)
                let text: String
                if msg.deliveryState == .revoked {
                    let who = outgoing ? "You" : (msg.senderDisplay.isEmpty ? "They" : msg.senderDisplay)
                    text = "\(who) unsent a message"
                } else {
                    text = msg.text
                }
                output.append(.systemNotice(
                    id: msg.id,
                    text: text,
                    rawTimestamp: msg.createdAt,
                    isRevoked: msg.deliveryState == .revoked
                ))

            case .callGroup(let calls):
                let outgoing = isOutgoing(calls[calls.count - 1], currentUserID: currentUserID)
                output.append(.callGroup(id: calls[0].id, messages: calls, isOutgoing: outgoing))

            case .photoStack(let photos, let urls):
                let last = photos[photos.count - 1]
                let outgoing = isOutgoing(last, currentUserID: currentUserID)
                let isStatusTarget = latestOutgoingID != nil && photos.contains(where: { $0.id == latestOutgoingID })
                output.append(.photoStack(
                    id: last.id,
                    messages: photos,
                    allMediaURLs: urls,
                    isOutgoing: outgoing,
                    senderDisplay: outgoing ? "You" : (last.senderDisplay.isEmpty ? "Friend" : last.senderDisplay),
                    senderID: last.senderID,
                    isLatestOutgoingStatusTarget: isStatusTarget
                ))

            case .single(let msg):
                let outgoing = isOutgoing(msg, currentUserID: currentUserID)
                let sepAfter: Bool = {
                    guard let nextFirst = nextEntry?.firstMessage else { return true }
                    return shouldInsertTimestampMark(before: nextFirst, after: msg, calendar: calendar)
                }()

                let continuesFromPrev: Bool = {
                    guard !needsTimeSep, let prevEntry else { return false }
                    guard case .single(let prevMsg) = prevEntry else { return false }
                    return isSameSenderRun(prevMsg, msg, currentUserID: currentUserID)
                }()

                let continuesToNext: Bool = {
                    guard !sepAfter, let nextEntry else { return false }
                    guard case .single(let nextMsg) = nextEntry else { return false }
                    return isSameSenderRun(msg, nextMsg, currentUserID: currentUserID)
                }()

                let isFirst = !continuesFromPrev
                let isLast = !continuesToNext
                let hasTail = isLast && bubbleUsesCurvedTail(msg)
                let showSenderName = roomKind == .group && !outgoing && isFirst && msg.kind != .call
                let showAvatar = roomKind == .group && !outgoing && isLast && msg.kind != .call
                let baseID = msg.id.components(separatedBy: "#photo-").first ?? msg.id
                let isStatusTarget = (latestOutgoingID == baseID) && isLast

                output.append(.bubble(MessageRunItem(
                    message: msg,
                    isOutgoing: outgoing,
                    isFirstInRun: isFirst,
                    isLastInRun: isLast,
                    hasTail: hasTail,
                    showGroupSenderName: showSenderName,
                    showGroupAvatar: showAvatar,
                    isLatestOutgoingStatusTarget: isStatusTarget
                )))
            }
        }

        return output
    }

    // MARK: - Classification Helpers

    public static func isOutgoing(_ message: Message, currentUserID: String?) -> Bool {
        guard let currentUserID, !currentUserID.isEmpty else {
            return message.senderID == "me" || message.senderID == "tokio"
        }
        return message.senderID == currentUserID
    }

    public static func isSystemLike(_ message: Message) -> Bool {
        message.kind == .system || message.deliveryState == .revoked
    }

    public static func bubbleUsesCurvedTail(_ message: Message) -> Bool {
        switch message.kind {
        case .text:
            return !isJumboEmojiOnly(message.text)
        case .voice:
            return true
        case .image, .drawing, .sticker, .video, .file, .call, .system:
            return false
        }
    }

    public static func isJumboEmojiOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 3 else { return false }
        return trimmed.allSatisfy { character in
            character.unicodeScalars.contains { scalar in
                scalar.properties.isEmojiPresentation
                    || (scalar.properties.isEmoji && scalar.value > 0x238C)
            }
        }
    }

    public static func quotePreviewText(for target: Message?) -> String {
        guard let target else { return "Original message unavailable" }
        if target.deliveryState == .revoked {
            return "Original message was unsent"
        }
        switch target.kind {
        case .image:
            return target.mediaURLs.count > 1 ? "[\(target.mediaURLs.count) Photos]" : "[Photo]"
        case .drawing:
            return "[Drawing]"
        case .sticker:
            return target.text.isEmpty ? "[Sticker]" : "[Sticker] \(target.text)"
        case .voice:
            if let dur = target.durationSeconds, dur > 0 {
                return "[Voice \(ThreadTimeFormatter.durationString(seconds: dur))]"
            }
            return "[Voice]"
        case .video:
            return "[Video]"
        case .file:
            return target.text.isEmpty ? "[File]" : "[File] \(target.text)"
        case .call:
            return target.text.isEmpty ? "[Call]" : target.text
        case .system:
            return target.text
        case .text:
            return target.text.replacingOccurrences(of: "\n", with: " ")
        }
    }

    public static func mediaDisplaySize(
        width: Int?,
        height: Int?,
        maxWidth: CGFloat,
        maxHeight: CGFloat = 300
    ) -> CGSize {
        let clampedMaxW = max(120, maxWidth)
        guard let width, let height, width > 0, height > 0 else {
            let side = round(min(clampedMaxW * 0.78, 224))
            return CGSize(width: side, height: round(side * 0.78))
        }
        let w = CGFloat(width)
        let h = CGFloat(height)
        let scale = min(clampedMaxW / w, maxHeight / h, 1.0)
        var outW = round(w * scale)
        var outH = round(h * scale)
        if outW < 104 {
            outH = round(outH * (104.0 / max(1, outW)))
            outW = 104
        }
        outH = max(76, min(outH, maxHeight))
        return CGSize(width: outW, height: outH)
    }

    // MARK: - Private Grouping Predicates

    private static func isGroupablePhotoMessage(_ message: Message, expandedIDs: Set<String>) -> Bool {
        message.kind == .image
            && !message.mediaURLs.isEmpty
            && message.replyToMessageID == nil
            && message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && message.deliveryState != .sending
            && message.deliveryState != .queued
            && message.deliveryState != .failed
            && message.deliveryState != .revoked
            && !expandedIDs.contains(message.id)
    }

    private static func isGroupableMissedCall(_ message: Message) -> Bool {
        guard message.kind == .call, message.deliveryState != .revoked else { return false }
        let lower = message.text.lowercased()
        return lower.contains("missed") || lower.contains("unanswered") || lower.contains("declined") || lower.contains("cancelled")
    }

    private static func shouldOpenNewDay(before current: Message, after previous: Message?, calendar: Calendar) -> Bool {
        guard let previous else { return true }
        let prevDate = ThreadTimeFormatter.date(from: previous.createdAt)
        let currDate = ThreadTimeFormatter.date(from: current.createdAt)
        return !calendar.isDate(prevDate, inSameDayAs: currDate)
    }

    private static func shouldInsertTimestampMark(before current: Message, after previous: Message?, calendar: Calendar) -> Bool {
        guard let previous else { return true }
        if shouldOpenNewDay(before: current, after: previous, calendar: calendar) {
            return true
        }
        let gap = ThreadTimeFormatter.date(from: current.createdAt)
            .timeIntervalSince(ThreadTimeFormatter.date(from: previous.createdAt))
        return gap >= stretchGapSeconds
    }

    private static func isSameSenderRun(_ lhs: Message, _ rhs: Message, currentUserID: String?) -> Bool {
        guard !isSystemLike(lhs), !isSystemLike(rhs),
              lhs.kind != .call, rhs.kind != .call
        else { return false }
        let sameDirection = isOutgoing(lhs, currentUserID: currentUserID) == isOutgoing(rhs, currentUserID: currentUserID)
        guard sameDirection, lhs.senderID == rhs.senderID else { return false }
        let gap = ThreadTimeFormatter.date(from: rhs.createdAt)
            .timeIntervalSince(ThreadTimeFormatter.date(from: lhs.createdAt))
        return gap < stretchGapSeconds
    }
}

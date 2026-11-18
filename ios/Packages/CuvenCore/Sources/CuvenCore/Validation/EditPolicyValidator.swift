import Foundation

// MARK: - Edit, Reaction & Note Policy Validator (Exact Port of src/store.js:11-26)

public enum EditValidationError: Equatable, Hashable, Error, LocalizedError, Sendable {
    case cannotEditMessage
    case emptyMessage
    case editWindowExpired
    case maxEditsReached(Int)

    public var errorDescription: String? {
        messageText
    }

    /// Matches `editProblem` verbatim strings from `src/store.js:20-26`.
    public var messageText: String {
        switch self {
        case .cannotEditMessage:
            return "Can't edit this message"
        case .emptyMessage:
            return "Can't change it to an empty message"
        case .editWindowExpired:
            return "Messages sent over 15 minutes ago can't be edited"
        case .maxEditsReached(let maxEdits):
            return "Each message can be edited at most \(maxEdits) times"
        }
    }
}

public enum EditPolicyValidator {
    /// 15 minutes in milliseconds (`src/store.js:14` `EDIT_WINDOW = 15 * 60 * 1000`).
    public static let editWindowMilliseconds: Int64 = 15 * 60 * 1000
    /// Maximum 5 edits per text message (`src/store.js:15` `EDIT_MAX = 5`).
    public static let maxEdits: Int = 5
    /// Canonical 6 tapback reactions (`src/store.js:12` `REACTIONS`).
    public static let allowedReactions: [String] = ["❤️", "😂", "👍", "😮", "😢", "🙏"]
    /// 24-hour Note TTL in milliseconds (`src/store.js:17` `NOTE_TTL`).
    public static let noteTTLMilliseconds: Int64 = 24 * 60 * 60 * 1000
    /// 60-character Note maximum (`src/store.js:18` `NOTE_MAX`).
    public static let noteMaxCharacters: Int = 60

    public static func validateEdit(
        message: Message,
        editorUserID: String,
        newText: String,
        nowMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> EditValidationError? {
        if message.senderID != editorUserID
            || message.kind != .text
            || message.deliveryState == .revoked {
            return .cannotEditMessage
        }
        if newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .emptyMessage
        }
        if nowMilliseconds - message.createdAt > editWindowMilliseconds {
            return .editWindowExpired
        }
        if message.editCount >= maxEdits {
            return .maxEditsReached(maxEdits)
        }
        return nil
    }

    public static func canEdit(
        message: Message,
        editorUserID: String,
        nowMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> Bool {
        if message.senderID != editorUserID
            || message.kind != .text
            || message.deliveryState == .revoked {
            return false
        }
        if nowMilliseconds - message.createdAt > editWindowMilliseconds {
            return false
        }
        return message.editCount < maxEdits
    }

    /// Returns empty string `""` when valid, or the exact server error message from `src/store.js:20-26`.
    public static func editProblem(
        message: Message?,
        editorUserID: String,
        newText: String,
        nowMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> String {
        guard let message else {
            return EditValidationError.cannotEditMessage.messageText
        }
        return validateEdit(
            message: message,
            editorUserID: editorUserID,
            newText: newText,
            nowMilliseconds: nowMilliseconds
        )?.messageText ?? ""
    }

    public static func isValidReaction(_ emoji: String) -> Bool {
        emoji.isEmpty || allowedReactions.contains(emoji)
    }

    /// Normalizes a 24h Note string identically to `src/hub.js:360` (collapsing whitespace, capping at 60 chars).
    public static func normalizeNoteText(_ raw: String) -> String {
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.count <= noteMaxCharacters {
            return collapsed
        }
        return String(collapsed.prefix(noteMaxCharacters))
    }

    public static func isNoteActive(
        _ note: UserNote,
        nowMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> Bool {
        nowMilliseconds - note.createdAt < noteTTLMilliseconds
    }
}

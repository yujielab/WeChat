import SwiftUI
import AppIntents
import CoreSpotlight
import UniformTypeIdentifiers
import TipKit

// The system around the app (Apple Developer Documentation): Siri and
// Shortcuts (App Intents), Spotlight (Core Spotlight), Handoff and
// suggestions (NSUserActivity), and tips for what's easy to miss (TipKit).

/// Where an intent, a Spotlight result or a notification wants to go,
/// held until the main view is there to take it.
enum PendingAction: Equatable {
    case search, newMoment, newGroup
}

@MainActor
enum PendingRoute {
    static var room: String?
    static var action: PendingAction?

    /// Hands what's waiting to the model once it exists.
    static func deliver(to model: AppModel) {
        if let room { model.pendingRoom = room; self.room = nil }
        if let action { model.pendingAction = action; self.action = nil }
    }

    static func open(room id: String) {
        if let model = AppDelegate.model { model.pendingRoom = id } else { room = id }
    }

    static func run(_ a: PendingAction) {
        if let model = AppDelegate.model { model.pendingAction = a } else { action = a }
    }
}

// MARK: - Siri and Shortcuts

/// A conversation, as Siri and Shortcuts see it: its name.
struct ChatEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Chat"
    static let defaultQuery = ChatQuery()
    var id: String
    var title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

/// Conversations from the app's last-known list (kept on the device by
/// ChatDirectory), so Siri can name them even before the app is open.
struct ChatQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ChatEntity] {
        ChatDirectory.load().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [ChatEntity] {
        let q = string.lowercased()
        return ChatDirectory.load().filter { $0.title.lowercased().contains(q) }
    }

    func suggestedEntities() async throws -> [ChatEntity] {
        Array(ChatDirectory.load().prefix(12))
    }
}

struct OpenChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Chat"
    static let description = IntentDescription("Opens a conversation in Cuven.")
    static let openAppWhenRun = true

    @Parameter(title: "Chat") var chat: ChatEntity

    init() {}
    init(chat: ChatEntity) { self.chat = chat }

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingRoute.open(room: chat.id)
        return .result()
    }
}

struct NewMomentIntent: AppIntent {
    static let title: LocalizedStringResource = "New Moment"
    static let description = IntentDescription("Starts a new moment to share with friends.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingRoute.run(.newMoment)
        return .result()
    }
}

struct SearchChatsIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Chats"
    static let description = IntentDescription("Searches your chats and contacts in Cuven.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingRoute.run(.search)
        return .result()
    }
}

/// Ready-made shortcuts, in Spotlight and Shortcuts and for Siri, with no setup.
struct CuvenShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenChatIntent(),
                    phrases: ["Open \(\.$chat) in \(.applicationName)", "Chat with \(\.$chat) in \(.applicationName)"],
                    shortTitle: "Open Chat", systemImageName: "bubble.left.and.bubble.right")
        AppShortcut(intent: NewMomentIntent(),
                    phrases: ["New moment in \(.applicationName)", "Share a moment in \(.applicationName)"],
                    shortTitle: "New Moment", systemImageName: "photo.on.rectangle")
        AppShortcut(intent: SearchChatsIntent(),
                    phrases: ["Search \(.applicationName)"],
                    shortTitle: "Search Chats", systemImageName: "magnifyingglass")
    }
}

// MARK: - Spotlight

/// Conversations in Spotlight (their names only: no message words leave the
/// app), and the short list Siri and Shortcuts pick from.
@MainActor
enum ChatDirectory {
    private static let key = "intents:chats"

    static func update(_ rooms: [Room]) {
        let list = rooms.prefix(200).map { ChatEntity(id: $0.id, title: $0.title) }
        if let data = try? JSONEncoder().encode(list.map { [$0.id, $0.title] }) {
            UserDefaults.standard.set(data, forKey: key)
        }
        let items = rooms.prefix(200).map { r -> CSSearchableItem in
            let a = CSSearchableItemAttributeSet(contentType: UTType.text)
            a.title = r.title
            a.contentDescription = r.isGroup ? String(localized: "Group chat") : String(localized: "Chat")
            if let u = r.peer?.username { a.keywords = [u, "@\(u)"] }
            return CSSearchableItem(uniqueIdentifier: r.id, domainIdentifier: "chats", attributeSet: a)
        }
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: ["chats"]) { _ in
            CSSearchableIndex.default().indexSearchableItems(Array(items)) { _ in }
        }
        CuvenShortcuts.updateAppShortcutParameters()
    }

    nonisolated static func load() -> [ChatEntity] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let pairs = try? JSONDecoder().decode([[String]].self, from: data) else { return [] }
        return pairs.compactMap { $0.count == 2 ? ChatEntity(id: $0[0], title: $0[1]) : nil }
    }

    /// Signed out: nothing of the account stays in Spotlight or Siri.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: ["chats"]) { _ in }
    }
}

/// The activity a conversation advertises while open (Handoff, suggestions).
enum ChatActivity {
    static let type = "us.cuven.app.chat"
}

// MARK: - Tips

/// Recording is hidden in a gesture: said once, in the system's own tip.
struct HoldToTalkTip: Tip {
    var title: Text { Text("Hold to record a voice message") }
    var message: Text? { Text("Touch and hold the empty message field. Let go to send, or slide up first to cancel.") }
    var image: Image? { Image(systemName: "waveform") }
    var options: [any TipOption] { [Tips.MaxDisplayCount(2)] }
}

enum CuvenTips {
    static func configure() {
        if Automation.active { Tips.hideAllTipsForTesting() }
        try? Tips.configure([.displayFrequency(.immediate)])
    }
}

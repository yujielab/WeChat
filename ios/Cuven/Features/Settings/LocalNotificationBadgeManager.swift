import CuvenCore
import Foundation
import Observation
import UserNotifications

/// Serializable local notification request model decoupling `LocalNotificationBadgeManager`
/// from `UNUserNotificationCenter` for deterministic unit testing in `CuvenTests`.
public struct PendingNotificationPayload: Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let subtitle: String
    public let body: String
    public let roomID: String
    public let messageID: String
    public let threadIdentifier: String

    public init(
        identifier: String,
        title: String,
        subtitle: String = "",
        body: String,
        roomID: String,
        messageID: String,
        threadIdentifier: String
    ) {
        self.identifier = identifier
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.roomID = roomID
        self.messageID = messageID
        self.threadIdentifier = threadIdentifier
    }
}

/// Abstraction over `UNUserNotificationCenter` enabling deterministic unit tests without triggering system dialogs.
public protocol UserNotificationCenterBackend: Sendable {
    func fetchAuthorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func addNotification(_ payload: PendingNotificationPayload) async throws
    func setBadgeCount(_ count: Int) async throws
    func removeDeliveredNotifications(forRoomID roomID: String) async
}

/// Production backend backed by Apple's `UNUserNotificationCenter.current()` (`iOS 27.1 SDK`).
/// Uses callback continuations so non-`Sendable` Objective-C `UNNotification` / `UNNotificationSettings`
/// objects remain strictly inside their callback queue and never cross Swift 6 actor boundaries.
public struct SystemUserNotificationCenterBackend: UserNotificationCenterBackend {
    public init() {}

    public func fetchAuthorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    public func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: options)
    }

    public func addNotification(_ payload: PendingNotificationPayload) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let content = UNMutableNotificationContent()
            content.title = payload.title
            if !payload.subtitle.isEmpty {
                content.subtitle = payload.subtitle
            }
            content.body = payload.body
            content.sound = .default
            content.threadIdentifier = payload.threadIdentifier
            content.userInfo = [
                "roomID": payload.roomID,
                "messageID": payload.messageID
            ]
            content.interruptionLevel = .active

            let request = UNNotificationRequest(
                identifier: payload.identifier,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public func setBadgeCount(_ count: Int) async throws {
        try await UNUserNotificationCenter.current().setBadgeCount(max(0, count))
    }

    public func removeDeliveredNotifications(forRoomID roomID: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let center = UNUserNotificationCenter.current()
            center.getDeliveredNotifications { delivered in
                let matchingIDs = delivered.compactMap { item -> String? in
                    let infoRoom = item.request.content.userInfo["roomID"] as? String
                    return (infoRoom == roomID || item.request.content.threadIdentifier == roomID)
                        ? item.request.identifier
                        : nil
                }
                if !matchingIDs.isEmpty {
                    center.removeDeliveredNotifications(withIdentifiers: matchingIDs)
                }
                continuation.resume()
            }
        }
    }
}

/// Non-actor-isolated Objective-C delegate relay preventing `@MainActor` / `@Observable` witness conflicts under Swift 6.
private final class NotificationCenterDelegateRelay: NSObject, UNUserNotificationCenterDelegate, Sendable {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let roomID = response.notification.request.content.userInfo["roomID"] as? String
        if let roomID {
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: LocalNotificationBadgeManager.didSelectRoomNotification,
                    object: nil,
                    userInfo: ["roomID": roomID]
                )
            }
        }
        completionHandler()
    }
}

/// Manages `UNUserNotificationCenter` authorization, foreground/background local notifications,
/// and unread app-icon badge synchronization (`UNUserNotificationCenter.setBadgeCount`).
///
/// Grounded in:
/// - Apple HIG: *Notifications* & *App Icons* (accurate unread badges, muted-thread respect, non-intrusive active-thread suppression)
/// - Apple Developer Documentation: `UserNotifications` (`UNUserNotificationCenter.setBadgeCount(_:)`, `UNUserNotificationCenterDelegate`)
/// - Cuven Web Reference: `public/js/ui/push.js`, `public/js/views/banner.js`, `design-qa.md:240-244`
@MainActor
@Observable
public final class LocalNotificationBadgeManager {
    public static let shared = LocalNotificationBadgeManager(registerAsDelegate: true)

    /// Posted on `NotificationCenter.default` when the user taps a delivered notification (`userInfo["roomID"]`).
    public static let didSelectRoomNotification = Notification.Name("CuvenDidSelectRoomFromNotification")

    private let backend: any UserNotificationCenterBackend
    private let delegateRelay = NotificationCenterDelegateRelay()

    public private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    public private(set) var lastSyncedBadgeCount: Int = 0
    public private(set) var lastErrorMessage: String?
    public var inAppNotificationsEnabled: Bool = true

    public var isAuthorized: Bool {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    public var statusDescription: String {
        switch authorizationStatus {
        case .authorized:
            return inAppNotificationsEnabled ? "Active" : "Paused in Cuven"
        case .provisional:
            return "Quiet delivery"
        case .ephemeral:
            return "Ephemeral"
        case .denied:
            return "Disabled in iOS Settings"
        case .notDetermined:
            return "Not yet enabled"
        @unknown default:
            return "Unknown"
        }
    }

    public init(
        backend: any UserNotificationCenterBackend = SystemUserNotificationCenterBackend(),
        registerAsDelegate: Bool = false
    ) {
        self.backend = backend
        if registerAsDelegate {
            UNUserNotificationCenter.current().delegate = delegateRelay
        }
    }

    // MARK: - Permission Lifecycle

    public func refreshAuthorizationStatus() async {
        authorizationStatus = await backend.fetchAuthorizationStatus()
    }

    @discardableResult
    public func requestPermission() async -> Bool {
        lastErrorMessage = nil
        do {
            let granted = try await backend.requestAuthorization(options: [.alert, .badge, .sound])
            authorizationStatus = await backend.fetchAuthorizationStatus()
            if granted && authorizationStatus == .notDetermined {
                authorizationStatus = .authorized
            }
            inAppNotificationsEnabled = granted
            return granted
        } catch {
            lastErrorMessage = error.localizedDescription
            await refreshAuthorizationStatus()
            return false
        }
    }

    // MARK: - Unread App Icon Badge Synchronization (`setBadgeCount`)

    /// Computes total unread badge count across non-hidden, non-muted conversations.
    /// A room manually marked unread (`isMarkedUnread`) contributes at least `1`.
    public static func computeUnreadBadgeCount(for rooms: [Room]) -> Int {
        rooms.reduce(into: 0) { sum, room in
            guard !room.isHidden, !room.isMuted else { return }
            let roomUnread = max(0, room.unreadCount)
            if roomUnread > 0 {
                sum += roomUnread
            } else if room.isMarkedUnread {
                sum += 1
            }
        }
    }

    /// Computes and synchronizes the app icon badge count from `rooms`.
    public func syncBadgeCount(for rooms: [Room]) async {
        let total = Self.computeUnreadBadgeCount(for: rooms)
        await syncBadgeCount(total)
    }

    /// Synchronizes an explicit unread count to the system app icon via `UNUserNotificationCenter.setBadgeCount(_:)`.
    public func syncBadgeCount(_ count: Int) async {
        let clamped = max(0, count)
        lastSyncedBadgeCount = clamped
        do {
            try await backend.setBadgeCount(clamped)
        } catch {
            // Simulator or unentitled test runner without badge permission still preserves `lastSyncedBadgeCount`.
            lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Foreground & Background Local Notification Scheduling

    /// Schedules an immediate local notification for an incoming `Message` when appropriate.
    /// Suppresses self-authored messages, revoked/system events, muted chats, and the currently visible room.
    @discardableResult
    public func notifyIncomingMessage(
        _ message: Message,
        room: Room?,
        currentUserID: String?,
        visibleRoomID: String?
    ) async -> Bool {
        guard inAppNotificationsEnabled else { return false }
        if let currentUserID, message.senderID == currentUserID { return false }
        if message.deliveryState == .revoked || message.kind == .system { return false }
        if room?.isMuted == true || room?.isHidden == true { return false }
        if let visibleRoomID, visibleRoomID == message.roomID { return false }

        if authorizationStatus == .notDetermined {
            await refreshAuthorizationStatus()
        }
        guard isAuthorized else { return false }

        let title: String
        let subtitle: String
        if let room {
            title = room.title.isEmpty ? message.senderDisplay : room.title
            subtitle = room.kind == .group ? message.senderDisplay : ""
        } else {
            title = message.senderDisplay
            subtitle = ""
        }

        let body = Self.notificationBody(for: message)
        let payload = PendingNotificationPayload(
            identifier: "cuven.msg.\(message.id)",
            title: title,
            subtitle: subtitle,
            body: body,
            roomID: message.roomID,
            messageID: message.id,
            threadIdentifier: message.roomID
        )

        do {
            try await backend.addNotification(payload)
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    public func clearDeliveredNotifications(forRoomID roomID: String) async {
        await backend.removeDeliveredNotifications(forRoomID: roomID)
    }

    public static func notificationBody(for message: Message) -> String {
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch message.kind {
        case .text:
            return trimmed.isEmpty ? "Sent a message" : trimmed
        case .image:
            let count = max(1, message.mediaURLs.count)
            let fallback = count > 1 ? "Sent \(count) photos" : "Sent a photo"
            return trimmed.isEmpty ? fallback : "📷 \(trimmed)"
        case .drawing:
            return "🎨 Sent a drawing"
        case .sticker:
            return trimmed.isEmpty ? "Sent a sticker" : "\(trimmed) Sticker"
        case .voice:
            return "🎙️ Voice message"
        case .video:
            return trimmed.isEmpty ? "🎬 Sent a video" : "🎬 \(trimmed)"
        case .file:
            return trimmed.isEmpty ? "📎 Sent a file" : "📎 \(trimmed)"
        case .call:
            return trimmed.isEmpty ? "Incoming call" : trimmed
        case .system:
            return trimmed
        }
    }
}

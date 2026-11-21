import ActivityKit
import AppIntents
import Foundation

/// A call as a Live Activity (ActivityKit): in the Dynamic Island, which on
/// iPhone Duo grows out of the outer camera's region, and on the Lock Screen.
/// Shared by the app (which starts and updates it) and the widget extension
/// (which draws it).
struct CallActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// "Calling…", "Ringing…", "Connecting…"; empty once connected.
        var status: String
        /// When it connected: the time counts up from here.
        var liveSince: Date?
        var muted: Bool
    }

    var name: String
    var initials: String
    var video: Bool
}

/// What the Live Activity's buttons reach in the app (set by CallManager).
enum CallControl {
    @MainActor static var hangUp: (() -> Void)?
    @MainActor static var toggleMute: (() -> Void)?
}

/// Ends the call from the Dynamic Island or the Lock Screen (runs in the app).
struct EndCallIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "End Call"
    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        CallControl.hangUp?()
        return .result()
    }
}

/// Mutes or unmutes your microphone from the Dynamic Island (runs in the app).
struct ToggleMuteIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mute Microphone"
    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        CallControl.toggleMute?()
        return .result()
    }
}

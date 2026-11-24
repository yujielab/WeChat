import SwiftUI
import UserNotifications

@main
struct CuvenApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @AppStorage("ui:motion") private var motion = "system"

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(model.colorScheme)
                .tint(Theme.blue)
                // Settings › Reduce motion: what moves only fades, quickly.
                .transaction { t in
                    if motion == "reduce", t.animation != nil { t.animation = .easeOut(duration: 0.15) }
                }
                .task {
                    CuvenTips.configure()
                    AppDelegate.model = model
                    PendingRoute.deliver(to: model)
                    Automation.prepare(model)
                    await model.launch()
                    await Automation.signIn(model)
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static weak var model: AppModel?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let room = response.notification.request.content.userInfo["room"] as? String
        Task { @MainActor in
            if let room { AppDelegate.model?.pendingRoom = room }
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            switch model.phase {
            case .launching:
                SplashView().transition(.opacity)
            case .signedOut:
                AuthView().transition(.opacity.combined(with: .scale(scale: 1.02)))
            case .ready:
                MainView().transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.4), value: model.phase)
        .modifier(EmulatedDisplay())
    }
}

/// CI screenshots only (CUVEN_EMULATE): the whole app laid out at the iPhone
/// Duo display's size in the top-left corner, with no status bar over it.
private struct EmulatedDisplay: ViewModifier {
    func body(content: Content) -> some View {
        if let emu = Emulation.current {
            content
                .safeAreaPadding(emu.insets)
                .frame(width: emu.size.width, height: emu.size.height)
                .clipped()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.black)
                .ignoresSafeArea()
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
        } else {
            content
        }
    }
}

struct SplashView: View {
    @State private var appear = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            Image("AppIcon-Mark")
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .scaleEffect(appear ? 1 : 0.86)
                .opacity(appear ? 1 : 0)
        }
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { appear = true } }
    }
}

/// Hooks for automated screenshots (CI runs the app in the Simulator against
/// a local `wrangler dev`). Driven only by environment variables a person's
/// device never has, so they do nothing in normal use.
enum Automation {
    static let env = ProcessInfo.processInfo.environment
    static var active: Bool { env["CUVEN_SCREEN"] != nil }
    static var screen: String { env["CUVEN_SCREEN"] ?? "" }

    @MainActor
    static func prepare(_ model: AppModel) {
        guard active else { return }
        if let server = env["CUVEN_SERVER"] { _ = model.setServer(server) }
        if let look = env["CUVEN_APPEARANCE"] { model.appearance = look }
        if env["CUVEN_BOOK"] == "1" { model.bookLayout = true }
    }

    @MainActor
    static func signIn(_ model: AppModel) async {
        guard active, model.phase == .signedOut, let user = env["CUVEN_USER"], let pass = env["CUVEN_PASS"] else { return }
        try? await model.login(username: user, password: pass)
    }

    /// Takes the shell to the screen being photographed.
    @MainActor
    static func drive(_ model: AppModel, _ nav: Nav) async {
        guard active else { return }
        try? await Task.sleep(for: .seconds(1.5))
        for _ in 0..<40 where model.rooms.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
        let first = model.rooms.first { !$0.isGroup }?.id ?? model.rooms.first?.id
        switch screen {
        case "thread": if let first { nav.open(room: first) }
        case "thread-long":
            // The longest conversation, scrolled so its messages run under the heading.
            if let long = model.rooms.first(where: { !$0.isGroup && $0.peer?.username == "bob" })?.id ?? first { nav.open(room: long) }
        case "info":
            if let first {
                nav.open(room: first)
                try? await Task.sleep(for: .seconds(1))
                nav.show(.info)
            }
        case "draw":
            if let first {
                nav.open(room: first)
                try? await Task.sleep(for: .seconds(1))
                nav.show(.draw)
            }
        case "group": if let g = model.rooms.first(where: { $0.isGroup })?.id { nav.open(room: g) }
        case "moments": nav.switchPage(.moments)
        case "requests", "friends": nav.switchPage(.friends)
        case "me": nav.switchPage(.me)
        case "settings": nav.settingsOpen = true
        case "newchat", "newgroup": nav.newGroup = true
        case "search":
            nav.toList()
            try? await Task.sleep(for: .milliseconds(300))
            nav.searching = true
        case "note": nav.noteEditor = true
        case "profile":
            if let peer = model.rooms.first(where: { !$0.isGroup })?.peer { nav.profile = peer.id }
        case "profile-scrolled":
            if let peer = model.rooms.first(where: { !$0.isGroup })?.peer { nav.profile = peer.id }
            try? await Task.sleep(for: .seconds(2))
            NotificationCenter.default.post(name: .automationScroll, object: nil)
        case "editprofile":
            nav.settingsOpen = true
            try? await Task.sleep(for: .milliseconds(500))
            nav.editingProfile = true
        case "note-open": if let n = model.notes.first { nav.openNote = n }
        case "plus":
            if let first {
                nav.open(room: first)
                try? await Task.sleep(for: .seconds(1))
                NotificationCenter.default.post(name: .automationPlus, object: nil)
            }
        case "focus":
            if let first {
                nav.open(room: first)
                try? await Task.sleep(for: .seconds(1.5))
                NotificationCenter.default.post(name: .automationFocus, object: nil)
            }
        default: break
        }
    }
}

extension Notification.Name {
    static let automationPlus = Notification.Name("cuven.automation.plus")
    static let automationFocus = Notification.Name("cuven.automation.focus")
    static let automationScroll = Notification.Name("cuven.automation.scroll")
    /// The tab you're on was tapped again: its page scrolls to the top (object: the page's rawValue).
    static let scrollToTop = Notification.Name("cuven.scrollToTop")
}

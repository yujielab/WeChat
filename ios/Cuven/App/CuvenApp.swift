import SwiftUI
import UserNotifications

@main
struct CuvenApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(model.colorScheme)
                .tint(Theme.blue)
                .task {
                    AppDelegate.model = model
                    await model.launch()
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
    }
}

struct SplashView: View {
    @State private var appear = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(Theme.blue.gradient)
                .scaleEffect(appear ? 1 : 0.86)
                .opacity(appear ? 1 : 0)
        }
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { appear = true } }
    }
}

//
//  CuvenApp.swift
//  Cuven
//
//  Apple HIG & iOS 27.2 SDK Grounding:
//  - Built against iOS 27.2 SDK (`Xcode 27.2`, `iphoneos27.2` / `iphonesimulator27.2`) with
//    `UIRequiresFullScreen = false`, `UIApplicationSupportsMultipleScenes = true`, and edge-to-edge
//    safe-area adaptation for iPhone and iPhone Duo (`PROJECT.md § 1, § 5.5`).
//  - Honors deterministic launch arguments (`--uitest-demo`, `--uitest-logged-out`,
//    `--uitest-posture=<iPhoneCompact|iPhoneSplit|duoClosed|duoHalfBook|duoHalfLaptop|duoOpen>`)
//    synchronously at scene initialization for zero-race automated Simulator verification.
//

import CuvenCore
import SwiftUI

@main
public struct CuvenApp: App {
    @State private var store: AppStore

    private let launchConfig: LaunchConfiguration

    @Environment(\.scenePhase) private var scenePhase

    public struct LaunchConfiguration: Equatable, Sendable {
        public let isDemoMode: Bool
        public let forceLoggedOut: Bool
        public let postureOverride: DuoPosture?

        public static func parse(arguments: [String] = ProcessInfo.processInfo.arguments) -> LaunchConfiguration {
            var isDemo = false
            var loggedOut = false
            var parsedPosture: DuoPosture?

            var index = 0
            while index < arguments.count {
                let arg = arguments[index]
                if arg == "--uitest-demo" {
                    isDemo = true
                } else if arg == "--uitest-logged-out" {
                    loggedOut = true
                } else if arg.hasPrefix("--uitest-posture=") {
                    let raw = String(arg.dropFirst("--uitest-posture=".count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    parsedPosture = DuoPosture(rawValue: raw)
                } else if arg == "--uitest-posture", index + 1 < arguments.count {
                    let raw = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                    parsedPosture = DuoPosture(rawValue: raw)
                    index += 1
                }
                index += 1
            }

            return LaunchConfiguration(
                isDemoMode: isDemo,
                forceLoggedOut: loggedOut,
                postureOverride: parsedPosture
            )
        }
    }

    public init() {
        let config = LaunchConfiguration.parse()
        self.launchConfig = config

        let initialStore = AppStore()

        if config.forceLoggedOut {
            // Ensure unauthenticated gate (`AuthRootView`) is shown cleanly on frame 0
            initialStore.authError = nil
        } else if config.isDemoMode {
            initialStore.enterDemoMode()
        }

        if let posture = config.postureOverride {
            initialStore.postureOverride = posture
        }

        self._store = State(initialValue: initialStore)
    }

    public var body: some Scene {
        WindowGroup {
            RootCoordinatorView(store: store)
                .task {
                    await performInitialBootstrapIfNeeded()
                }
                .onChange(of: store.isAuthenticated) { _, _ in
                    // Preserve explicit `--uitest-posture=...` launch override across sign-in / demo transitions
                    if let launchPosture = launchConfig.postureOverride,
                       store.postureOverride == nil {
                        store.postureOverride = launchPosture
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active,
                       store.isAuthenticated,
                       !launchConfig.isDemoMode,
                       !launchConfig.forceLoggedOut {
                        Task {
                            await store.outbox.resume()
                        }
                    }
                }
        }
    }

    @MainActor
    private func performInitialBootstrapIfNeeded() async {
        if launchConfig.forceLoggedOut {
            if store.isAuthenticated {
                await store.signOut()
            }
            if let launchPosture = launchConfig.postureOverride {
                store.postureOverride = launchPosture
            }
            return
        }

        if launchConfig.isDemoMode {
            if !store.isAuthenticated || store.rooms.isEmpty {
                store.enterDemoMode()
            }
            if let launchPosture = launchConfig.postureOverride {
                store.postureOverride = launchPosture
            }
            return
        }

        await store.bootstrap()
        if let launchPosture = launchConfig.postureOverride,
           store.postureOverride == nil {
            store.postureOverride = launchPosture
        }
    }
}

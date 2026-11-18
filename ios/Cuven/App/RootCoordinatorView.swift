//
//  RootCoordinatorView.swift
//  Cuven
//
//  Apple HIG & iOS 27.2 SDK Grounding:
//  - Human Interface Guidelines › Designing for iPhone Duo › Dynamic layouts, Split views, Continuity & Sheets
//    (iOS 27.2 SDK: `DuoPostureMonitor` -> 4-column `StripContainerView`, right-edge `DuoRightEdgeChromeOverlay`
//     hosting `52pt` `DuoRailView` + `52×282pt` `PagesCapsuleView`, `PostureMatrixSwitcherHUD`,
//     full-page `MomentsRootView` / `MemoriesRootView` place swaps, `InAppBannerOverlay`,
//     `CallOverlayContainerView`, and posture-aware `.presentationPlacement` modal sheets)
//  - Canonical Cross-Module Contract: `PROJECT.md § 5.2, § 5.4, § 5.5`
//  - Cuven Web Parity: `public/js/views/shell.js:25-500`, `public/js/ui/pages.js:50-115`
//

import CuvenCore
import SwiftUI

/// Top-level scene coordinator bridging `AuthRootView` (when signed out) and the signed-in
/// iPhone & iPhone Duo 4-column spatial shell (`StripContainerView` + `DuoRightEdgeChromeOverlay` +
/// `MomentsRootView` / `MemoriesRootView` + `CallOverlayContainerView` + posture-aware sheets).
public struct RootCoordinatorView: View {
    private let store: AppStore

    @State private var presentedModal: CuvenShellModalDestination?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(store: AppStore) {
        self.store = store
    }

    private var preferredScheme: ColorScheme? {
        switch store.prefs.theme {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    /// True when a full-page place (`Moments` or `Memories`) is covering the 4-column strip (`pages.js:94`).
    private var isFullPagePlaceOverlayActive: Bool {
        store.activePage == .moments || store.activePage == .memories
    }

    public var body: some View {
        DuoPostureMonitor(store: store) { metrics in
            ZStack {
                CuvenColors.paperBackground
                    .ignoresSafeArea()

                if store.isAuthenticated {
                    authenticatedSpatialShell(metrics: metrics)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .opacity.combined(with: .scale(scale: 0.985))
                        )
                } else {
                    AuthRootView(store: store)
                        .transition(.opacity)
                }
            }
            .animation(
                CuvenSprings.adaptive(CuvenSprings.gentle, reduceMotion: reduceMotion),
                value: store.isAuthenticated
            )
            .environment(\.cuvenPresentShellModal) { destination in
                presentShellModal(destination)
            }
            .sheet(item: $presentedModal, onDismiss: handleModalDismissed) { destination in
                modalDestinationContent(for: destination)
                    .modifier(PostureAwareSheetPlacementModifier(posture: metrics.posture))
            }
        }
        .preferredColorScheme(preferredScheme)
        .onAppear {
            syncServerBaseURLDefault()
        }
        .onChange(of: store.serverBaseURL) { _, _ in
            syncServerBaseURLDefault()
        }
        .onChange(of: store.activePage) { _, newPage in
            routeActivePageIfModal(newPage)
        }
        .onChange(of: store.isAuthenticated) { _, isAuthenticated in
            if !isAuthenticated {
                presentedModal = nil
            }
        }
    }

    // MARK: - Signed-In iPhone & iPhone Duo Spatial Shell

    @ViewBuilder
    private func authenticatedSpatialShell(metrics: DuoLayoutMetrics) -> some View {
        let currentWindowStart = StripContainerView.windowStart(
            focus: effectiveStripFocus,
            visibleCount: metrics.visibleColumnCount
        )

        ZStack(alignment: .topLeading) {
            // 1. Persistent 4-Column Horizontal Strip (`0: Sidebar | 1: ChatList | 2: Thread | 3: Artifact`)
            StripContainerView(
                store: store,
                metrics: metrics,
                onPresentModal: { destination in
                    presentShellModal(destination)
                }
            )
            .allowsHitTesting(!isFullPagePlaceOverlayActive)
            .accessibilityHidden(isFullPagePlaceOverlayActive)

            // 2. Full-Page Place Overlays (`Moments` & `Memories` — swap in place under `PagesCapsuleView`, `pages.js:7-9`)
            if store.activePage == .moments {
                MomentsRootView(
                    store: store,
                    metrics: metrics,
                    onClose: {
                        returnFromFullPagePlace()
                    }
                )
                .transition(.opacity)
                .zIndex(10)
            } else if store.activePage == .memories {
                MemoriesRootView(
                    store: store,
                    metrics: metrics,
                    onClose: {
                        returnFromFullPagePlace()
                    }
                )
                .transition(.opacity)
                .zIndex(10)
            }

            // 3. iPhone Duo Right-Edge System Column Chrome (`52pt` `DuoRailView` + `52×282pt` `PagesCapsuleView`)
            if metrics.hasRightSystemColumn {
                DuoRightEdgeChromeOverlay(
                    store: store,
                    metrics: metrics,
                    windowStartColumn: currentWindowStart,
                    panLeadBackOffset: 0,
                    isFullPageOverlayActive: isFullPagePlaceOverlayActive,
                    onNavigateColumn: { targetColumn in
                        navigateStripColumn(targetColumn)
                    },
                    onSelectPage: { page in
                        handlePagesCapsuleSelection(page)
                    },
                    onPresentModal: { destination in
                        presentShellModal(destination)
                    }
                )
                .zIndex(20)
            }

            // 4. Collapsible Liquid Glass Posture Matrix Switcher HUD (`shell.postureSwitcher`)
            PostureMatrixSwitcherHUD(
                store: store,
                metrics: metrics
            )
            .zIndex(30)

            // 5. Interactive Top Notification Banner (`InAppBannerOverlay`)
            InAppBannerOverlay(
                store: store,
                metrics: metrics
            )
            .zIndex(40)

            // 6. Native WebRTC Audio/Video Call Stage & Velocity-Projected PiP (`CallOverlayContainerView`)
            CallOverlayContainerView(
                store: store,
                metrics: metrics
            )
            .zIndex(50)
        }
        .frame(
            width: metrics.viewportSize.width,
            height: metrics.viewportSize.height,
            alignment: .topLeading
        )
        .animation(
            CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion),
            value: store.activePage
        )
    }

    // MARK: - Navigation & Modal Routing (`pages.js:51-86`, `shell.js:100-107`)

    private var effectiveStripFocus: Int {
        if store.activeArtifactMode != nil && store.activeColumnIndex >= 2 {
            return 3
        }
        return max(0, min(3, store.activeColumnIndex))
    }

    private func navigateStripColumn(_ targetColumn: Int) {
        let clamped = max(0, min(3, targetColumn))
        withAnimation(CuvenSprings.adaptive(CuvenSprings.stripSlide, reduceMotion: reduceMotion)) {
            if store.activePage != .chats && store.activePage != .menu {
                store.navigateToPage(clamped == 0 ? .menu : .chats)
            }
            if clamped < 3 && store.activeArtifactMode != nil {
                store.closeArtifact()
            }
            store.activeColumnIndex = clamped
        }
    }

    private func handlePagesCapsuleSelection(_ page: NavigationPage) {
        switch page {
        case .chats:
            presentedModal = nil
            withAnimation(CuvenSprings.adaptive(CuvenSprings.stripSlide, reduceMotion: reduceMotion)) {
                store.navigateToPage(.chats)
                if store.activeArtifactMode != nil {
                    store.closeArtifact()
                }
                if store.activeColumnIndex == 0 {
                    store.activeColumnIndex = 1
                }
            }

        case .menu:
            presentedModal = nil
            withAnimation(CuvenSprings.adaptive(CuvenSprings.stripSlide, reduceMotion: reduceMotion)) {
                store.navigateToPage(.menu)
                if store.activeArtifactMode != nil {
                    store.closeArtifact()
                }
                store.activeColumnIndex = 0
            }

        case .moments:
            presentedModal = nil
            withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
                store.navigateToPage(.moments)
            }

        case .memories:
            presentedModal = nil
            withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
                store.navigateToPage(.memories)
            }

        case .friends:
            store.navigateToPage(.friends)
            presentedModal = .friendsAndRequests

        case .you:
            store.navigateToPage(.you)
            presentedModal = .settings
        }
    }

    private func routeActivePageIfModal(_ page: NavigationPage) {
        switch page {
        case .friends:
            if presentedModal != .friendsAndRequests {
                presentedModal = .friendsAndRequests
            }
        case .you:
            if presentedModal != .settings {
                presentedModal = .settings
            }
        default:
            break
        }
    }

    private func returnFromFullPagePlace() {
        withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
            store.navigateToPage(store.activeColumnIndex == 0 ? .menu : .chats)
        }
    }

    private func presentShellModal(_ destination: CuvenShellModalDestination) {
        presentedModal = destination
    }

    private func handleModalDismissed() {
        if store.activePage == .friends || store.activePage == .you {
            store.navigateToPage(store.activeColumnIndex == 0 ? .menu : .chats)
        }
    }

    @ViewBuilder
    private func modalDestinationContent(for destination: CuvenShellModalDestination) -> some View {
        switch destination {
        case .settings:
            SettingsRootSheet(store: store, initialTab: nil)

        case .settingsTab(let initialTab):
            SettingsRootSheet(store: store, initialTab: initialTab)

        case .avatarCoverEditor:
            ProfileAvatarCoverEditorSheet(store: store)

        case .friendsAndRequests:
            FriendRequestsAndPeopleSheet(store: store)

        case .globalSearch:
            GlobalSearchSheet(store: store)

        case .wordExplain(let initialText, let roomContext):
            WordPickerExplainSheet(
                store: store,
                initialText: initialText,
                roomContext: roomContext
            )
        }
    }

    private func syncServerBaseURLDefault() {
        UserDefaults.standard.set(store.serverBaseURL.absoluteString, forKey: "cuven.serverBaseURL")
    }
}

// MARK: - iOS 27.0 / 27.2 Posture-Aware Sheet Placement (`README.md` L70–72 & `spec_miner` § 1.3.B #4)

/// Centers modals across the full canvas on `duoOpen` / `iPhoneSplit` (`.presentationPlacement(.center)`),
/// confines modals to the originating pane clear of the physical fold crease on `duoHalfBook` (`.leading`),
/// and uses standard bottom-rising sheet presentation on 1-column postures.
private struct PostureAwareSheetPlacementModifier: ViewModifier {
    let posture: DuoPosture

    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            switch posture {
            case .duoHalfBook:
                content
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(28)
                    .presentationPlacement(.leading)

            case .duoOpen, .iPhoneSplit:
                content
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(28)
                    .presentationPlacement(.center)

            case .iPhoneCompact, .duoClosed, .duoHalfLaptop:
                content
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(28)
                    .presentationPlacement(.automatic)
            }
        } else {
            content
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
        }
    }
}

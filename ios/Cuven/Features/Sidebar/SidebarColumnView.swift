import SwiftUI
import CuvenCore

// MARK: - Apple HIG & iOS 27.1 SDK Traceability
// - Apple HIG › Designing for iPhone Duo & Split Views: Column 0 ("Home") adapts seamlessly between
//   1-column stack (`iPhoneCompact` / `duoClosed` clearing the asymmetric right-edge system column & 52pt `DuoRail`)
//   and 2-column split (`duoOpen` / `duoHalfBook` / `iPhoneSplit`), clearing the 56pt floating bottom dock.
// - Apple HIG › Materials / Liquid Glass: Active scope row features a gliding `@Namespace` `matchedGeometryEffect`
//   Liquid Glass highlight pill (`.cuvenLiquidGlass(...)`) with automatic Reduce Transparency solid fallback.
// - Apple HIG › Color & Contrast: Facebook-Blue (`#1877F2` / `CuvenColors.sidebarBlue`) icon badges paired with
//   ink labels (`public/css/columns.css:53-54`), WCAG AA (`>= 5.4:1`) unread count pill (`CuvenColors.unreadBadgeBackground`),
//   and `>= 44×44pt` hit regions across every row and quick action.
// - Cuven Web Reference: `public/js/views/sidebar.js` & `public/css/columns.css`.

/// Column 0 (`Home`) navigation sidebar for Cuven on iPhone & iPhone Duo.
public struct SidebarColumnView: View {
    private let store: AppStore
    private let metrics: DuoLayoutMetrics

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @Namespace private var activeRowNamespace

    @State private var isShowingProfileEditor: Bool = false
    @State private var isShowingFriendsSheet: Bool = false
    @State private var isShowingSettingsSheet: Bool = false
    @State private var settingsInitialTab: String? = nil
    @State private var isShowingWelcomeGuide: Bool = false

    public init(store: AppStore, metrics: DuoLayoutMetrics) {
        self.store = store
        self.metrics = metrics
    }

    // MARK: - Derived State & Spatial Insets

    private var leadingContentInset: CGFloat {
        let baseMargin: CGFloat = metrics.viewportSize.width >= 430 ? 20 : 18
        return metrics.safeAreaLeft + baseMargin
    }

    /// Ensures Column 0 never intrudes into iPhone Duo's right-edge status/camera column or `52pt` `DuoRailView`
    /// when shown single-pane (`duoClosed`), respects symmetric right safe areas in 1-column landscape,
    /// and keeps symmetric inner margin when shown as the leading split pane (`duoOpen` / `duoHalfBook` / `iPhoneSplit`).
    private var trailingContentInset: CGFloat {
        let baseMargin: CGFloat = metrics.viewportSize.width >= 430 ? 20 : 18
        if metrics.visibleColumnCount == 1 {
            if metrics.hasRightSystemColumn {
                let rightClearance = max(metrics.safeAreaRight, max(metrics.railWidth, 52) + 24)
                return rightClearance + 14
            }
            return metrics.safeAreaRight + baseMargin
        }
        return baseMargin
    }

    private var topContentPadding: CGFloat {
        max(metrics.safeAreaTop, 12) + 22
    }

    private var bottomContentPadding: CGFloat {
        max(metrics.safeAreaBottom, 16) + 84
    }

    private var visibleRooms: [Room] {
        store.rooms.filter { !$0.isHidden }
    }

    private var unreadConversationCount: Int {
        visibleRooms.filter { $0.unreadCount > 0 || $0.isMarkedUnread }.count
    }

    private var pendingIncomingRequestsCount: Int {
        store.contacts.filter { $0.status == .pendingIn }.count
    }

    private var acceptedFriendsCount: Int {
        store.contacts.filter { $0.status == .accepted }.count
    }

    private var hasFreshMoments: Bool {
        !store.moments.isEmpty
    }

    public var body: some View {
        ZStack(alignment: .top) {
            CuvenColors.paperBackground
                .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    sidebarHeader

                    if store.isBootstrapping && store.rooms.isEmpty && store.currentUser == nil {
                        SidebarSkeletonPlaceholderView()
                            .transition(.opacity)
                    } else {
                        Group {
                            profileHeaderCard

                            scopesSection

                            discoverAndPlacesSection

                            ContextualGuideTipDeckView(
                                metrics: metrics,
                                onOpenWelcomeTour: {
                                    isShowingWelcomeGuide = true
                                }
                            )
                            .padding(.top, 4)
                        }
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .opacity.animation(.easeOut(duration: 0.22))
                        )
                    }
                }
                .padding(.top, topContentPadding)
                .padding(.bottom, bottomContentPadding)
                .padding(.leading, leadingContentInset)
                .padding(.trailing, trailingContentInset)
            }
        }
        .cuvenCappedDynamicType()
        .cuvenAdaptiveModal(
            isPresented: $isShowingProfileEditor,
            metrics: metrics,
            tall: true
        ) {
            ProfileAvatarCoverEditorSheet(store: store)
        }
        .cuvenAdaptiveModal(
            isPresented: $isShowingFriendsSheet,
            metrics: metrics,
            tall: true
        ) {
            FriendRequestsAndPeopleSheet(store: store)
        }
        .cuvenAdaptiveModal(
            isPresented: $isShowingSettingsSheet,
            metrics: metrics,
            tall: true
        ) {
            SettingsRootSheet(store: store, initialTab: settingsInitialTab)
        }
        .cuvenAdaptiveModal(
            isPresented: $isShowingWelcomeGuide,
            metrics: metrics,
            tall: false
        ) {
            WelcomeGuideSheetView {
                isShowingWelcomeGuide = false
            }
        }
    }

    // MARK: - Large "Home" Header (`sidebar.js:46`, `columns.css:10-12`)

    private var sidebarHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Home")
                .font(CuvenFonts.cappedLargeTitle(weight: .bold))
                .foregroundStyle(CuvenColors.sidebarBlue)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("sidebar.headerTitle")

            Spacer(minLength: 8)

            if store.isBootstrapping {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Syncing")
                        .font(CuvenFonts.cappedCaption(weight: .medium))
                        .foregroundStyle(CuvenColors.inkSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(CuvenColors.elevatedSurface)
                )
                .transition(.opacity)
            }
        }
    }

    // MARK: - User Profile Header Card (`.side-me` in `sidebar.js:20-21` + Direct Avatar Editor Trigger)

    private var profileHeaderCard: some View {
        let user = store.currentUser
        let displayName = (user?.display.isEmpty == false ? user?.display : user?.username) ?? "Me"
        let handleText = user.map { "@\($0.username)" } ?? ""
        let isOnline = user?.isOnline ?? true
        let noteText = store.myNote?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let bioText = user?.bio.trimmingCharacters(in: .whitespacesAndNewlines)

        let subtitleLine: String = {
            if let noteText, !noteText.isEmpty {
                return "“\(noteText)”"
            }
            if let bioText, !bioText.isEmpty {
                return bioText
            }
            return "Profile, appearance & privacy"
        }()

        return HStack(spacing: 4) {
            // Direct 1-tap Avatar & Cover Crop trigger (`>= 44×44pt`)
            Button {
                CuvenHaptics.lightTap()
                isShowingProfileEditor = true
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    CuvenAvatarView(
                        name: displayName,
                        urlString: user?.avatarURL,
                        size: 52,
                        isOnline: isOnline
                    )

                    ZStack {
                        Circle()
                            .fill(CuvenColors.cardSurface)
                            .frame(width: 20, height: 20)

                        Image(systemName: "camera.aperture")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(CuvenColors.sidebarBlue)
                    }
                    .offset(x: 2, y: 2)
                }
                .frame(minWidth: 56, minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar.editAvatarButton")
            .accessibilityLabel("Edit avatar and cover")

            // Main `.side-me` row opening `SettingsRootSheet` focused on `"profile"` (`sidebar.js:20-21`)
            Button {
                CuvenHaptics.lightTap()
                settingsInitialTab = "profile"
                isShowingSettingsSheet = true
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(displayName)
                                .font(CuvenFonts.cappedHeadline(weight: .semibold))
                                .foregroundStyle(CuvenColors.inkPrimary)
                                .lineLimit(1)

                            if !handleText.isEmpty {
                                Text(handleText)
                                    .font(CuvenFonts.cappedCaption())
                                    .foregroundStyle(CuvenColors.inkSecondary)
                                    .lineLimit(1)
                            }
                        }

                        HStack(spacing: 5) {
                            if let noteText, !noteText.isEmpty {
                                Image(systemName: "quote.bubble.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(CuvenColors.sidebarBlue)
                            } else {
                                Circle()
                                    .fill(isOnline ? CuvenColors.onlineGreen : CuvenColors.inkTertiary)
                                    .frame(width: 7, height: 7)
                            }

                            Text(subtitleLine)
                                .font(CuvenFonts.cappedFootnote())
                                .foregroundStyle(CuvenColors.inkSecondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 4)

                    // Vertically centered chevron (`docs/hig-audit.md` P2-6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CuvenColors.inkTertiary)
                        .frame(width: 16, height: 16)
                }
                .padding(.leading, 6)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(SidebarRowPressStyle(reduceMotion: reduceMotion))
            .accessibilityIdentifier("sidebar.profileCard")
            .accessibilityLabel("\(displayName), Profile & Settings")
            .accessibilityValue(subtitleLine)
            .accessibilityHint("Opens profile, avatar, and settings")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 74)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(CuvenColors.cardSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            colorSchemeContrast == .increased ? CuvenColors.inkTertiary : CuvenColors.cardLine,
                            lineWidth: 1
                        )
                )
        )
    }

    // MARK: - Chat Scopes (`All`, `Unread`, `Direct`, `Groups` w/ Facebook-Blue Badges & Gliding Liquid Glass)

    private var scopesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionEyebrow("CHATS")

            VStack(spacing: 3) {
                ForEach(SidebarScope.allCases) { scope in
                    scopeRow(for: scope)
                }
            }
        }
    }

    private func scopeRow(for scope: SidebarScope) -> some View {
        let isSelected = (store.activePage == .chats || store.activePage == .menu) && store.selectedSidebarScope == scope
        let badgeCount = scope == .unread ? unreadConversationCount : 0
        let label = scopeTitle(for: scope)
        let symbol = scopeSymbol(for: scope)

        return Button {
            selectChatScope(scope)
        } label: {
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.clear)
                        .cuvenLiquidGlass(
                            mode: store.prefs.glassMode,
                            cornerRadius: 14,
                            interactiveBounce: false
                        )
                        .matchedGeometryEffect(
                            id: "sidebarGlidingActiveRow",
                            in: activeRowNamespace
                        )
                }

                HStack(spacing: 12) {
                    facebookBlueIconBadge(
                        symbolName: symbol,
                        isEmphasized: isSelected
                    )

                    Text(label)
                        .font(CuvenFonts.cappedBody(weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if badgeCount > 0 {
                        Text("\(badgeCount)")
                            .font(CuvenFonts.cappedCaption(weight: .semibold).monospacedDigit())
                            .foregroundStyle(CuvenColors.unreadBadgeText)
                            .padding(.horizontal, 7)
                            .frame(minWidth: 22, minHeight: 22)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(CuvenColors.unreadBadgeBackground)
                            )
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .scale(scale: 0.8).combined(with: .opacity)
                            )
                    }
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(SidebarRowPressStyle(reduceMotion: reduceMotion))
        .accessibilityIdentifier("sidebar.scope.\(scope.rawValue)")
        .accessibilityLabel(label)
        .accessibilityValue(badgeCount > 0 ? "\(badgeCount) unread" : "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Rich Social & Utility Rows (`Moments`, `Memories`, `Friends & Requests`, `Settings`)

    private var discoverAndPlacesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionEyebrow("DISCOVER & PLACES")

            VStack(spacing: 3) {
                // 1. Moments (`sidebar.moments`)
                socialNavigationRow(
                    id: "sidebar.moments",
                    title: "Moments",
                    subtitle: momentsSubtitle,
                    accessibilityStatusValue: hasFreshMoments ? "New moments available" : "",
                    symbolName: "photo.on.rectangle.angled",
                    isSelected: store.activePage == .moments,
                    trailingAccessory: {
                        HStack(spacing: 8) {
                            if hasFreshMoments {
                                Circle()
                                    .fill(CuvenColors.sidebarBlue)
                                    .frame(width: 8, height: 8)
                                    .accessibilityHidden(true)
                            }
                            rowChevron
                        }
                    },
                    action: {
                        CuvenHaptics.lightTap()
                        withAnimation(CuvenSprings.adaptive(CuvenSprings.stripSlide, reduceMotion: reduceMotion)) {
                            store.navigateToPage(.moments)
                        }
                    }
                )

                // 2. Memories (`sidebar.memories`)
                socialNavigationRow(
                    id: "sidebar.memories",
                    title: "Memories",
                    subtitle: memoriesSubtitle,
                    accessibilityStatusValue: store.memories.isEmpty ? "" : "\(store.memories.count) saved",
                    symbolName: "photo.stack.fill",
                    isSelected: store.activePage == .memories,
                    trailingAccessory: {
                        HStack(spacing: 6) {
                            if !store.memories.isEmpty {
                                Text("\(store.memories.count)")
                                    .font(CuvenFonts.cappedCaption(weight: .medium).monospacedDigit())
                                    .foregroundStyle(CuvenColors.inkSecondary)
                            }
                            rowChevron
                        }
                    },
                    action: {
                        CuvenHaptics.lightTap()
                        withAnimation(CuvenSprings.adaptive(CuvenSprings.stripSlide, reduceMotion: reduceMotion)) {
                            store.navigateToPage(.memories)
                        }
                    }
                )

                // 3. Friends & Requests (`sidebar.friends`)
                socialNavigationRow(
                    id: "sidebar.friends",
                    title: "Friends & Requests",
                    subtitle: friendsSubtitle,
                    accessibilityStatusValue: pendingIncomingRequestsCount > 0
                        ? "\(pendingIncomingRequestsCount) pending requests"
                        : "",
                    symbolName: "person.badge.plus",
                    isSelected: isShowingFriendsSheet || store.activePage == .friends,
                    trailingAccessory: {
                        HStack(spacing: 6) {
                            if pendingIncomingRequestsCount > 0 {
                                Text("\(pendingIncomingRequestsCount)")
                                    .font(CuvenFonts.cappedCaption(weight: .semibold).monospacedDigit())
                                    .foregroundStyle(Color.white)
                                    .padding(.horizontal, 7)
                                    .frame(minWidth: 22, minHeight: 22)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(CuvenColors.dangerRed)
                                    )
                            }
                            rowChevron
                        }
                    },
                    action: {
                        CuvenHaptics.lightTap()
                        isShowingFriendsSheet = true
                    }
                )

                // 4. Settings (`sidebar.settings`)
                socialNavigationRow(
                    id: "sidebar.settings",
                    title: "Settings",
                    subtitle: settingsSubtitle,
                    accessibilityStatusValue: settingsSubtitle,
                    symbolName: "gearshape.fill",
                    isSelected: isShowingSettingsSheet || store.activePage == .you,
                    trailingAccessory: {
                        rowChevron
                    },
                    action: {
                        CuvenHaptics.lightTap()
                        settingsInitialTab = nil
                        isShowingSettingsSheet = true
                    }
                )
            }
        }
    }

    private func socialNavigationRow<Accessory: View>(
        id: String,
        title: String,
        subtitle: String?,
        accessibilityStatusValue: String = "",
        symbolName: String,
        isSelected: Bool,
        @ViewBuilder trailingAccessory: () -> Accessory,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.clear)
                        .cuvenLiquidGlass(
                            mode: store.prefs.glassMode,
                            cornerRadius: 14,
                            interactiveBounce: false
                        )
                        .matchedGeometryEffect(
                            id: "sidebarGlidingActiveRow",
                            in: activeRowNamespace
                        )
                }

                HStack(spacing: 12) {
                    facebookBlueIconBadge(
                        symbolName: symbolName,
                        isEmphasized: isSelected
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(CuvenFonts.cappedBody(weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(CuvenColors.inkPrimary)
                            .lineLimit(1)

                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(CuvenFonts.cappedCaption())
                                .foregroundStyle(CuvenColors.inkSecondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    trailingAccessory()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(SidebarRowPressStyle(reduceMotion: reduceMotion))
        .accessibilityIdentifier(id)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityStatusValue)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Shared Row Components & Copy

    private func sectionEyebrow(_ title: String) -> some View {
        Text(title)
            .font(CuvenFonts.cappedCaption(weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(CuvenColors.inkSecondary)
            .padding(.horizontal, 12)
    }

    /// Facebook-Blue (`#1877F2` / `CuvenColors.sidebarBlue`) squircle icon badge (`columns.css:54`).
    private func facebookBlueIconBadge(symbolName: String, isEmphasized: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    CuvenColors.sidebarBlue.opacity(
                        colorScheme == .dark
                            ? (isEmphasized ? 0.26 : 0.16)
                            : (isEmphasized ? 0.16 : 0.10)
                    )
                )
                .frame(width: 30, height: 30)

            Image(systemName: symbolName)
                .font(.system(size: 15, weight: isEmphasized ? .semibold : .medium))
                .foregroundStyle(CuvenColors.sidebarBlue)
        }
    }

    private var rowChevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(CuvenColors.inkTertiary)
            .frame(width: 14, height: 14)
    }

    private func scopeTitle(for scope: SidebarScope) -> String {
        switch scope {
        case .all:
            return "All"
        case .unread:
            return "Unread"
        case .direct:
            return "Direct"
        case .groups:
            return "Groups"
        }
    }

    private func scopeSymbol(for scope: SidebarScope) -> String {
        switch scope {
        case .all:
            return "bubble.left.and.bubble.right.fill"
        case .unread:
            return "envelope.badge.fill"
        case .direct:
            return "person.fill"
        case .groups:
            return "person.2.fill"
        }
    }

    private var momentsSubtitle: String {
        if let latest = store.moments.first {
            return "Latest from \(latest.author.display)"
        }
        return "Photos & stories from friends"
    }

    private var memoriesSubtitle: String {
        if store.memories.isEmpty {
            return "Shared photos & drawings by month"
        }
        return "\(store.memories.count) shared moments saved"
    }

    private var friendsSubtitle: String {
        if pendingIncomingRequestsCount > 0 {
            return "\(pendingIncomingRequestsCount) pending request\(pendingIncomingRequestsCount == 1 ? "" : "s")"
        }
        if acceptedFriendsCount > 0 {
            return "\(acceptedFriendsCount) friend\(acceptedFriendsCount == 1 ? "" : "s") · Add or start group"
        }
        return "Add contacts, requests & groups"
    }

    private var settingsSubtitle: String {
        let glassLabel = store.prefs.glassMode == .clear ? "Clear Glass" : "Tinted Glass"
        return "\(glassLabel) · Glow, AI Memory & Privacy"
    }

    // MARK: - Actions

    private func selectChatScope(_ scope: SidebarScope) {
        CuvenHaptics.selectionChanged()
        let transitionAnimation = CuvenSprings.adaptive(CuvenSprings.stripSlide, reduceMotion: reduceMotion)
        withAnimation(transitionAnimation) {
            store.selectedSidebarScope = scope
            store.navigateToPage(.chats)
            // Advance strip from Column 0 (Sidebar) to Column 1 (ChatList) so the filtered inbox opens cleanly
            if metrics.visibleColumnCount == 1 || store.activeColumnIndex == 0 {
                store.activeColumnIndex = 1
            }
        }
    }
}

/// Subtle tactile row highlight & press bounce matching `.side-scope:active` (`columns.css:48`, `tokens.css:188`).
private struct SidebarRowPressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? CuvenColors.inkPrimary.opacity(0.06)
                            : Color.clear
                    )
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1.0)
            .animation(
                reduceMotion ? CuvenSprings.reducedMotionFade : CuvenSprings.pressBounce,
                value: configuration.isPressed
            )
    }
}

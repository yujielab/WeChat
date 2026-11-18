//
//  AdaptiveActionBars.swift
//  Cuven
//
//  Apple HIG & iOS 27.1 SDK Grounding:
//  - Human Interface Guidelines › Designing for iPhone Duo › Vertical controls & Split views
//    ("Move controls to the trailing edge on iPhone Duo; keep horizontal bottom controls on leading split pane
//     and standard iPhone")
//  - Human Interface Guidelines › Materials › Liquid Glass (`56pt` bottom dock capsules & `52pt` Duo rail)
//  - Cuven Web Parity: `public/js/ui/bars.js:20-39`, `public/css/duo-layout.css:74-101`,
//    `public/css/rail.css:35-82`, `public/css/pages.css:88-93`, `public/js/views/shell.js:87-110`
//

import CuvenCore
import SwiftUI

// MARK: - Horizontal 56pt Floating Liquid Glass Bottom Dock (`shell.bottomDock`)

/// Renders the `56pt` floating Liquid Glass horizontal bottom bar used on:
/// 1. Standard iPhone (`!metrics.hasRightSystemColumn`, both `iPhoneCompact` and `iPhoneSplit`).
/// 2. The **leading (left) column** of iPhone Duo in 2-column postures (`duoOpen` `342pt` & `duoHalfBook` `462pt`),
///    providing thumb-reachable `Filter` + `Search` capsules while the right column uses vertical `DuoRailView`.
public struct HorizontalBottomDockView: View {
    private let store: AppStore
    public let columnIndex: Int
    public let isSplitLeadingColumn: Bool
    public let metrics: DuoLayoutMetrics
    public let panLeadBackOffset: CGFloat
    public let onNavigateColumn: (Int) -> Void
    public let onPresentModal: (CuvenShellModalDestination) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Canonical `56pt` dock height matching `public/css/duo-layout.css:78` (`--dock-h: 56px`).
    public static let dockHeight: CGFloat = 56

    public init(
        store: AppStore,
        columnIndex: Int,
        isSplitLeadingColumn: Bool,
        metrics: DuoLayoutMetrics,
        panLeadBackOffset: CGFloat = 0,
        onNavigateColumn: @escaping (Int) -> Void,
        onPresentModal: @escaping (CuvenShellModalDestination) -> Void
    ) {
        self.store = store
        self.columnIndex = columnIndex
        self.isSplitLeadingColumn = isSplitLeadingColumn
        self.metrics = metrics
        self.panLeadBackOffset = panLeadBackOffset
        self.onNavigateColumn = onNavigateColumn
        self.onPresentModal = onPresentModal
    }

    private var unreadRoomCount: Int {
        store.rooms.reduce(into: 0) { acc, room in
            if !room.isHidden && (room.unreadCount > 0 || room.isMarkedUnread) {
                acc += 1
            }
        }
    }

    private var pendingRequestCount: Int {
        store.contacts.reduce(into: 0) { acc, item in
            if item.status == .pendingIn {
                acc += 1
            }
        }
    }

    public var body: some View {
        HStack(spacing: 8) {
            switch columnIndex {
            case 0:
                sidebarHorizontalItems
            case 1:
                chatListHorizontalItems
            case 3:
                artifactHorizontalItems
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.dockHeight, maxHeight: Self.dockHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shell.bottomDock")
        .accessibilityLabel("Bottom actions")
    }

    // MARK: - Column 0 (`Sidebar`) Horizontal Dock

    @ViewBuilder
    private var sidebarHorizontalItems: some View {
        Spacer(minLength: 0)

        if !isSplitLeadingColumn {
            HStack(spacing: 2) {
                dockIconButton(
                    id: "chats",
                    symbol: "bubble.left.and.bubble.right",
                    label: "Chats",
                    badge: unreadRoomCount > 0 ? "\(min(99, unreadRoomCount))" : nil
                ) {
                    onNavigateColumn(1)
                }

                dockIconButton(
                    id: "friends",
                    symbol: "person.badge.plus",
                    label: "Friends",
                    badge: pendingRequestCount > 0 ? "\(min(9, pendingRequestCount))" : nil
                ) {
                    onPresentModal(.friendsAndRequests)
                }

                dockIconButton(
                    id: "settings",
                    symbol: "gearshape",
                    label: "Settings"
                ) {
                    onPresentModal(.settings)
                }
            }
            .padding(6)
            .frame(height: Self.dockHeight)
            .cuvenLiquidGlass(
                mode: store.prefs.glassMode,
                cornerRadius: Self.dockHeight / 2,
                interactiveBounce: false
            )
        }
    }

    // MARK: - Column 1 (`ChatList`) Horizontal Dock (`Filter` + `Search` Hybrid / Compact Navigation)

    @ViewBuilder
    private var chatListHorizontalItems: some View {
        if !isSplitLeadingColumn {
            // Single-column compact iPhone: leading stationary `Home/Sidebar` button (`56×56pt`)
            standaloneDockCircleButton(
                id: "sidebar",
                symbol: "chevron.left",
                label: "Home sidebar"
            ) {
                onNavigateColumn(0)
            }
            .offset(x: panLeadBackOffset)
        }

        // Scope Filter Menu (`Filter` capsule — `All`, `Unread`, `Direct`, `Groups`)
        Menu {
            ForEach(SidebarScope.allCases) { scope in
                Button {
                    CuvenHaptics.selectionChanged()
                    withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
                        store.selectedSidebarScope = scope
                    }
                } label: {
                    HStack {
                        Text(scopeTitle(for: scope))
                        if store.selectedSidebarScope == scope {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            ZStack {
                if store.selectedSidebarScope != .all {
                    Circle()
                        .fill(CuvenColors.ctaInk)
                        .frame(width: 44, height: 44)
                }
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 18.5, weight: .semibold))
                    .foregroundStyle(store.selectedSidebarScope != .all ? CuvenColors.onCtaInk : CuvenColors.inkPrimary)
            }
            .frame(width: Self.dockHeight, height: Self.dockHeight)
            .contentShape(Circle())
            .cuvenLiquidGlass(
                mode: store.prefs.glassMode,
                cornerRadius: Self.dockHeight / 2,
                interactiveBounce: true
            )
        }
        .accessibilityIdentifier("shell.bottomDock.filter")
        .accessibilityLabel("Filter chats, current: \(scopeTitle(for: store.selectedSidebarScope))")

        // Expanding `Search` Liquid Glass capsule (`chatList.js:144-163` `.search-pill`) -> `GlobalSearchSheet`
        Button {
            CuvenHaptics.lightTap()
            onPresentModal(.globalSearch)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16.5, weight: .medium))
                    .foregroundStyle(CuvenColors.inkSecondary)

                Text(isSplitLeadingColumn ? "Search" : "Search chats")
                    .font(CuvenFonts.cappedBody())
                    .foregroundStyle(CuvenColors.inkSecondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if store.selectedSidebarScope != .all {
                    Text(scopeTitle(for: store.selectedSidebarScope))
                        .font(CuvenFonts.cappedCaption(weight: .semibold))
                        .foregroundStyle(CuvenColors.sidebarBlue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(CuvenColors.sidebarBlue.opacity(0.12), in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: Self.dockHeight, maxHeight: Self.dockHeight)
            .contentShape(Capsule())
            .cuvenLiquidGlass(
                mode: store.prefs.glassMode,
                cornerRadius: Self.dockHeight / 2,
                interactiveBounce: true
            )
        }
        .buttonStyle(DuoDockPressStyle())
        .accessibilityIdentifier("shell.bottomDock.search")
        .accessibilityLabel("Search chats, messages, and people")

        if !isSplitLeadingColumn {
            // Compact iPhone quick place capsule (`Moments` + `Friends / New Chat`)
            HStack(spacing: 2) {
                dockIconButton(
                    id: "moments",
                    symbol: "photo.on.rectangle.angled",
                    label: "Moments"
                ) {
                    store.navigateToPage(.moments)
                }

                dockIconButton(
                    id: "friends",
                    symbol: "square.and.pencil",
                    label: "Friends and new chat",
                    badge: pendingRequestCount > 0 ? "\(min(9, pendingRequestCount))" : nil
                ) {
                    onPresentModal(.friendsAndRequests)
                }
            }
            .padding(6)
            .frame(height: Self.dockHeight)
            .cuvenLiquidGlass(
                mode: store.prefs.glassMode,
                cornerRadius: Self.dockHeight / 2,
                interactiveBounce: false
            )
        }
    }

    // MARK: - Column 3 (`Artifact` Room Info) Horizontal Dock

    @ViewBuilder
    private var artifactHorizontalItems: some View {
        standaloneDockCircleButton(
            id: isSplitLeadingColumn ? "close" : "back",
            symbol: metrics.visibleColumnCount == 1 ? "chevron.left" : "xmark",
            label: metrics.visibleColumnCount == 1 ? "Back to conversation" : "Close details"
        ) {
            store.closeArtifact()
        }
        .offset(x: metrics.visibleColumnCount == 1 ? panLeadBackOffset : 0)

        Spacer(minLength: 0)
    }

    // MARK: - Shared Button Builders

    @ViewBuilder
    private func standaloneDockCircleButton(
        id: String,
        symbol: String,
        label: String,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button {
            CuvenHaptics.lightTap()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(CuvenColors.inkPrimary)
                .frame(width: Self.dockHeight, height: Self.dockHeight)
                .contentShape(Circle())
                .cuvenLiquidGlass(
                    mode: store.prefs.glassMode,
                    cornerRadius: Self.dockHeight / 2,
                    interactiveBounce: true
                )
        }
        .buttonStyle(DuoDockPressStyle())
        .accessibilityIdentifier("shell.bottomDock.\(id)")
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func dockIconButton(
        id: String,
        symbol: String,
        label: String,
        badge: String? = nil,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button {
            CuvenHaptics.lightTap()
            action()
        } label: {
            ZStack {
                Image(systemName: symbol)
                    .font(.system(size: 18.5, weight: .medium))
                    .foregroundStyle(CuvenColors.inkPrimary)

                if let badge, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(CuvenColors.dangerRed, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .offset(x: 2, y: 2)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(DuoDockPressStyle())
        .accessibilityIdentifier("shell.bottomDock.\(id)")
        .accessibilityLabel(label)
    }

    private func scopeTitle(for scope: SidebarScope) -> String {
        switch scope {
        case .all: return "All"
        case .unread: return "Unread"
        case .direct: return "Direct"
        case .groups: return "Groups"
        }
    }
}

// MARK: - iPhone Duo Right-Edge System Column Chrome (`DuoRailView` + `PagesCapsuleView`)

/// Positions `DuoRailView` (`shell.duoRail`, `52pt` wide, centered `49pt` from right physical edge)
/// and `PagesCapsuleView` (`shell.pagesCapsule`, `52×282pt` at foot) inside iPhone Duo's right-edge
/// status/camera column, honoring `170pt` (`duoClosed` portrait) / `118pt` (`duoOpen` / `duoHalfBook`)
/// top camera+clock reserves and keyboard state.
public struct DuoRightEdgeChromeOverlay: View {
    private let store: AppStore
    public let metrics: DuoLayoutMetrics
    public let windowStartColumn: Int
    public let panLeadBackOffset: CGFloat
    public let isFullPageOverlayActive: Bool
    public let onNavigateColumn: (Int) -> Void
    public let onSelectPage: (NavigationPage) -> Void
    public let onPresentModal: (CuvenShellModalDestination) -> Void

    @Environment(\.cuvenKeyboardHeight) private var keyboardHeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        store: AppStore,
        metrics: DuoLayoutMetrics,
        windowStartColumn: Int,
        panLeadBackOffset: CGFloat = 0,
        isFullPageOverlayActive: Bool,
        onNavigateColumn: @escaping (Int) -> Void,
        onSelectPage: @escaping (NavigationPage) -> Void,
        onPresentModal: @escaping (CuvenShellModalDestination) -> Void
    ) {
        self.store = store
        self.metrics = metrics
        self.windowStartColumn = windowStartColumn
        self.panLeadBackOffset = panLeadBackOffset
        self.isFullPageOverlayActive = isFullPageOverlayActive
        self.onNavigateColumn = onNavigateColumn
        self.onSelectPage = onSelectPage
        self.onPresentModal = onPresentModal
    }

    /// Exact trailing distance from the physical right screen edge so the `52pt` rail's centerline sits
    /// at `49pt` (`rail.css:41-43`: `max(4, min(49, safeRight - 34) - 26)` -> `23pt` on `84pt`/`91pt` Duo).
    public static func trailingEdgeOffset(for metrics: DuoLayoutMetrics) -> CGFloat {
        let effectiveSafeRight = max(metrics.safeAreaRight, metrics.posture == .duoClosed ? 91 : 84)
        let centerFromRight = min(metrics.railCenterFromRight, effectiveSafeRight - 34)
        return max(4, centerFromRight - DuoRailView.railWidth / 2)
    }

    private var isKeyboardVisible: Bool {
        keyboardHeight > 40
    }

    /// Determines whether `PagesCapsuleView` (`shell.pagesCapsule`) is shown (`pages.js:90-95`, `shell.js:87-99`):
    /// - Hidden while software keyboard is up (`pages.css:34`).
    /// - Shown over any full-page place overlay (`Moments`, `Memories`, `Friends`, `You`) so switching places is 1 tap.
    /// - In 2-column split (`duoOpen` / `duoHalfBook`), shown whenever `DrawingBoard` is NOT occupying the trailing rail.
    /// - In 1-column `duoClosed`, shown on `Sidebar` (`0`) and `ChatList` (`1`); hidden inside `Thread` (`2`) and
    ///   `Artifact` (`3`) so the conversation composer & details own the full height cleanly.
    public var shouldShowPagesCapsule: Bool {
        guard metrics.hasRightSystemColumn, !isKeyboardVisible else { return false }
        if isFullPageOverlayActive {
            return true
        }
        if metrics.visibleColumnCount >= 2 {
            let trailingCol = min(3, windowStartColumn + 1)
            if trailingCol == 3 && store.activeArtifactMode == .drawingBoard {
                return false
            }
            return true
        } else {
            return store.activeColumnIndex <= 1
        }
    }

    /// Column index whose contextual actions populate `DuoRailView`:
    /// in 1-column `duoClosed`, the active column; in 2-column `duoOpen` / `duoHalfBook`, the trailing (right) column.
    private var railedColumnIndex: Int {
        if metrics.visibleColumnCount >= 2 {
            return min(3, windowStartColumn + 1)
        }
        return store.activeColumnIndex
    }

    private var isOuterLandscape: Bool {
        metrics.posture == .duoClosed && metrics.viewportSize.width > metrics.viewportSize.height
    }

    private var railTopPadding: CGFloat {
        max(metrics.safeAreaTop, metrics.railTopReserve)
    }

    private var pagesBottomPadding: CGFloat {
        max(metrics.safeAreaBottom, isOuterLandscape ? 64 : 14)
    }

    private var railBottomPadding: CGFloat {
        if isKeyboardVisible {
            return keyboardHeight + 4
        }
        let baseFoot = pagesBottomPadding
        if shouldShowPagesCapsule {
            return baseFoot + PagesCapsuleView.capsuleHeight + 12
        }
        return baseFoot
    }

    public var body: some View {
        if metrics.hasRightSystemColumn {
            let rightInset = Self.trailingEdgeOffset(for: metrics)
            let railConfig = buildRailGroups(for: railedColumnIndex)

            ZStack(alignment: .bottomTrailing) {
                // 1. Contextual Column `DuoRailView` (`shell.duoRail`) — steps aside (`opacity 0`) when a
                // full-page overlay (`Moments`, `Memories`, etc.) owns the canvas (`pages.css:92`).
                // Stationary in viewport coordinates (`panLeadBackOffset: 0` -> 0.0pt drift during swipe-back).
                if !isFullPageOverlayActive && (!railConfig.top.isEmpty || !railConfig.bottom.isEmpty) {
                    DuoRailView(
                        topGroups: railConfig.top,
                        bottomGroups: railConfig.bottom,
                        glassMode: store.prefs.glassMode,
                        panLeadBackOffset: 0
                    )
                    .padding(.top, railTopPadding)
                    .padding(.bottom, railBottomPadding)
                    .padding(.trailing, rightInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.opacity)
                }

                // 2. Bottom 6-Item `PagesCapsuleView` (`shell.pagesCapsule`, `52×282pt`)
                if shouldShowPagesCapsule {
                    PagesCapsuleView(
                        store: store,
                        metrics: metrics,
                        onSelectPage: onSelectPage
                    )
                    .padding(.bottom, pagesBottomPadding)
                    .padding(.trailing, rightInset)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.95, anchor: .bottom))
                    )
                }
            }
            .frame(
                width: metrics.viewportSize.width,
                height: metrics.viewportSize.height,
                alignment: .bottomTrailing
            )
        }
    }

    // MARK: - Contextual Rail Group Builder (`sidebar.js`, `chatList.js`, `thread.js`, `artifact.js`)

    private func buildRailGroups(for column: Int) -> (top: [DuoActionBarGroup], bottom: [DuoActionBarGroup]) {
        let isSinglePane = (metrics.visibleColumnCount == 1)

        switch column {
        case 0:
            // Sidebar (`Home`) on `duoClosed`
            let search = DuoActionBarItem(
                id: "search",
                systemImage: "magnifyingglass",
                title: "Search chats",
                priority: 6,
                action: { onPresentModal(.globalSearch) }
            )
            let settings = DuoActionBarItem(
                id: "settings",
                systemImage: "gearshape",
                title: "Settings",
                priority: 4,
                action: { onPresentModal(.settings) }
            )
            return (
                top: [DuoActionBarGroup(id: "sidebar.top", items: [search, settings])],
                bottom: []
            )

        case 1:
            // ChatList (`Messages`) — `duoClosed` or trailing beside `Sidebar`
            var topGroups: [DuoActionBarGroup] = []
            if isSinglePane {
                topGroups.append(
                    DuoActionBarGroup(
                        id: "list.back",
                        items: [
                            DuoActionBarItem(
                                id: "back",
                                systemImage: "chevron.left",
                                title: "Home sidebar",
                                isPrimaryNavigation: true,
                                action: { onNavigateColumn(0) }
                            )
                        ]
                    )
                )
            }
            topGroups.append(
                DuoActionBarGroup(
                    id: "list.actions",
                    items: [
                        DuoActionBarItem(
                            id: "newChat",
                            systemImage: "square.and.pencil",
                            title: "Friends and new chat",
                            priority: 6,
                            action: { onPresentModal(.friendsAndRequests) }
                        ),
                        DuoActionBarItem(
                            id: "filterCycle",
                            systemImage: "line.3.horizontal.decrease",
                            title: "Cycle chat filter",
                            priority: 4,
                            isActive: store.selectedSidebarScope != .all,
                            action: { cycleSidebarScope() }
                        )
                    ]
                )
            )
            return (top: topGroups, bottom: [])

        case 2:
            // Conversation (`Thread`) — `duoClosed` single pane OR `duoOpen` / `duoHalfBook` trailing pane!
            var topGroups: [DuoActionBarGroup] = []
            if isSinglePane {
                let otherUnread = totalUnreadExcludingSelected()
                topGroups.append(
                    DuoActionBarGroup(
                        id: "thread.back",
                        items: [
                            DuoActionBarItem(
                                id: "back",
                                systemImage: "chevron.left",
                                title: "Back to chats",
                                isPrimaryNavigation: true,
                                badgeText: otherUnread > 0 ? (otherUnread > 99 ? "99+" : "\(otherUnread)") : nil,
                                action: { onNavigateColumn(1) }
                            )
                        ]
                    )
                )
            }

            if let roomID = store.selectedRoomID ?? store.rooms.first(where: { !$0.isHidden })?.id {
                topGroups.append(
                    DuoActionBarGroup(
                        id: "thread.calls",
                        items: [
                            DuoActionBarItem(
                                id: "audio",
                                systemImage: "phone",
                                title: "Voice call",
                                priority: 6,
                                action: { store.startCall(in: roomID, mediaKind: .audio) }
                            ),
                            DuoActionBarItem(
                                id: "video",
                                systemImage: "video",
                                title: "Video call",
                                priority: 5,
                                action: { store.startCall(in: roomID, mediaKind: .video) }
                            )
                        ]
                    )
                )
                topGroups.append(
                    DuoActionBarGroup(
                        id: "thread.tools",
                        items: [
                            DuoActionBarItem(
                                id: "info",
                                systemImage: "info.circle",
                                title: "Chat info",
                                priority: 4,
                                isActive: store.activeArtifactMode == .roomInfo,
                                action: { toggleArtifact(.roomInfo, for: roomID) }
                            ),
                            DuoActionBarItem(
                                id: "draw",
                                systemImage: "pencil.and.scribble",
                                title: "Drawing board",
                                priority: 3,
                                isActive: store.activeArtifactMode == .drawingBoard,
                                action: { toggleArtifact(.drawingBoard, for: roomID) }
                            )
                        ]
                    )
                )
            } else {
                topGroups.append(
                    DuoActionBarGroup(
                        id: "thread.empty",
                        items: [
                            DuoActionBarItem(
                                id: "newChat",
                                systemImage: "square.and.pencil",
                                title: "Start a chat",
                                priority: 5,
                                action: { onPresentModal(.friendsAndRequests) }
                            )
                        ]
                    )
                )
            }
            return (top: topGroups, bottom: [])

        case 3:
            // Artifact (`Room Info` or `Drawing Board`)
            let leadID = isSinglePane ? "back" : "close"
            let leadIcon = isSinglePane ? "chevron.left" : "xmark"
            let leadTitle = isSinglePane ? "Back to conversation" : "Close details"
            var topGroups: [DuoActionBarGroup] = [
                DuoActionBarGroup(
                    id: "artifact.lead",
                    items: [
                        DuoActionBarItem(
                            id: leadID,
                            systemImage: leadIcon,
                            title: leadTitle,
                            isPrimaryNavigation: true,
                            action: { store.closeArtifact() }
                        )
                    ]
                )
            ]

            if let roomID = store.selectedRoomID ?? store.rooms.first(where: { !$0.isHidden })?.id {
                topGroups.append(
                    DuoActionBarGroup(
                        id: "artifact.mode",
                        items: [
                            DuoActionBarItem(
                                id: "roomInfo",
                                systemImage: "info.circle",
                                title: "Room info",
                                priority: 5,
                                isActive: store.activeArtifactMode == .roomInfo,
                                action: { store.openArtifact(.roomInfo, for: roomID) }
                            ),
                            DuoActionBarItem(
                                id: "drawingBoard",
                                systemImage: "pencil.and.scribble",
                                title: "Drawing board",
                                priority: 4,
                                isActive: store.activeArtifactMode == .drawingBoard,
                                action: { store.openArtifact(.drawingBoard, for: roomID) }
                            )
                        ]
                    )
                )
            }
            return (top: topGroups, bottom: [])

        default:
            return (top: [], bottom: [])
        }
    }

    private func toggleArtifact(_ mode: ArtifactMode, for roomID: String) {
        if store.selectedRoomID != roomID {
            store.selectRoom(roomID)
        }
        if store.activeArtifactMode == mode && (store.activeColumnIndex == 3 || metrics.visibleColumnCount == 2) {
            store.closeArtifact()
        } else {
            store.openArtifact(mode, for: roomID)
        }
    }

    private func cycleSidebarScope() {
        let all = SidebarScope.allCases
        guard let idx = all.firstIndex(of: store.selectedSidebarScope) else {
            store.selectedSidebarScope = .all
            return
        }
        store.selectedSidebarScope = all[(idx + 1) % all.count]
    }

    private func totalUnreadExcludingSelected() -> Int {
        let current = store.selectedRoomID
        return store.rooms.reduce(into: 0) { sum, room in
            guard !room.isHidden, room.id != current else { return }
            sum += max(room.unreadCount, room.isMarkedUnread ? 1 : 0)
        }
    }
}

private struct DuoDockPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1.0)
            .animation(
                CuvenSprings.adaptive(CuvenSprings.pressBounce, reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }
}

import SwiftUI
import CuvenCore

// MARK: - Column 1: Cuven Inbox ("Messages") Root Column (`PROJECT.md § 5.4`)
//
// Grounding References:
// - Apple Human Interface Guidelines: Designing for iPhone Duo & Split Views (adaptive 1-column
//   stack & `duoClosed` clearing the 84–91pt right system column vs 2-column `342pt` `duoOpen` /
//   `462pt` `duoHalfBook` leading split pane with gliding active-room selection capsule)
// - Apple Human Interface Guidelines: Materials / Liquid Glass, Motion, Gestures & Accessibility
//   (>= 44×44pt touch regions, capped Dynamic Type chrome, Reduce Motion fallbacks, VoiceOver actions)
// - Cuven Web Reference: `public/js/views/chatList.js`, `public/js/views/people.js`,
//   `public/js/views/insights.js`, `public/css/list.css`, `public/css/people.css`, `public/css/insights.css`

public struct ChatListColumnView: View {
    private enum InboxFilterTab: String, CaseIterable, Identifiable {
        case all
        case unread
        case direct
        case groups
        case requests

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .unread: return "Unread"
            case .direct: return "Direct"
            case .groups: return "Groups"
            case .requests: return "Requests"
            }
        }

        var sidebarScope: SidebarScope? {
            switch self {
            case .all: return .all
            case .unread: return .unread
            case .direct: return .direct
            case .groups: return .groups
            case .requests: return nil
            }
        }

        init(scope: SidebarScope) {
            switch scope {
            case .all: self = .all
            case .unread: self = .unread
            case .direct: self = .direct
            case .groups: self = .groups
            }
        }
    }

    private struct DeletedRoomUndoState: Equatable {
        let room: Room
        let token: UUID
    }

    private let store: AppStore
    private let metrics: DuoLayoutMetrics

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Namespace private var filterThumbNamespace
    @Namespace private var activeRowSelectionNamespace

    @State private var selectedFilterTab: InboxFilterTab
    @State private var openSwipedRoomID: String?
    @State private var isShowingGlobalSearch = false
    @State private var isShowingFriendsSheet = false
    @State private var isShowingSettingsSheet = false
    @State private var isHeaderCollapsed = false
    @State private var undoState: DeletedRoomUndoState?
    @State private var undoDismissTask: Task<Void, Never>?

    public init(store: AppStore, metrics: DuoLayoutMetrics) {
        self.store = store
        self.metrics = metrics
        self._selectedFilterTab = State(initialValue: InboxFilterTab(scope: store.selectedSidebarScope))
    }

    // MARK: - Spatial Geometry & Safe Insets (`list.css:20, 102, 224-239`)

    private var isSplitMode: Bool {
        metrics.visibleColumnCount >= 2
    }

    private var headerHorizontalInset: CGFloat {
        isSplitMode ? 18 : 20
    }

    /// `10pt` outer row margin matches `list.css:102, 230` so rows measure `322pt` inside `342pt` `duoOpen` (`342 ± 28pt`).
    private var rowContainerHorizontalInset: CGFloat {
        10
    }

    private var trailingSafePadding: CGFloat {
        ChatListSpatialMetrics.trailingSystemColumnInset(for: metrics)
    }

    private var topHeaderPadding: CGFloat {
        max(metrics.safeAreaTop, 12) + (isSplitMode ? 16 : 20)
    }

    private var bottomScrollPadding: CGFloat {
        max(metrics.safeAreaBottom, 16) + 88
    }

    // MARK: - Filtered & Sorted Conversations

    private var trimmedDockSearchQuery: String {
        store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isInlineDockSearchActive: Bool {
        !trimmedDockSearchQuery.isEmpty
    }

    private var visibleSortedRooms: [Room] {
        store.rooms
            .filter { !$0.isHidden }
            .sorted { lhs, rhs in
                if lhs.lastMessageTimestamp != rhs.lastMessageTimestamp {
                    return lhs.lastMessageTimestamp > rhs.lastMessageTimestamp
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    private var filteredRooms: [Room] {
        switch selectedFilterTab {
        case .all:
            return visibleSortedRooms
        case .unread:
            return visibleSortedRooms.filter { $0.unreadCount > 0 || $0.isMarkedUnread }
        case .direct:
            return visibleSortedRooms.filter { $0.kind == .dm }
        case .groups:
            return visibleSortedRooms.filter { $0.kind == .group }
        case .requests:
            return []
        }
    }

    private var pinnedRooms: [Room] {
        guard selectedFilterTab == .all else { return [] }
        return Array(filteredRooms.filter(\.isPinned).prefix(12))
    }

    /// Mirrors `chatList.js:465`: unpinned conversations populate `.rows` while pinned conversations
    /// occupy `PinnedConversationsGridView`; falls back to `filteredRooms` if 100% of rooms are pinned.
    private var displayedRowRooms: [Room] {
        guard selectedFilterTab != .requests else { return [] }
        if selectedFilterTab == .all {
            let unpinned = filteredRooms.filter { !$0.isPinned }
            return unpinned.isEmpty ? filteredRooms : unpinned
        }
        return filteredRooms
    }

    private var inlineSearchMatchedRooms: [Room] {
        guard isInlineDockSearchActive else { return [] }
        return visibleSortedRooms.filter { room in
            room.title.localizedCaseInsensitiveContains(trimmedDockSearchQuery)
                || room.subtitle.localizedCaseInsensitiveContains(trimmedDockSearchQuery)
                || room.lastMessagePreview.localizedCaseInsensitiveContains(trimmedDockSearchQuery)
        }
    }

    private var incomingRequestsCount: Int {
        store.contacts.reduce(into: 0) { count, item in
            if item.status == .pendingIn { count += 1 }
        }
    }

    private var hasFreshMoments: Bool {
        !store.moments.isEmpty
    }

    // MARK: - Body

    public var body: some View {
        ZStack(alignment: .top) {
            CuvenColors.paperBackground
                .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    // Scroll offset probe for collapsed inline title bar (`chatList.js:244-256`)
                    GeometryReader { proxy in
                        Color.clear
                            .preference(
                                key: ChatListScrollMinYKey.self,
                                value: proxy.frame(in: .named("chatlist.scrollSpace")).minY
                            )
                    }
                    .frame(height: 0)

                    chatListHeader

                    if store.isBootstrapping && store.rooms.isEmpty {
                        ChatListBootstrapSkeletonView(
                            isSplitMode: isSplitMode,
                            leadingInset: rowContainerHorizontalInset + metrics.safeAreaLeft,
                            trailingInset: rowContainerHorizontalInset + trailingSafePadding
                        )
                        .padding(.top, 8)
                    } else if isInlineDockSearchActive {
                        inlineDockSearchResultsSection
                    } else {
                        standardInboxContent
                    }
                }
                .padding(.top, topHeaderPadding)
                .padding(.bottom, bottomScrollPadding)
            }
            .coordinateSpace(name: "chatlist.scrollSpace")
            .simultaneousGesture(
                DragGesture(minimumDistance: 14)
                    .onChanged { value in
                        // Close any open swiped row when vertical scrolling begins (`chatList.js:254`)
                        if openSwipedRoomID != nil && abs(value.translation.height) > abs(value.translation.width) {
                            openSwipedRoomID = nil
                        }
                    }
            )
            .onPreferenceChange(ChatListScrollMinYKey.self) { minY in
                let shouldCollapse = minY < -38
                if shouldCollapse != isHeaderCollapsed {
                    if reduceMotion {
                        isHeaderCollapsed = shouldCollapse
                    } else {
                        withAnimation(.easeOut(duration: 0.18)) {
                            isHeaderCollapsed = shouldCollapse
                        }
                    }
                }
            }

            if isHeaderCollapsed {
                collapsedInlineTopBar
                    .transition(.opacity)
            }

            if let currentUndo = undoState {
                VStack {
                    Spacer()
                    undoToastView(for: currentUndo)
                        .padding(.leading, 16 + metrics.safeAreaLeft)
                        .padding(.trailing, 16 + trailingSafePadding)
                        .padding(.bottom, max(metrics.safeAreaBottom, 16) + 68)
                }
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .cuvenCappedDynamicType()
        .onChange(of: store.selectedSidebarScope) { _, newScope in
            let mapped = InboxFilterTab(scope: newScope)
            if selectedFilterTab != mapped {
                if reduceMotion {
                    selectedFilterTab = mapped
                } else {
                    withAnimation(CuvenSprings.railMorph) {
                        selectedFilterTab = mapped
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingGlobalSearch) {
            GlobalSearchSheet(store: store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(30)
        }
        .sheet(isPresented: $isShowingFriendsSheet) {
            FriendRequestsAndPeopleSheet(store: store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(30)
        }
        .sheet(isPresented: $isShowingSettingsSheet) {
            SettingsRootSheet(store: store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(30)
        }
    }

    // MARK: - Header & Collapsed Inline Top Bar (`list.css:4-57`)

    private var chatListHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Messages")
                    .font(isSplitMode ? CuvenFonts.cappedTitle1() : CuvenFonts.cappedLargeTitle())
                    .foregroundStyle(ChatListPalette.messagesTitleBlue)
                    .lineLimit(1)

                if !store.isDemoMode && !store.isWebSocketConnected && !store.isBootstrapping {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                        Text("Connecting…")
                            .font(CuvenFonts.cappedCaption2(weight: .medium))
                            .foregroundStyle(CuvenColors.inkSecondary)
                    }
                    .accessibilityLabel("Reconnecting to server")
                }
            }

            Spacer(minLength: 4)

            // Moments quick-jump button on standard iPhone where PagesCapsule is absent (`chatList.js:49-55`)
            if !metrics.hasRightSystemColumn {
                Button {
                    CuvenHaptics.lightTap()
                    store.navigateToPage(.moments)
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(CuvenColors.inkPrimary)
                            .frame(width: 40, height: 40)
                            .cuvenLiquidGlass(mode: store.prefs.glassMode, cornerRadius: 20, interactiveBounce: true)

                        if hasFreshMoments {
                            Circle()
                                .fill(CuvenColors.freshMomentsDot)
                                .frame(width: 9, height: 9)
                                .overlay(Circle().strokeBorder(CuvenColors.paperBackground, lineWidth: 1.8))
                                .offset(x: -1, y: 1)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(hasFreshMoments ? "Moments, new from friends" : "Moments")
                .accessibilityIdentifier("chatlist.momentsButton")
            }

            // Profile / Settings quick button when Sidebar is off-screen in split mode (`list.css:49-52`)
            if isSplitMode {
                Button {
                    CuvenHaptics.lightTap()
                    isShowingSettingsSheet = true
                } label: {
                    CuvenAvatarView(
                        name: store.currentUser?.display ?? "Me",
                        urlString: store.currentUser?.avatarURL,
                        size: 36,
                        isOnline: true
                    )
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("chatlist.profileButton")
            }

            // Frosted Facebook-Blue Global Search Button (`list.css:27-48`, `PROJECT.md § 5.5`)
            Button {
                CuvenHaptics.lightTap()
                openSwipedRoomID = nil
                isShowingGlobalSearch = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle()
                            .fill(ChatListPalette.filterGlassBlue)
                            .shadow(
                                color: ChatListPalette.facebookBlue.opacity(0.28),
                                radius: 8,
                                x: 0,
                                y: 4
                            )
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.7)
                    )
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search")
            .accessibilityIdentifier("chatlist.searchButton")

            // Unified Friends / Requests / New Group Button (`PROJECT.md § 5.5` `chatlist.newChatButton`)
            Button {
                CuvenHaptics.lightTap()
                openSwipedRoomID = nil
                isShowingFriendsSheet = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .frame(width: 40, height: 40)
                        .cuvenLiquidGlass(mode: store.prefs.glassMode, cornerRadius: 20, interactiveBounce: true)

                    if incomingRequestsCount > 0 {
                        Text(incomingRequestsCount > 99 ? "99+" : "\(incomingRequestsCount)")
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Capsule().fill(CuvenColors.dangerRed))
                            .overlay(Capsule().strokeBorder(CuvenColors.paperBackground, lineWidth: 2))
                            .offset(x: 4, y: -3)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                incomingRequestsCount > 0
                    ? "Friends and new chat, \(incomingRequestsCount) pending requests"
                    : "Friends and new chat"
            )
            .accessibilityIdentifier("chatlist.newChatButton")
        }
        .padding(.leading, headerHorizontalInset + metrics.safeAreaLeft)
        .padding(.trailing, headerHorizontalInset + trailingSafePadding)
        .padding(.bottom, 2)
    }

    private var collapsedInlineTopBar: some View {
        VStack(spacing: 0) {
            HStack {
                Text(
                    selectedFilterTab == .all
                        ? "Messages"
                        : "Messages · \(selectedFilterTab.title)"
                )
                .font(CuvenFonts.cappedSubhead(weight: .semibold))
                .foregroundStyle(CuvenColors.inkPrimary)
                .lineLimit(1)

                Spacer()
            }
            .padding(.leading, headerHorizontalInset + metrics.safeAreaLeft)
            .padding(.trailing, headerHorizontalInset + trailingSafePadding)
            .padding(.top, max(metrics.safeAreaTop, 10) + 6)
            .padding(.bottom, 10)
            .background(.ultraThinMaterial)

            Rectangle()
                .fill(CuvenColors.hairlineSeparator)
                .frame(height: 0.6)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Standard Inbox Stack (`chatList.js:107`)

    @ViewBuilder
    private var standardInboxContent: some View {
        if selectedFilterTab == .all {
            NotesStripView(store: store, metrics: metrics)

            SmartInsightsDeckView(store: store, metrics: metrics)
        }

        filterTabsStrip

        if selectedFilterTab != .all && selectedFilterTab != .requests && !filteredRooms.isEmpty {
            HStack(spacing: 6) {
                Text("Showing \(selectedFilterTab.title.lowercased()) conversations")
                    .font(CuvenFonts.cappedFootnote())
                    .foregroundStyle(CuvenColors.inkSecondary)

                Button {
                    selectFilterTab(.all)
                } label: {
                    Text("Show all")
                        .font(CuvenFonts.cappedFootnote(weight: .semibold))
                        .foregroundStyle(ChatListPalette.accessibleBlueText)
                        .frame(minHeight: 36)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, headerHorizontalInset + metrics.safeAreaLeft)
            .padding(.trailing, headerHorizontalInset + trailingSafePadding)
        }

        if selectedFilterTab == .all && !pinnedRooms.isEmpty {
            PinnedConversationsGridView(
                store: store,
                rooms: pinnedRooms,
                metrics: metrics,
                onDeleteRoom: { room in
                    performRoomDeleteWithUndo(room)
                }
            )
        }

        if selectedFilterTab == .requests {
            InboxPeopleDiscoverySectionView(
                store: store,
                metrics: metrics,
                showRequestsInline: true,
                onOpenFriendsSheet: { isShowingFriendsSheet = true }
            )
        } else if filteredRooms.isEmpty {
            emptyConversationsView
        } else {
            LazyVStack(spacing: isSplitMode ? 2 : 3) {
                ForEach(displayedRowRooms) { room in
                    ChatListRowView(
                        store: store,
                        room: room,
                        metrics: metrics,
                        activeSelectionNamespace: activeRowSelectionNamespace,
                        openSwipedRoomID: $openSwipedRoomID,
                        onDeleteRoom: { target in
                            performRoomDeleteWithUndo(target)
                        }
                    )
                }
            }
            .padding(.leading, rowContainerHorizontalInset + metrics.safeAreaLeft)
            .padding(.trailing, rowContainerHorizontalInset + trailingSafePadding)
        }

        if selectedFilterTab == .all {
            InboxPeopleDiscoverySectionView(
                store: store,
                metrics: metrics,
                showRequestsInline: false,
                onOpenFriendsSheet: { isShowingFriendsSheet = true }
            )
        }
    }

    // MARK: - Gliding `#1877F2` Frosted Filter Strip (`list.css:58-85`, `people.css:111-146`)

    private var filterTabsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(InboxFilterTab.allCases) { tab in
                    let isSelected = selectedFilterTab == tab
                    Button {
                        selectFilterTab(tab)
                    } label: {
                        HStack(spacing: 6) {
                            Text(tab.title)
                                .font(CuvenFonts.cappedSubhead(weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(
                                    isSelected
                                        ? Color.white
                                        : (tab == .requests && incomingRequestsCount > 0 ? CuvenColors.inkPrimary : CuvenColors.inkSecondary)
                                )

                            if tab == .requests && incomingRequestsCount > 0 {
                                Text(incomingRequestsCount > 99 ? "99+" : "\(incomingRequestsCount)")
                                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                                    .foregroundStyle(isSelected ? ChatListPalette.facebookBlue : Color.white)
                                    .padding(.horizontal, 6)
                                    .frame(minWidth: 20, minHeight: 20)
                                    .background(
                                        Capsule()
                                            .fill(isSelected ? Color.white : CuvenColors.dangerRed)
                                    )
                            }
                        }
                        .padding(.horizontal, isSplitMode ? 13 : 15)
                        .frame(height: 36)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(ChatListPalette.filterGlassBlue)
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(Color.white.opacity(0.26), lineWidth: 0.6)
                                    )
                                    .shadow(
                                        color: ChatListPalette.facebookBlue.opacity(0.24),
                                        radius: 6,
                                        x: 0,
                                        y: 3
                                    )
                                    .matchedGeometryEffect(
                                        id: "chatlist.filterThumb",
                                        in: filterThumbNamespace
                                    )
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                    .accessibilityIdentifier("chatlist.filter.\(tab.rawValue)")
                }
            }
            .padding(.leading, headerHorizontalInset + metrics.safeAreaLeft)
            .padding(.trailing, headerHorizontalInset + trailingSafePadding)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Inline Bottom-Dock Search Results (`chatList.js:810-918`)

    private var inlineDockSearchResultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SEARCH RESULTS")
                    .font(CuvenFonts.cappedCaption(weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(CuvenColors.inkSecondary)

                Spacer()

                Button {
                    CuvenHaptics.lightTap()
                    store.searchQuery = ""
                } label: {
                    Text("Cancel")
                        .font(CuvenFonts.cappedCaption(weight: .semibold))
                        .foregroundStyle(ChatListPalette.accessibleBlueText)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chatlist.inlineSearchCancel")
            }
            .padding(.leading, headerHorizontalInset + metrics.safeAreaLeft)
            .padding(.trailing, headerHorizontalInset + trailingSafePadding)

            if inlineSearchMatchedRooms.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(ChatListPalette.tertiaryInk)
                    Text("No results")
                        .font(CuvenFonts.cappedHeadline())
                        .foregroundStyle(CuvenColors.inkPrimary)
                    Text("Nothing matched “\(trimmedDockSearchQuery)”")
                        .font(CuvenFonts.cappedCaption())
                        .foregroundStyle(CuvenColors.inkSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            } else {
                LazyVStack(spacing: isSplitMode ? 2 : 3) {
                    ForEach(inlineSearchMatchedRooms) { room in
                        ChatListRowView(
                            store: store,
                            room: room,
                            metrics: metrics,
                            activeSelectionNamespace: activeRowSelectionNamespace,
                            openSwipedRoomID: $openSwipedRoomID,
                            onDeleteRoom: { target in
                                performRoomDeleteWithUndo(target)
                            }
                        )
                    }
                }
                .padding(.leading, rowContainerHorizontalInset + metrics.safeAreaLeft)
                .padding(.trailing, rowContainerHorizontalInset + trailingSafePadding)
            }
        }
    }

    // MARK: - Empty States (`list.css:141-155`)

    @ViewBuilder
    private var emptyConversationsView: some View {
        if selectedFilterTab == .all {
            HStack(spacing: 6) {
                Text("Your chats appear here.")
                    .font(CuvenFonts.cappedSubhead())
                    .foregroundStyle(CuvenColors.inkSecondary)

                Button {
                    CuvenHaptics.lightTap()
                    isShowingFriendsSheet = true
                } label: {
                    Text("Start")
                        .font(CuvenFonts.cappedSubhead(weight: .semibold))
                        .foregroundStyle(ChatListPalette.accessibleBlueText)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chatlist.emptyStartButton")
            }
            .padding(.leading, headerHorizontalInset + metrics.safeAreaLeft)
            .padding(.trailing, headerHorizontalInset + trailingSafePadding)
            .padding(.vertical, 10)
        } else {
            VStack(spacing: 10) {
                Image(systemName: emptyScopeSymbol)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(ChatListPalette.tertiaryInk)

                Text("No \(selectedFilterTab.title.lowercased()) chats")
                    .font(CuvenFonts.cappedHeadline())
                    .foregroundStyle(CuvenColors.inkPrimary)

                Text(emptyScopeSubtitle)
                    .font(CuvenFonts.cappedCaption())
                    .foregroundStyle(CuvenColors.inkSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 240)

                Button {
                    selectFilterTab(.all)
                } label: {
                    Text("Show all chats")
                        .font(CuvenFonts.cappedSubhead(weight: .semibold))
                        .foregroundStyle(CuvenColors.onCtaInk)
                        .padding(.horizontal, 20)
                        .frame(minHeight: 44)
                        .background(Capsule().fill(CuvenColors.ctaInk))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .padding(.leading, headerHorizontalInset + metrics.safeAreaLeft)
            .padding(.trailing, headerHorizontalInset + trailingSafePadding)
        }
    }

    private var emptyScopeSymbol: String {
        switch selectedFilterTab {
        case .unread: return "checkmark.message"
        case .direct: return "person.crop.circle"
        case .groups: return "person.3"
        case .all, .requests: return "bubble.left.and.bubble.right"
        }
    }

    private var emptyScopeSubtitle: String {
        switch selectedFilterTab {
        case .unread: return "You're all caught up — unread conversations will appear here."
        case .direct: return "Start a 1:1 conversation from Friends."
        case .groups: return "Create a group conversation from Friends."
        case .all, .requests: return ""
        }
    }

    // MARK: - 5-Second Undo Toast (`DISPATCH.md` Item 2 & `chatList.js:765-785`)

    private func undoToastView(for state: DeletedRoomUndoState) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "trash.slash.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(CuvenColors.inkSecondary)

            Text("Hidden “\(state.room.title)”")
                .font(CuvenFonts.cappedSubhead(weight: .medium))
                .foregroundStyle(CuvenColors.inkPrimary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                restoreDeletedRoom(state)
            } label: {
                Text("Undo")
                    .font(CuvenFonts.cappedSubhead(weight: .bold))
                    .foregroundStyle(ChatListPalette.accessibleBlueText)
                    .padding(.horizontal, 12)
                    .frame(minWidth: 56, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chatlist.undoButton")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(minHeight: 50)
        .cuvenLiquidGlass(mode: store.prefs.glassMode, cornerRadius: 25, interactiveBounce: false)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatlist.undoToast")
    }

    // MARK: - Actions

    private func selectFilterTab(_ tab: InboxFilterTab) {
        CuvenHaptics.selectionChanged()
        openSwipedRoomID = nil
        if reduceMotion {
            selectedFilterTab = tab
            if let scope = tab.sidebarScope {
                store.selectedSidebarScope = scope
            }
        } else {
            withAnimation(CuvenSprings.railMorph) {
                selectedFilterTab = tab
                if let scope = tab.sidebarScope {
                    store.selectedSidebarScope = scope
                }
            }
        }
    }

    private func performRoomDeleteWithUndo(_ room: Room) {
        undoDismissTask?.cancel()
        openSwipedRoomID = nil

        let snapshot = room
        let token = UUID()
        store.deleteOrHideRoom(room.id)

        if reduceMotion {
            undoState = DeletedRoomUndoState(room: snapshot, token: token)
        } else {
            withAnimation(CuvenSprings.sheetPresent) {
                undoState = DeletedRoomUndoState(room: snapshot, token: token)
            }
        }

        undoDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, undoState?.token == token else { return }
            if reduceMotion {
                undoState = nil
            } else {
                withAnimation(.easeOut(duration: 0.22)) {
                    undoState = nil
                }
            }
        }
    }

    private func restoreDeletedRoom(_ state: DeletedRoomUndoState) {
        undoDismissTask?.cancel()
        CuvenHaptics.softImpact()

        let restoreBlock = {
            if let index = store.rooms.firstIndex(where: { $0.id == state.room.id }) {
                store.rooms[index].isHidden = false
            } else {
                var restored = state.room
                restored.isHidden = false
                store.rooms.append(restored)
            }
            undoState = nil
        }

        if reduceMotion {
            restoreBlock()
        } else {
            withAnimation(CuvenSprings.railMorph) {
                restoreBlock()
            }
        }

        if !store.isDemoMode {
            let roomID = state.room.id
            let client = store.apiClient
            Task {
                try? await client.setRoomFlags(roomID: roomID, hidden: false)
            }
        }
    }
}

// MARK: - Scroll Offset Preference Key

private struct ChatListScrollMinYKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Bootstrap Shimmer Skeleton (`list.css:188-194`, `skeleton.js`)

private struct ChatListBootstrapSkeletonView: View {
    let isSplitMode: Bool
    let leadingInset: CGFloat
    let trailingInset: CGFloat

    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<6, id: \.self) { index in
                HStack(spacing: 12) {
                    Circle()
                        .fill(ChatListPalette.subtleChipFill)
                        .frame(width: isSplitMode ? 44 : 48, height: isSplitMode ? 44 : 48)

                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(ChatListPalette.subtleChipFill)
                            .frame(width: CGFloat(92 + (index % 3) * 28), height: 13)

                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(ChatListPalette.subtleChipFill)
                            .frame(maxWidth: .infinity)
                            .frame(height: 10)
                    }
                }
                .padding(.horizontal, isSplitMode ? 11 : 13)
                .padding(.vertical, isSplitMode ? 10 : 12)
                .frame(minHeight: isSplitMode ? 66 : 76)
            }
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, trailingInset)
        .cuvenSkeletonShimmer(active: true)
    }
}

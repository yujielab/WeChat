// MomentsRootView.swift
// Cuven — Native iOS & iPhone Duo App (iOS 27.1 SDK)
//
// Canonical Milestone M9 Entry Point (`PROJECT.md § 5.4` & `§ 5.5`):
// `public struct MomentsRootView: View { public init(store: AppStore, metrics: DuoLayoutMetrics, onClose: @escaping () -> Void) }`
//
// Apple HIG & iOS 27.1 SDK Grounding:
// - Designing for iPhone Duo:
//   * `iPhoneCompact` / `duoClosed` (`<700pt`): Single full-bleed editorial column (inset clear of `safeRight` on Duo Outer).
//   * `duoOpen` (`951x669pt`) / `iPhoneSplit`: Spacious centered editorial stream OR 2-column adaptive waterfall/feed
//     with full clearance for the right `84pt` `DuoRail` + `PagesCapsuleView`.
//   * `duoHalfBook`: Fold-aware book spread (`462pt | hinge | 461pt`) with Stories & Compose rail on left page and
//     Moment stream on right page, zero content straddling the crease!
//   * `duoHalfLaptop`: Tabletop split keeping feed stage above horizontal fold and quick compose/filter bar below.
// - Materials / Liquid Glass: Sky Blue (`#0099FF` / `#4CC2FF`) Clarinetta editorial header + floating Liquid Glass
//   Compose (`moments.composeButton`) & Close controls.

import SwiftUI
import CuvenCore

public struct MomentsRootView: View {
    private let store: AppStore
    private let metrics: DuoLayoutMetrics
    private let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var scrollOffsetY: CGFloat = 0
    @State private var prefersTwoColumnStreamOnWide: Bool = false
    @State private var lastSeenEpochMillis: Int64 = 0
    @State private var viewedAuthorIDs: Set<String> = []
    @State private var knownTopMomentID: String?
    @State private var hasUnseenLiveArrival: Bool = false

    // Modal & navigation destinations
    @State private var showComposeEditor: Bool = false
    @State private var selectedProfileUser: CuvenUser?
    @State private var activeLightbox: MomentLightboxRequest?
    @State private var scrollToTopTrigger: Int = 0

    private static let lastSeenDefaultsKey = "cuven.moments.lastSeenMillis"

    public init(
        store: AppStore,
        metrics: DuoLayoutMetrics,
        onClose: @escaping () -> Void
    ) {
        self.store = store
        self.metrics = metrics
        self.onClose = onClose
    }

    // MARK: - Spatial & Posture Geometry

    private var rightRailClearance: CGFloat {
        if metrics.hasRightSystemColumn {
            return max(metrics.safeAreaRight, metrics.railWidth + 24)
        }
        return metrics.safeAreaRight
    }

    private var isWideCanvas: Bool {
        metrics.posture == .duoOpen || metrics.posture == .iPhoneSplit || metrics.viewportSize.width >= 700
    }

    private var isHeaderScrolled: Bool {
        scrollOffsetY > 6
    }

    // MARK: - Privacy-Filtered Feed & Story Ring Entries

    private var visibleFeedMoments: [MomentPost] {
        let now = Date()
        let meID = store.currentUser?.id
        return store.moments
            .filter { post in
                // Future scheduled posts are visible only to their author (`moments-editor.cjs:121`)
                if let scheduled = post.scheduledAt, MomentsTimeFormatter.date(fromEpoch: scheduled) > now {
                    return post.author.id == meID
                }
                // Friends-only posts require friendship or authorship (`moments.cjs:55, 85`)
                if post.audience == "friends" {
                    return post.author.id == meID || isFriend(with: post.author.id)
                }
                return true
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var storyEntries: [MomentsStoryPersonEntry] {
        let meID = store.currentUser?.id
        var latestByUser: [String: (user: CuvenUser, timestamp: Int64)] = [:]

        for post in visibleFeedMoments where post.author.id != meID {
            if let existing = latestByUser[post.author.id] {
                if post.createdAt > existing.timestamp {
                    latestByUser[post.author.id] = (post.author, post.createdAt)
                }
            } else {
                latestByUser[post.author.id] = (post.author, post.createdAt)
            }
        }

        // Also surface accepted friends even if they haven't posted yet
        for contact in store.contacts where contact.status == .accepted && contact.user.id != meID {
            if latestByUser[contact.user.id] == nil {
                latestByUser[contact.user.id] = (contact.user, 0)
            }
        }

        return latestByUser.values
            .map { pair in
                let normalizedPostMillis = pair.timestamp > 10_000_000_000 ? pair.timestamp : pair.timestamp * 1000
                let fresh = normalizedPostMillis > lastSeenEpochMillis
                    && pair.timestamp > 0
                    && !viewedAuthorIDs.contains(pair.user.id)
                return MomentsStoryPersonEntry(
                    user: pair.user,
                    latestTimestamp: pair.timestamp,
                    isFresh: fresh,
                    isFriend: isFriend(with: pair.user.id)
                )
            }
            .sorted { lhs, rhs in
                if lhs.isFresh != rhs.isFresh {
                    return lhs.isFresh && !rhs.isFresh
                }
                return lhs.latestTimestamp > rhs.latestTimestamp
            }
            .prefix(24)
            .map { $0 }
    }

    private func isFriend(with userID: String) -> Bool {
        if store.currentUser?.id == userID { return true }
        if store.contacts.contains(where: { $0.user.id == userID && $0.status == .accepted }) {
            return true
        }
        if let dm = store.rooms.first(where: { $0.kind == .dm && ($0.peerUserID == userID || $0.memberIDs.contains(userID)) }) {
            let msgs = store.messagesByRoom[dm.id] ?? []
            if msgs.isEmpty { return true }
            let meSpoke = store.currentUser.map { me in msgs.contains(where: { $0.senderID == me.id }) } ?? false
            let peerSpoke = msgs.contains(where: { $0.senderID == userID })
            return meSpoke && peerSpoke
        }
        return false
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            CuvenColors.paperBackground
                .ignoresSafeArea()

            if let profileUser = selectedProfileUser {
                UserMomentsProfileView(
                    store: store,
                    user: profileUser,
                    metrics: metrics,
                    onBack: {
                        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : CuvenSprings.stripSlide) {
                            selectedProfileUser = nil
                        }
                    },
                    onOpenCompose: {
                        showComposeEditor = true
                    },
                    onStartChat: { targetUser in
                        startDirectChatAndExitMoments(with: targetUser)
                    }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                postureAdaptiveMomentsFeed
            }
        }
        .onAppear {
            let stored = Int64(UserDefaults.standard.double(forKey: Self.lastSeenDefaultsKey))
            lastSeenEpochMillis = stored
            knownTopMomentID = visibleFeedMoments.first?.id
            markMomentsSeenNow()
        }
        .onChange(of: visibleFeedMoments.first?.id) { oldTop, newTop in
            guard let newTop, newTop != oldTop, oldTop != nil else {
                knownTopMomentID = newTop
                return
            }
            if let newest = visibleFeedMoments.first {
                if newest.author.id == store.currentUser?.id {
                    scrollToTopTrigger &+= 1
                } else if scrollOffsetY > 140 {
                    hasUnseenLiveArrival = true
                }
            }
            knownTopMomentID = newTop
        }
        .cuvenAdaptiveModal(isPresented: $showComposeEditor, metrics: metrics, tall: true) {
            MomentsPostEditorSheet(
                store: store,
                metrics: metrics,
                onDismiss: { showComposeEditor = false }
            )
        }
        .fullScreenCover(item: $activeLightbox) { req in
            MomentMediaLightboxOverlay(
                store: store,
                post: req.post,
                initialIndex: req.initialIndex,
                onDismiss: { activeLightbox = nil }
            )
        }
    }

    // MARK: - Posture-Adaptive Feed Layouts (`iPhone`, `duoClosed`, `duoHalfBook`, `duoHalfLaptop`, `duoOpen`)

    @ViewBuilder
    private var postureAdaptiveMomentsFeed: some View {
        if metrics.posture == .duoHalfBook, let hinge = metrics.hingeDivisionRect {
            // Book fold (`462 | hinge | 461`): Left page holds editorial masthead + Stories + floating Compose;
            // Right page holds full Moment stream clear of crease & DuoRail!
            HStack(spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    VStack(alignment: .leading, spacing: 16) {
                        editorialMastheadBar(compactControls: true)
                        MomentsStoriesRowView(
                            currentUser: store.currentUser,
                            entries: storyEntries,
                            trailingInset: 14,
                            onComposeTap: { showComposeEditor = true },
                            onPersonTap: { openProfile(for: $0) }
                        )
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                    floatingComposeGlassButton
                        .padding(.trailing, 18)
                        .padding(.bottom, max(metrics.safeAreaBottom, 14) + 16)
                }
                .frame(width: max(280, hinge.minX))

                Color.clear
                    .frame(width: max(28, hinge.width))

                feedScrollView(includeStoriesInsideScroll: false, forceSingleColumn: true)
                    .frame(maxWidth: .infinity)
            }
        } else if metrics.posture == .duoHalfLaptop, let hinge = metrics.hingeDivisionRect {
            // Tabletop fold: Upper stage displays Moment cards; lower flat deck holds header + Stories + Compose
            VStack(spacing: 0) {
                feedScrollView(includeStoriesInsideScroll: false, forceSingleColumn: true)
                    .frame(height: max(240, hinge.minY))

                Color.clear
                    .frame(height: max(16, hinge.height))

                ZStack(alignment: .bottomTrailing) {
                    VStack(spacing: 8) {
                        editorialMastheadBar(compactControls: false)
                        MomentsStoriesRowView(
                            currentUser: store.currentUser,
                            entries: storyEntries,
                            trailingInset: rightRailClearance + 14,
                            onComposeTap: { showComposeEditor = true },
                            onPersonTap: { openProfile(for: $0) }
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                    floatingComposeGlassButton
                        .padding(.trailing, max(20, rightRailClearance + 16))
                        .padding(.bottom, max(metrics.safeAreaBottom, 12) + 12)
                }
                .frame(maxHeight: .infinity)
                .background(CuvenColors.elevatedSurface)
            }
        } else {
            // Standard iPhone, `duoClosed`, `iPhoneSplit`, and `duoOpen` (`951x669pt`)
            ZStack(alignment: .top) {
                feedScrollView(includeStoriesInsideScroll: true, forceSingleColumn: false)

                VStack(spacing: 8) {
                    editorialMastheadBar(compactControls: false)

                    if hasUnseenLiveArrival {
                        Button {
                            CuvenHaptics.lightTap()
                            hasUnseenLiveArrival = false
                            markMomentsSeenNow()
                            scrollToTopTrigger &+= 1
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 13, weight: .bold))
                                Text("New moments")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .foregroundStyle(CuvenColors.onCtaInk)
                            .padding(.horizontal, 16)
                            .frame(height: 36)
                            .background(CuvenColors.ctaInk, in: Capsule())
                            .shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("moments.newArrivalPill")
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }

                // Floating Liquid Glass Compose `+` button (`moments.composeButton`, `moments.css:61`)
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        floatingComposeGlassButton
                            .padding(.trailing, max(20, rightRailClearance + 16))
                            .padding(.bottom, max(metrics.safeAreaBottom, 14) + 16)
                    }
                }
            }
        }
    }

    // MARK: - Editorial Header (`Clarinetta` Sky Blue + Liquid Glass Controls)

    private func editorialMastheadBar(compactControls: Bool) -> some View {
        HStack(spacing: 10) {
            // Sky Blue `"Moments"` title (`#0099FF` light / `#4CC2FF` dark, `tokens.css:62,285`)
            Text("Moments")
                .font(CuvenFonts.clarinettaDisplay(size: 32, weight: .bold, italic: false))
                .foregroundStyle(MomentsPalette.skyTitle)
                .lineLimit(1)

            Spacer(minLength: 8)

            // 1-col Editorial vs 2-col Stream toggle on `duoOpen` / `iPhoneSplit`
            if isWideCanvas && !compactControls {
                Button {
                    CuvenHaptics.selectionChanged()
                    withAnimation(reduceMotion ? .easeOut(duration: 0.12) : CuvenSprings.railMorph) {
                        prefersTwoColumnStreamOnWide.toggle()
                    }
                } label: {
                    Image(systemName: prefersTwoColumnStreamOnWide ? "rectangle.grid.1x2" : "rectangle.grid.2x2")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .cuvenLiquidGlass(mode: store.prefs.glassMode, cornerRadius: 22, interactiveBounce: true)
                .accessibilityLabel(prefersTwoColumnStreamOnWide ? "Single editorial column" : "Two-column layout")
                .accessibilityIdentifier("moments.layoutToggle")
            }

            // `Your moments` avatar shortcut (hidden when Duo `PagesCapsuleView` already shows `You`, `moments.css:59`)
            if !metrics.hasRightSystemColumn, let me = store.currentUser {
                Button {
                    CuvenHaptics.selectionChanged()
                    openProfile(for: me)
                } label: {
                    CuvenAvatarView(
                        name: me.display.isEmpty ? me.username : me.display,
                        urlString: me.avatarURL,
                        size: 32,
                        isOnline: false
                    )
                    .padding(1.5)
                    .overlay {
                        Circle().strokeBorder(CuvenColors.inkPrimary, lineWidth: 1.5)
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Your moments")
                .accessibilityIdentifier("moments.myProfileButton")
            }

            // Liquid Glass `Close` button (`moments.js:110`)
            Button {
                CuvenHaptics.lightTap()
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(CuvenColors.inkPrimary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .cuvenLiquidGlass(mode: store.prefs.glassMode, cornerRadius: 22, interactiveBounce: true)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("moments.closeButton")
        }
        .padding(.leading, max(20, metrics.safeAreaLeft + 20))
        .padding(.trailing, compactControls ? 14 : max(14, rightRailClearance + 14))
        .padding(.top, max(12, metrics.safeAreaTop + 6))
        .padding(.bottom, 8)
        .background {
            if isHeaderScrolled {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(CuvenColors.hairlineSeparator)
                            .frame(height: 0.5)
                    }
                    .ignoresSafeArea(edges: .top)
            }
        }
    }

    private var floatingComposeGlassButton: some View {
        Button {
            CuvenHaptics.lightTap()
            showComposeEditor = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 23, weight: .bold))
                .foregroundStyle(CuvenColors.inkPrimary)
                .frame(width: 56, height: 56)
        }
        .buttonStyle(.plain)
        .cuvenLiquidGlass(mode: store.prefs.glassMode, cornerRadius: 28, interactiveBounce: true)
        .accessibilityLabel("New moment")
        .accessibilityIdentifier("moments.composeButton")
    }

    // MARK: - Feed Scroll Container (`moments.feed`)

    private func feedScrollView(includeStoriesInsideScroll: Bool, forceSingleColumn: Bool) -> some View {
        let availableContentWidth = metrics.viewportSize.width - metrics.safeAreaLeft - rightRailClearance
        let useCenteredEditorialColumn = isWideCanvas && !prefersTwoColumnStreamOnWide && !forceSingleColumn
        let useTwoColumnStream = isWideCanvas && prefersTwoColumnStreamOnWide && !forceSingleColumn && availableContentWidth >= 620

        return ScrollViewReader { scrollProxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .id("moments.feedTopAnchor")

                    // Top reserve for sticky masthead when rendered in ZStack
                    if includeStoriesInsideScroll {
                        Color.clear
                            .frame(height: max(68, metrics.safeAreaTop + 62))

                        MomentsStoriesRowView(
                            currentUser: store.currentUser,
                            entries: storyEntries,
                            trailingInset: rightRailClearance + 14,
                            onComposeTap: { showComposeEditor = true },
                            onPersonTap: { openProfile(for: $0) }
                        )
                        .padding(.leading, metrics.safeAreaLeft)
                    }

                    if visibleFeedMoments.isEmpty {
                        emptyFeedPlaceholder
                            .padding(.leading, metrics.safeAreaLeft)
                            .padding(.trailing, rightRailClearance)
                    } else if useTwoColumnStream {
                        twoColumnEditorialFeed
                            .padding(.leading, max(16, metrics.safeAreaLeft + 16))
                            .padding(.trailing, max(16, rightRailClearance + 16))
                            .padding(.top, 14)
                    } else {
                        LazyVStack(spacing: useCenteredEditorialColumn ? 16 : 0) {
                            ForEach(visibleFeedMoments) { post in
                                MomentCardView(
                                    store: store,
                                    post: post,
                                    ownerProfileUserID: nil,
                                    horizontalCardShape: useCenteredEditorialColumn,
                                    onOpenProfile: { openProfile(for: $0) },
                                    onStartChat: { startDirectChatAndExitMoments(with: $0) },
                                    onOpenLightbox: { tappedPost, idx in
                                        activeLightbox = MomentLightboxRequest(post: tappedPost, initialIndex: idx)
                                    }
                                )
                                .frame(maxWidth: useCenteredEditorialColumn ? 560 : .infinity)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.leading, metrics.safeAreaLeft)
                        .padding(.trailing, rightRailClearance)
                        .padding(.top, useCenteredEditorialColumn ? 14 : 0)
                    }

                    // Bottom clearance so floating Compose button never obscures the last card (`moments.css:64`)
                    Color.clear
                        .frame(height: max(metrics.safeAreaBottom, 16) + 92)
                }
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: MomentsFeedScrollOffsetKey.self,
                            value: -proxy.frame(in: .named("momentsFeedScroll")).minY
                        )
                    }
                )
            }
            .coordinateSpace(name: "momentsFeedScroll")
            .onPreferenceChange(MomentsFeedScrollOffsetKey.self) { offset in
                scrollOffsetY = offset
                if offset < 40 && hasUnseenLiveArrival {
                    hasUnseenLiveArrival = false
                }
            }
            .onChange(of: scrollToTopTrigger) { _, _ in
                if reduceMotion {
                    scrollProxy.scrollTo("moments.feedTopAnchor", anchor: .top)
                } else {
                    withAnimation(CuvenSprings.smooth) {
                        scrollProxy.scrollTo("moments.feedTopAnchor", anchor: .top)
                    }
                }
            }
            .accessibilityIdentifier("moments.feed")
        }
    }

    private var twoColumnEditorialFeed: some View {
        let leftPosts = visibleFeedMoments.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil }
        let rightPosts = visibleFeedMoments.enumerated().compactMap { !$0.offset.isMultiple(of: 2) ? $0.element : nil }

        return HStack(alignment: .top, spacing: 16) {
            LazyVStack(spacing: 16) {
                ForEach(leftPosts) { post in
                    MomentCardView(
                        store: store,
                        post: post,
                        ownerProfileUserID: nil,
                        horizontalCardShape: true,
                        onOpenProfile: { openProfile(for: $0) },
                        onStartChat: { startDirectChatAndExitMoments(with: $0) },
                        onOpenLightbox: { tappedPost, idx in
                            activeLightbox = MomentLightboxRequest(post: tappedPost, initialIndex: idx)
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity)

            LazyVStack(spacing: 16) {
                ForEach(rightPosts) { post in
                    MomentCardView(
                        store: store,
                        post: post,
                        ownerProfileUserID: nil,
                        horizontalCardShape: true,
                        onOpenProfile: { openProfile(for: $0) },
                        onStartChat: { startDirectChatAndExitMoments(with: $0) },
                        onOpenLightbox: { tappedPost, idx in
                            activeLightbox = MomentLightboxRequest(post: tappedPost, initialIndex: idx)
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var emptyFeedPlaceholder: some View {
        VStack(spacing: 8) {
            Text("Nothing here yet")
                .font(CuvenFonts.cappedHeadline(weight: .bold))
                .foregroundStyle(CuvenColors.inkPrimary)

            Text("Moments you and others share appear here.")
                .font(.system(size: 15))
                .foregroundStyle(CuvenColors.inkSecondary)
                .multilineTextAlignment(.center)

            Button {
                CuvenHaptics.lightTap()
                showComposeEditor = true
            } label: {
                Text("Share a moment")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CuvenColors.onCtaInk)
                    .padding(.horizontal, 20)
                    .frame(height: 44)
                    .background(CuvenColors.ctaInk, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
        .padding(.horizontal, 28)
    }

    // MARK: - Navigation & Seen Tracking Helpers

    private func openProfile(for user: CuvenUser) {
        viewedAuthorIDs.insert(user.id)
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : CuvenSprings.stripSlide) {
            selectedProfileUser = user
        }
    }

    private func startDirectChatAndExitMoments(with user: CuvenUser) {
        Task {
            let roomID = await store.createDirectChat(with: user.id)
            store.selectRoom(roomID)
            store.navigateToPage(.chats)
            onClose()
        }
    }

    private func markMomentsSeenNow() {
        let nowMillis = MomentsTimeFormatter.epochMilliseconds(from: Date())
        UserDefaults.standard.set(Double(nowMillis), forKey: Self.lastSeenDefaultsKey)
    }
}

private struct MomentsFeedScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

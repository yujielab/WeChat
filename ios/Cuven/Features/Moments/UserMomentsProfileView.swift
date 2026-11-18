// UserMomentsProfileView.swift
// Cuven — Native iOS & iPhone Duo App (iOS 27.1 SDK)
//
// Author Moments Profile Page (`public/js/views/moments.js:208-397`, `public/css/moments.css:316-498`):
// - Stretchy parallax Cover header (custom `BackdropPreset` / uploaded cover photo / deep indigo ribbon)
// - Sticky frosted Liquid Glass top bar revealing author's name once cover scrolls out of view
// - Overlapping `104pt` Avatar (`4pt` paper border), Display Name, `@username`, Bio, Post/Friend counts
// - `Share profile` + `Edit profile` (self) / solid Ink `Message` (peer) pill buttons
// - Spring-underlined segmented `Posts` timeline vs aspect-preserving 2/3-column `Media` waterfall masonry grid
// - Floating Compose `+` button when viewing own profile.

import SwiftUI
import CuvenCore

public enum MomentsProfileSegment: String, CaseIterable, Identifiable, Sendable {
    case posts = "posts"
    case media = "media"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .posts: return "Posts"
        case .media: return "Media"
        }
    }

    public var symbolName: String {
        switch self {
        case .posts: return "doc.text"
        case .media: return "photo.on.rectangle.angled"
        }
    }
}

public struct UserMomentsProfileView: View {
    private let store: AppStore
    private let user: CuvenUser
    private let metrics: DuoLayoutMetrics
    private let onBack: () -> Void
    private let onOpenCompose: () -> Void
    private let onOpenProfileEdit: (() -> Void)?
    private let onStartChat: (CuvenUser) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tabUnderlineNamespace

    @State private var selectedSegment: MomentsProfileSegment
    @State private var scrollOffsetY: CGFloat = 0
    @State private var activeLightbox: MomentLightboxRequest?
    @State private var nestedProfileUser: CuvenUser?
    @State private var showProfileEditorSheet: Bool = false

    public init(
        store: AppStore,
        user: CuvenUser,
        metrics: DuoLayoutMetrics,
        initialSegment: MomentsProfileSegment = .posts,
        onBack: @escaping () -> Void,
        onOpenCompose: @escaping () -> Void = {},
        onOpenProfileEdit: (() -> Void)? = nil,
        onStartChat: @escaping (CuvenUser) -> Void = { _ in }
    ) {
        self.store = store
        self.user = user
        self.metrics = metrics
        self._selectedSegment = State(initialValue: initialSegment)
        self.onBack = onBack
        self.onOpenCompose = onOpenCompose
        self.onOpenProfileEdit = onOpenProfileEdit
        self.onStartChat = onStartChat
    }

    private var liveUser: CuvenUser {
        if let me = store.currentUser, me.id == user.id { return me }
        if let contact = store.contacts.first(where: { $0.user.id == user.id }) { return contact.user }
        if let author = store.moments.first(where: { $0.author.id == user.id })?.author { return author }
        return user
    }

    private var isSelfProfile: Bool {
        store.currentUser?.id == liveUser.id
    }

    private var isFriendWithUser: Bool {
        if isSelfProfile { return true }
        if store.contacts.contains(where: { $0.user.id == liveUser.id && $0.status == .accepted }) {
            return true
        }
        if let dm = store.rooms.first(where: { $0.kind == .dm && ($0.peerUserID == liveUser.id || $0.memberIDs.contains(liveUser.id)) }) {
            let msgs = store.messagesByRoom[dm.id] ?? []
            if msgs.isEmpty { return true }
            let meSpoke = store.currentUser.map { me in msgs.contains(where: { $0.senderID == me.id }) } ?? false
            let peerSpoke = msgs.contains(where: { $0.senderID == liveUser.id })
            return meSpoke && peerSpoke
        }
        return false
    }

    private var visibleUserPosts: [MomentPost] {
        let now = Date()
        return store.moments
            .filter { post in
                guard post.author.id == liveUser.id else { return false }
                // Scheduled posts are visible only to their author until timestamp arrives (`moments-editor.cjs:121`)
                if let scheduled = post.scheduledAt, MomentsTimeFormatter.date(fromEpoch: scheduled) > now {
                    return isSelfProfile
                }
                // Friends-only posts are visible only to self & friends (`moments.cjs:85`)
                if post.audience == "friends" && !(isSelfProfile || isFriendWithUser) {
                    return false
                }
                return true
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var visibleMediaPosts: [MomentPost] {
        visibleUserPosts.filter { !$0.media.isEmpty }
    }

    private var rightRailInset: CGFloat {
        metrics.hasRightSystemColumn ? max(metrics.safeAreaRight, metrics.railWidth + 16) : metrics.safeAreaRight
    }

    private var baseCoverHeight: CGFloat {
        metrics.viewportSize.width >= 700 ? 204 : 176
    }

    private var hasScrolledPastCover: Bool {
        scrollOffsetY > (baseCoverHeight - 68)
    }

    private var displayName: String {
        liveUser.display.isEmpty ? liveUser.username : liveUser.display
    }

    private var waterfallColumnCount: Int {
        let availableWidth = metrics.viewportSize.width - metrics.safeAreaLeft - rightRailInset
        return availableWidth >= 640 ? 3 : 2
    }

    private var hasScrolledPastTabs: Bool {
        scrollOffsetY > (baseCoverHeight + 172)
    }

    public var body: some View {
        ZStack(alignment: .top) {
            CuvenColors.paperBackground
                .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    parallaxCoverHeader

                    identityAndActionsBlock
                        .padding(.leading, max(20, metrics.safeAreaLeft + 20))
                        .padding(.trailing, max(20, rightRailInset + 16))

                    segmentedTabBar(underlineID: "profileSegmentUnderlineInline", includeAccessibilityIDs: !hasScrolledPastTabs)
                        .padding(.top, 18)
                        .padding(.trailing, rightRailInset)

                    contentPanel
                        .padding(.leading, metrics.safeAreaLeft)
                        .padding(.trailing, rightRailInset)
                        .padding(.bottom, max(metrics.safeAreaBottom, 16) + (isSelfProfile ? 92 : 36))
                }
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ProfileScrollOffsetPreferenceKey.self,
                            value: -proxy.frame(in: .named("momentsProfileScroll")).minY
                        )
                    }
                )
            }
            .coordinateSpace(name: "momentsProfileScroll")
            .onPreferenceChange(ProfileScrollOffsetPreferenceKey.self) { offset in
                scrollOffsetY = offset
            }

            stickyTopNavigationBar

            if isSelfProfile {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            CuvenHaptics.lightTap()
                            onOpenCompose()
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(CuvenColors.onCtaInk)
                                .frame(width: 58, height: 58)
                                .background(CuvenColors.ctaInk, in: Circle())
                                .shadow(color: .black.opacity(0.32), radius: 14, x: 0, y: 6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("New moment")
                        .accessibilityIdentifier("moments.profile.composeButton")
                        .padding(.trailing, max(20, rightRailInset + 16))
                        .padding(.bottom, max(metrics.safeAreaBottom, 14) + 16)
                    }
                }
            }
        }
        .fullScreenCover(item: $activeLightbox) { req in
            MomentMediaLightboxOverlay(
                store: store,
                post: req.post,
                initialIndex: req.initialIndex,
                onDismiss: { activeLightbox = nil }
            )
        }
        .sheet(item: $nestedProfileUser) { targetUser in
            UserMomentsProfileView(
                store: store,
                user: targetUser,
                metrics: metrics,
                onBack: { nestedProfileUser = nil },
                onOpenCompose: onOpenCompose,
                onStartChat: onStartChat
            )
        }
        .sheet(isPresented: $showProfileEditorSheet) {
            ProfileAvatarCoverEditorSheet(store: store)
        }
        .accessibilityIdentifier("moments.profileView")
    }

    // MARK: - Parallax Stretchy Cover Header (`moments.css:316-331`)

    private var parallaxCoverHeader: some View {
        GeometryReader { geo in
            let minY = geo.frame(in: .named("momentsProfileScroll")).minY
            let overscrollStretch = max(0, minY)
            let upwardParallax = min(0, minY) * 0.32
            let height = baseCoverHeight + overscrollStretch

            ZStack {
                if let preset = MomentsPalette.resolveCoverPreset(liveUser.coverURL) {
                    CuvenBackdropView(preset: preset, customImageURL: nil)
                } else if let cover = liveUser.coverURL, !cover.isEmpty {
                    MomentsMediaThumbnailView(
                        urlString: cover,
                        serverBaseURL: store.serverBaseURL,
                        filterName: nil,
                        altLabel: "\(displayName)'s cover photo",
                        contentMode: .fill
                    )
                } else {
                    MomentsPalette.coverGradient(dominantTintHex: liveUser.dominantTintHex)
                        .overlay {
                            RadialGradient(
                                colors: [Color(red: 0.47, green: 0.63, blue: 1.0).opacity(0.42), .clear],
                                center: .topTrailing,
                                startRadius: 10,
                                endRadius: 260
                            )
                        }
                }

                LinearGradient(
                    colors: [Color.black.opacity(0.28), .clear, Color.black.opacity(0.18)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: geo.size.width, height: height)
            .clipped()
            .offset(y: minY > 0 ? -minY : -upwardParallax)
        }
        .frame(height: baseCoverHeight)
    }

    // MARK: - Sticky Top Bar (`moments.css:334-368, 397-410`)

    private var stickyTopNavigationBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    CuvenHaptics.lightTap()
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(hasScrolledPastCover ? CuvenColors.inkPrimary : .white)
                        .frame(width: 44, height: 44)
                        .background {
                            if hasScrolledPastCover {
                                Circle()
                                    .fill(CuvenColors.elevatedSurface.opacity(0.92))
                                    .overlay {
                                        Circle().strokeBorder(CuvenColors.hairlineSeparator, lineWidth: 0.75)
                                    }
                            } else {
                                Circle()
                                    .fill(Color.black.opacity(0.44))
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .accessibilityIdentifier("moments.profile.backButton")

                Text(displayName)
                    .font(CuvenFonts.cappedHeadline(weight: .bold))
                    .foregroundStyle(CuvenColors.inkPrimary)
                    .lineLimit(1)
                    .opacity(hasScrolledPastCover ? 1.0 : 0.0)
                    .offset(y: hasScrolledPastCover ? 0 : 6)
                    .animation(.easeOut(duration: 0.20), value: hasScrolledPastCover)

                Spacer()
            }
            .padding(.leading, max(14, metrics.safeAreaLeft + 14))
            .padding(.trailing, max(14, rightRailInset + 14))
            .padding(.top, max(8, metrics.safeAreaTop))
            .padding(.bottom, 10)

            if hasScrolledPastTabs {
                segmentedTabBar(underlineID: "profileSegmentUnderlineSticky", includeAccessibilityIDs: true)
                    .padding(.leading, metrics.safeAreaLeft)
                    .padding(.trailing, rightRailInset)
            }
        }
        .background {
            if hasScrolledPastCover {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(alignment: .bottom) {
                        if !hasScrolledPastTabs {
                            Rectangle()
                                .fill(CuvenColors.hairlineSeparator)
                                .frame(height: 0.5)
                        }
                    }
                    .ignoresSafeArea(edges: .top)
            }
        }
    }

    // MARK: - Overlapping Avatar, Identity & Action Pills (`moments.css:371-395`)

    private var identityAndActionsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Overlapping `104pt` avatar (`margin-top: -54px`)
            CuvenAvatarView(
                name: displayName,
                urlString: liveUser.avatarURL,
                size: 104,
                isOnline: liveUser.isOnline
            )
            .padding(4)
            .background(CuvenColors.paperBackground, in: Circle())
            .offset(y: -52)
            .padding(.bottom, -44)

            Text(displayName)
                .font(CuvenFonts.clarinettaDisplay(size: 28, weight: .bold, italic: false))
                .foregroundStyle(CuvenColors.inkPrimary)

            Text("@\(liveUser.username)")
                .font(CuvenFonts.cappedBody(weight: .regular))
                .foregroundStyle(CuvenColors.inkSecondary)
                .padding(.top, 2)

            if !liveUser.bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(liveUser.bio)
                    .font(CuvenFonts.cappedBody(weight: .regular))
                    .foregroundStyle(CuvenColors.inkPrimary)
                    .lineSpacing(3)
                    .padding(.top, 10)
            }

            // Tabular post & relationship counts (`moments.js:269-276`)
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Text("\(visibleUserPosts.count)")
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(CuvenColors.inkPrimary)
                    Text(visibleUserPosts.count == 1 ? "Post" : "Posts")
                        .font(.system(size: 15))
                        .foregroundStyle(CuvenColors.inkSecondary)
                }

                if isSelfProfile {
                    let acceptedFriendsCount = store.contacts.filter { $0.status == .accepted }.count
                    HStack(spacing: 4) {
                        Text("\(acceptedFriendsCount)")
                            .font(.system(size: 15, weight: .semibold).monospacedDigit())
                            .foregroundStyle(CuvenColors.inkPrimary)
                        Text(acceptedFriendsCount == 1 ? "Friend" : "Friends")
                            .font(.system(size: 15))
                            .foregroundStyle(CuvenColors.inkSecondary)
                    }
                } else {
                    Text(isFriendWithUser ? "Friends" : "You've not talked yet")
                        .font(.system(size: 15))
                        .foregroundStyle(CuvenColors.inkSecondary)
                }
            }
            .padding(.top, 12)

            // Two `44pt` pill buttons (`Share profile` + `Edit profile` or `Message`)
            HStack(spacing: 10) {
                ShareLink(item: "Find \(displayName) on Cuven: @\(liveUser.username)") {
                    Text("Share profile")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .overlay {
                            Capsule()
                                .strokeBorder(CuvenColors.hairlineSeparator, lineWidth: 1.0)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("moments.profile.shareButton")

                Button {
                    CuvenHaptics.lightTap()
                    if isSelfProfile {
                        if let onOpenProfileEdit {
                            onOpenProfileEdit()
                        } else {
                            showProfileEditorSheet = true
                        }
                    } else {
                        onStartChat(liveUser)
                    }
                } label: {
                    Text(isSelfProfile ? "Edit profile" : "Message")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isSelfProfile ? CuvenColors.inkPrimary : CuvenColors.onCtaInk)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background {
                            if isSelfProfile {
                                Capsule().fill(Color.clear)
                            } else {
                                Capsule().fill(CuvenColors.ctaInk)
                            }
                        }
                        .overlay {
                            if isSelfProfile {
                                Capsule().strokeBorder(CuvenColors.hairlineSeparator, lineWidth: 1.0)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("moments.profile.editOrMessageButton")
            }
            .padding(.top, 16)
        }
    }

    // MARK: - Segmented `Posts` vs `Media` Tab Bar (`moments.css:397-427`)

    private func segmentedTabBar(underlineID: String, includeAccessibilityIDs: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(MomentsProfileSegment.allCases) { segment in
                let isSelected = (selectedSegment == segment)
                Button {
                    guard selectedSegment != segment else { return }
                    CuvenHaptics.selectionChanged()
                    withAnimation(reduceMotion ? .easeOut(duration: 0.12) : CuvenSprings.pressBounce) {
                        selectedSegment = segment
                    }
                } label: {
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Image(systemName: segment.symbolName)
                                .font(.system(size: 18, weight: isSelected ? .bold : .medium))
                            if isSelected {
                                Text(segment.title)
                                    .font(CuvenFonts.cappedHeadline(weight: .bold))
                            }
                        }
                        .foregroundStyle(isSelected ? CuvenColors.inkPrimary : CuvenColors.inkSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 51)

                        ZStack {
                            Color.clear.frame(height: 3)
                            if isSelected {
                                Capsule()
                                    .fill(CuvenColors.inkPrimary)
                                    .frame(height: 3)
                                    .padding(.horizontal, 24)
                                    .matchedGeometryEffect(id: underlineID, in: tabUnderlineNamespace)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(segment.title)
                .accessibilityIdentifier(includeAccessibilityIDs ? "moments.profile.\(segment.rawValue)Tab" : "moments.profile.\(segment.rawValue)Tab.hidden")
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CuvenColors.hairlineSeparator)
                .frame(height: 0.5)
        }
    }

    // MARK: - Posts Timeline vs 2/3-Column Media Waterfall Masonry (`moments.js:348-372`)

    @ViewBuilder
    private var contentPanel: some View {
        switch selectedSegment {
        case .posts:
            if visibleUserPosts.isEmpty {
                emptyProfileState
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(visibleUserPosts) { post in
                        MomentCardView(
                            store: store,
                            post: post,
                            ownerProfileUserID: liveUser.id,
                            onOpenProfile: { target in
                                if target.id != liveUser.id {
                                    nestedProfileUser = target
                                }
                            },
                            onStartChat: onStartChat,
                            onOpenLightbox: { tappedPost, idx in
                                activeLightbox = MomentLightboxRequest(post: tappedPost, initialIndex: idx)
                            }
                        )
                    }
                }
            }

        case .media:
            if visibleMediaPosts.isEmpty {
                emptyProfileState
            } else {
                MomentsMediaWaterfallGrid(
                    posts: visibleMediaPosts,
                    columnCount: waterfallColumnCount,
                    serverBaseURL: store.serverBaseURL,
                    onSelectPost: { tappedPost in
                        CuvenHaptics.lightTap()
                        activeLightbox = MomentLightboxRequest(post: tappedPost, initialIndex: 0)
                    }
                )
                .padding(12)
                .accessibilityIdentifier("moments.profile.mediaWaterfall")
            }
        }
    }

    private var emptyProfileState: some View {
        VStack(spacing: 8) {
            if isSelfProfile {
                Text("Share your first moment")
                    .font(CuvenFonts.cappedHeadline(weight: .bold))
                    .foregroundStyle(CuvenColors.inkPrimary)
                Text("Photos or a video, and a few words.")
                    .font(.system(size: 15))
                    .foregroundStyle(CuvenColors.inkSecondary)

                Button {
                    CuvenHaptics.lightTap()
                    onOpenCompose()
                } label: {
                    Text("Share a moment")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(CuvenColors.onCtaInk)
                        .padding(.horizontal, 20)
                        .frame(height: 44)
                        .background(CuvenColors.ctaInk, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            } else if !isFriendWithUser {
                Text("Nothing for everyone yet")
                    .font(CuvenFonts.cappedHeadline(weight: .bold))
                    .foregroundStyle(CuvenColors.inkPrimary)
                Text("What \(displayName) shares for everyone shows up here.")
                    .font(.system(size: 15))
                    .foregroundStyle(CuvenColors.inkSecondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Nothing shared yet")
                    .font(CuvenFonts.cappedHeadline(weight: .bold))
                    .foregroundStyle(CuvenColors.inkPrimary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
        .padding(.horizontal, 28)
    }
}

// MARK: - Shortest-Column Aspect-Preserving Waterfall Masonry (`moments.js:350-372`, `moments.css:451-472`)

struct MomentsMediaWaterfallGrid: View {
    let posts: [MomentPost]
    let columnCount: Int
    let serverBaseURL: URL
    let onSelectPost: (MomentPost) -> Void

    private var distributedColumns: [[MomentPost]] {
        let count = max(2, columnCount)
        var columns: [[MomentPost]] = Array(repeating: [], count: count)
        var estimatedHeights: [CGFloat] = Array(repeating: 0, count: count)

        for post in posts {
            guard let primary = post.media.first else { continue }
            let ratio = min(1.50, max(0.66, CGFloat(max(1, primary.width)) / CGFloat(max(1, primary.height))))
            // Relative card height = image inverse aspect + caption + footer
            let cardRelativeHeight = (1.0 / ratio) + (post.text.isEmpty ? 0.22 : 0.42)

            // Shortest column takes the next card (`moments.js:368-369`)
            let shortestIndex = estimatedHeights.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
            columns[shortestIndex].append(post)
            estimatedHeights[shortestIndex] += cardRelativeHeight
        }
        return columns
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(Array(distributedColumns.enumerated()), id: \.offset) { _, colPosts in
                LazyVStack(spacing: 10) {
                    ForEach(colPosts) { post in
                        MomentsWaterfallTileCard(
                            post: post,
                            serverBaseURL: serverBaseURL,
                            onTap: { onSelectPost(post) }
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct MomentsWaterfallTileCard: View {
    let post: MomentPost
    let serverBaseURL: URL
    let onTap: () -> Void

    private var clampedAspectRatio: CGFloat {
        guard let first = post.media.first else { return 1.0 }
        let raw = CGFloat(max(1, first.width)) / CGFloat(max(1, first.height))
        return min(1.50, max(0.66, raw))
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                if let first = post.media.first {
                    ZStack(alignment: .topTrailing) {
                        GeometryReader { geo in
                            MomentsMediaThumbnailView(
                                urlString: first.url,
                                serverBaseURL: serverBaseURL,
                                filterName: first.filterName,
                                altLabel: first.altText ?? post.text,
                                contentMode: .fill
                            )
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                        }
                        .aspectRatio(clampedAspectRatio, contentMode: .fit)

                        if first.isVideo {
                            Circle()
                                .fill(Color.black.opacity(0.48))
                                .frame(width: 36, height: 36)
                                .overlay {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.white)
                                        .offset(x: 1)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if post.media.count > 1 {
                            Text("\(post.media.count)")
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .frame(height: 22)
                                .background(Color.black.opacity(0.54), in: Capsule())
                                .padding(8)
                        }
                    }
                }

                if !post.text.isEmpty {
                    Text(post.text)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                }

                HStack(spacing: 6) {
                    CuvenAvatarView(
                        name: post.author.display.isEmpty ? post.author.username : post.author.display,
                        urlString: post.author.avatarURL,
                        size: 20,
                        isOnline: false
                    )

                    Text(post.author.display.isEmpty ? post.author.username : post.author.display)
                        .font(.system(size: 12))
                        .foregroundStyle(CuvenColors.inkSecondary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    HStack(spacing: 3) {
                        Image(systemName: "heart")
                            .font(.system(size: 12, weight: .medium))
                        if !post.likedUserIDs.isEmpty {
                            Text("\(post.likedUserIDs.count)")
                                .font(.system(size: 12).monospacedDigit())
                        }
                    }
                    .foregroundStyle(CuvenColors.inkSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 10)
            }
            .background(CuvenColors.elevatedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(CuvenColors.hairlineSeparator, lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 3)
        }
        .buttonStyle(.plain)
    }
}

private struct ProfileScrollOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

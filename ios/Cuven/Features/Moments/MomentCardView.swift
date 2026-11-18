// MomentCardView.swift
// Cuven — Native iOS & iPhone Duo App (iOS 27.1 SDK)
//
// Rich Editorial Moment Card (`public/js/views/moments.js:449-730`, `public/css/moments.css:116-314`):
// - Author header (`36pt` avatar, display name, `@username` vs `"Suggested for you"`, `"Message"` CTA pill, `•••` menu)
// - Multi-photo `4:5` snap carousel (`1/N` badge + frosted pips) AND 1-tap toggleable Adaptive 1/2/3/4+ Collage Grid
// - `ALT` accessibility badge overlay -> full VoiceOver/visual description sheet
// - Double-tap photo burst heart animation (multi-stage spring scale + 8 radial particles + rigid haptic)
// - Frosted Liquid Glass pills (`Like`, `Comment`, `Share`) resting directly over the bottom edge of the photo
// - `@tagged` friend chips, 2-line clamped caption with `"more"`, expandable inline Comments drawer + composer,
//   scheduled publish badge, and `Everyone` / `Friends` audience indicator.

import SwiftUI
import CuvenCore

enum MomentMediaDisplayStyle: String, Sendable {
    case carousel
    case collage
}

struct MomentLightboxRequest: Identifiable, Equatable {
    let post: MomentPost
    let initialIndex: Int
    var id: String { "\(post.id)-\(initialIndex)" }
}

struct MomentCardView: View {
    let store: AppStore
    let post: MomentPost
    let ownerProfileUserID: String?
    var defaultMediaStyle: MomentMediaDisplayStyle = .carousel
    var horizontalCardShape: Bool = false
    let onOpenProfile: (CuvenUser) -> Void
    let onStartChat: (CuvenUser) -> Void
    let onOpenLightbox: (MomentPost, Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var currentSlideIndex: Int = 0
    @State private var mediaDisplayStyle: MomentMediaDisplayStyle = .carousel
    @State private var showHeartBurst: Bool = false
    @State private var heartBurstScale: CGFloat = 0.28
    @State private var heartBurstOpacity: Double = 0.0
    @State private var particleSpread: CGFloat = 0.0
    @State private var likeIconBounce: Bool = false

    @State private var isCaptionExpanded: Bool = false
    @State private var areAllCommentsExpanded: Bool = false
    @State private var commentDraft: String = ""
    @State private var isSubmittingComment: Bool = false
    @FocusState private var isCommentFieldFocused: Bool

    @State private var selectedAltDescription: String?
    @State private var showDeleteConfirmation: Bool = false

    private var currentUserID: String? { store.currentUser?.id }

    private var isOwnPost: Bool {
        guard let me = currentUserID else { return false }
        return post.author.id == me
    }

    private var isFriendWithAuthor: Bool {
        if isOwnPost { return true }
        if store.contacts.contains(where: { $0.user.id == post.author.id && $0.status == .accepted }) {
            return true
        }
        // Mutual 1:1 DM check matching `moments.js` / `src/store.js`
        if let dmRoom = store.rooms.first(where: { $0.kind == .dm && ($0.peerUserID == post.author.id || $0.memberIDs.contains(post.author.id)) }) {
            let msgs = store.messagesByRoom[dmRoom.id] ?? []
            if msgs.isEmpty { return true } // seeded accepted DM
            let meSpoke = currentUserID.map { uid in msgs.contains(where: { $0.senderID == uid }) } ?? false
            let peerSpoke = msgs.contains(where: { $0.senderID == post.author.id })
            return meSpoke && peerSpoke
        }
        return false
    }

    private var isLikedByMe: Bool {
        guard let me = currentUserID else { return false }
        return post.likedUserIDs.contains(me)
    }

    private var canViewerComment: Bool {
        switch post.commentPolicy {
        case "off":
            return false
        case "friends":
            return isOwnPost || isFriendWithAuthor
        default:
            return true
        }
    }

    private var isScheduledFuture: Bool {
        guard let scheduled = post.scheduledAt else { return false }
        return MomentsTimeFormatter.date(fromEpoch: scheduled) > Date()
    }

    private var authorDisplayName: String {
        post.author.display.isEmpty ? post.author.username : post.author.display
    }

    private var resolvedTaggedUsers: [CuvenUser] {
        post.taggedUserIDs.map { uid in
            if let me = store.currentUser, me.id == uid { return me }
            if let contact = store.contacts.first(where: { $0.user.id == uid }) { return contact.user }
            if let suggested = store.suggestedPeople.first(where: { $0.id == uid }) { return suggested }
            if let momentAuthor = store.moments.first(where: { $0.author.id == uid })?.author { return momentAuthor }
            return CuvenUser(id: uid, username: uid, display: uid)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            authorHeaderRow

            if !post.media.isEmpty {
                mediaStageWithOverlaidActionPills
            } else if !post.text.isEmpty {
                textOnlyEditorialBody
                actionBarRow(overPhoto: false)
                    .padding(.top, 2)
            }

            if !resolvedTaggedUsers.isEmpty {
                taggedFriendsRow
                    .padding(.top, post.media.isEmpty ? 4 : 10)
            }

            if !post.media.isEmpty && !post.text.isEmpty {
                captionBlock
                    .padding(.top, resolvedTaggedUsers.isEmpty ? 10 : 4)
            }

            commentsSection
                .padding(.top, 4)

            commentComposerOrRestrictionRow
                .padding(.top, 6)

            timestampAndAudienceFooter
                .padding(.top, 6)
                .padding(.bottom, 14)
        }
        .background(horizontalCardShape ? CuvenColors.elevatedSurface : CuvenColors.paperBackground)
        .clipShape(RoundedRectangle(cornerRadius: horizontalCardShape ? 20 : 0, style: .continuous))
        .overlay(alignment: .bottom) {
            if !horizontalCardShape {
                Rectangle()
                    .fill(CuvenColors.hairlineSeparator)
                    .frame(height: 0.5)
            }
        }
        .overlay {
            if horizontalCardShape {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(CuvenColors.hairlineSeparator, lineWidth: 0.75)
            }
        }
        .onAppear {
            mediaDisplayStyle = defaultMediaStyle
        }
        .confirmationDialog(
            "Delete this moment?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                CuvenHaptics.rigidImpact()
                Task {
                    await store.deleteMoment(momentID: post.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its photos, likes and comments go with it.")
        }
        .sheet(isPresented: Binding(
            get: { selectedAltDescription != nil },
            set: { if !$0 { selectedAltDescription = nil } }
        )) {
            AltDescriptionReaderSheet(descriptionText: selectedAltDescription ?? "")
                .presentationDetents([.medium, .fraction(0.38)])
                .presentationDragIndicator(.visible)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("moments.card.\(post.id)")
    }

    // MARK: - 1. Author Header (`moments.js:456-474`)

    private var authorHeaderRow: some View {
        HStack(spacing: 8) {
            let canNavigateAuthor = (ownerProfileUserID != post.author.id)
            Button {
                guard canNavigateAuthor else { return }
                CuvenHaptics.selectionChanged()
                onOpenProfile(post.author)
            } label: {
                HStack(spacing: 10) {
                    CuvenAvatarView(
                        name: authorDisplayName,
                        urlString: post.author.avatarURL,
                        size: 36,
                        isOnline: post.author.isOnline
                    )

                    VStack(alignment: .leading, spacing: 1) {
                        Text(authorDisplayName)
                            .font(CuvenFonts.cappedBody(weight: .bold))
                            .foregroundStyle(CuvenColors.inkPrimary)
                            .lineLimit(1)

                        Text((!isOwnPost && !isFriendWithAuthor) ? "Suggested for you" : "@\(post.author.username)")
                            .font(CuvenFonts.cappedCaption(weight: .regular))
                            .foregroundStyle(CuvenColors.inkSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canNavigateAuthor)
            .accessibilityLabel("\(authorDisplayName)'s moments")

            if !isOwnPost && !isFriendWithAuthor {
                Button {
                    CuvenHaptics.lightTap()
                    onStartChat(post.author)
                } label: {
                    Text("Message")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(CuvenColors.incomingBubble, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Message \(authorDisplayName)")
            }

            Menu {
                if isOwnPost {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } else {
                    if ownerProfileUserID != post.author.id {
                        Button {
                            onOpenProfile(post.author)
                        } label: {
                            Label("View profile", systemImage: "person")
                        }
                    }
                    Button {
                        onStartChat(post.author)
                    } label: {
                        Label("Message", systemImage: "bubble.left")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(CuvenColors.inkPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More actions")
        }
        .frame(minHeight: 56)
        .padding(.leading, 14)
        .padding(.trailing, 6)
    }

    // MARK: - 2. Media Stage (4:5 Carousel + Adaptive 1/2/3/4+ Collage + Overlaid Frosted Pills)

    private var clampedPrimaryAspectRatio: CGFloat {
        guard let first = post.media.first else { return 1.0 }
        if post.media.count > 1 && mediaDisplayStyle == .carousel {
            // Multi-photo Moments default to 4:5 editorial portrait ratio (`moments.js:636`, `spec_miner_survey_2`)
            let raw = CGFloat(max(1, first.width)) / CGFloat(max(1, first.height))
            return min(1.25, max(0.80, raw))
        }
        let raw = CGFloat(max(1, first.width)) / CGFloat(max(1, first.height))
        return min(1.91, max(0.80, raw))
    }

    private var mediaStageWithOverlaidActionPills: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                if post.media.count == 1, let single = post.media.first {
                    singleMediaView(single, index: 0)
                        .aspectRatio(clampedPrimaryAspectRatio, contentMode: .fit)
                } else if mediaDisplayStyle == .collage {
                    MomentCollageGridView(
                        media: post.media,
                        serverBaseURL: store.serverBaseURL,
                        onTapPhoto: { idx in
                            CuvenHaptics.lightTap()
                            onOpenLightbox(post, idx)
                        },
                        onDoubleTapPhoto: {
                            triggerDoubleTapLikeBurst()
                        },
                        onTapAlt: { alt in
                            selectedAltDescription = alt
                        }
                    )
                    .aspectRatio(0.88, contentMode: .fit)
                } else {
                    // Canonical `4:5` Snap Carousel (`1/N` badge + frosted pips)
                    TabView(selection: $currentSlideIndex) {
                        ForEach(Array(post.media.enumerated()), id: \.element.id) { index, item in
                            singleMediaView(item, index: index)
                                .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .aspectRatio(clampedPrimaryAspectRatio, contentMode: .fit)
                }

                // Top overlays: `ALT` badge (top-left) + `1/N` counter & Carousel/Collage switcher (top-right)
                VStack {
                    HStack(alignment: .top, spacing: 8) {
                        if mediaDisplayStyle == .carousel || post.media.count == 1 {
                            let activeIndex = min(max(0, currentSlideIndex), post.media.count - 1)
                            if let alt = post.media[activeIndex].altText, !alt.isEmpty {
                                altBadgeButton(alt)
                            }
                        }

                        Spacer()

                        if post.media.count > 1 {
                            HStack(spacing: 6) {
                                if mediaDisplayStyle == .carousel {
                                    Text("\(min(currentSlideIndex + 1, post.media.count))/\(post.media.count)")
                                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 10)
                                        .frame(height: 26)
                                        .background(Color.black.opacity(0.56), in: Capsule())
                                        .accessibilityLabel("Photo \(currentSlideIndex + 1) of \(post.media.count)")
                                }

                                Button {
                                    CuvenHaptics.selectionChanged()
                                    withAnimation(reduceMotion ? .easeOut(duration: 0.12) : CuvenSprings.railMorph) {
                                        mediaDisplayStyle = (mediaDisplayStyle == .carousel) ? .collage : .carousel
                                    }
                                } label: {
                                    Image(systemName: mediaDisplayStyle == .carousel ? "square.grid.2x2" : "rectangle.split.3x1")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 28, height: 26)
                                        .background(Color.black.opacity(0.56), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(mediaDisplayStyle == .carousel ? "Show photo collage grid" : "Show swipe carousel")
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)

                    Spacer()
                }

                // Double-tap burst heart + radial sparkle particles (`moments.js:610-621`)
                if showHeartBurst {
                    doubleTapBurstOverlay
                        .allowsHitTesting(false)
                }
            }
            .opacity(isScheduledFuture ? 0.90 : 1.0)
            .clipped()

            // Frosted dark/glass pills resting directly over the bottom edge of the photo (`moments.css:252-277`)
            actionBarRow(overPhoto: true)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private func singleMediaView(_ item: MomentMedia, index: Int) -> some View {
        if item.isVideo {
            MomentsInlineVideoView(
                urlString: item.url,
                serverBaseURL: store.serverBaseURL,
                bottomControlOffset: 58
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    triggerDoubleTapLikeBurst()
                }
            )
        } else {
            GeometryReader { geo in
                MomentsMediaThumbnailView(
                    urlString: item.url,
                    serverBaseURL: store.serverBaseURL,
                    filterName: item.filterName,
                    altLabel: photoAccessibilityLabel(for: item, index: index),
                    contentMode: .fill
                )
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    triggerDoubleTapLikeBurst()
                }
                .onTapGesture(count: 1) {
                    CuvenHaptics.lightTap()
                    onOpenLightbox(post, index)
                }
            }
        }
    }

    private func altBadgeButton(_ altText: String) -> some View {
        Button {
            CuvenHaptics.lightTap()
            selectedAltDescription = altText
        } label: {
            Text("ALT")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(Color.black.opacity(0.64), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(minWidth: 44, minHeight: 44, alignment: .topLeading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Read photo description: \(altText)")
    }

    private var doubleTapBurstOverlay: some View {
        ZStack {
            if !reduceMotion {
                ForEach(0..<8, id: \.self) { idx in
                    let angle = Double(idx) * (.pi / 4.0)
                    let radius = 68.0 * particleSpread
                    Image(systemName: idx.isMultiple(of: 2) ? "heart.fill" : "sparkle")
                        .font(.system(size: idx.isMultiple(of: 2) ? 16 : 13, weight: .bold))
                        .foregroundStyle(idx.isMultiple(of: 2) ? Color(red: 1.0, green: 0.27, blue: 0.35) : .white)
                        .offset(
                            x: CGFloat(cos(angle) * radius),
                            y: CGFloat(sin(angle) * radius)
                        )
                        .scaleEffect(max(0.2, 1.15 - particleSpread * 0.55))
                        .opacity(heartBurstOpacity * Double(max(0, 1.0 - particleSpread * 0.45)))
                }
            }

            Image(systemName: "heart.fill")
                .font(.system(size: 86, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, Color(red: 1.0, green: 0.30, blue: 0.38)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: .black.opacity(0.38), radius: 18, x: 0, y: 8)
                .scaleEffect(heartBurstScale)
                .opacity(heartBurstOpacity)
        }
    }

    // MARK: - 3. Text-Only Editorial Body (`moments.css:246`)

    @ViewBuilder
    private var textOnlyEditorialBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(post.text)
                .font(CuvenFonts.cappedTitle(weight: .regular))
                .foregroundStyle(CuvenColors.inkPrimary)
                .lineSpacing(4)
                .lineLimit(isCaptionExpanded ? nil : 8)
                .fixedSize(horizontal: false, vertical: true)

            if post.text.count > 220 && !isCaptionExpanded {
                Button("more") {
                    withAnimation(.easeOut(duration: 0.18)) {
                        isCaptionExpanded = true
                    }
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(CuvenColors.inkSecondary)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
    }

    // MARK: - 4. Frosted Action Pills (`Like`, `Comment`, `Share` + Page Dots)

    private func actionBarRow(overPhoto: Bool) -> some View {
        HStack(spacing: 6) {
            // Like pill (`store.toggleMomentLike`)
            Button {
                toggleLikeFromButton()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isLikedByMe ? "heart.fill" : "heart")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(isLikedByMe ? CuvenColors.dangerRed : (overPhoto ? .white : CuvenColors.inkPrimary))
                        .scaleEffect(likeIconBounce ? 1.32 : 1.0)
                        .animation(reduceMotion ? nil : CuvenSprings.bubblePop, value: likeIconBounce)

                    if !post.likedUserIDs.isEmpty {
                        Text("\(post.likedUserIDs.count)")
                            .font(.system(size: 15, weight: .semibold).monospacedDigit())
                            .foregroundStyle(overPhoto ? .white : CuvenColors.inkPrimary)
                    }
                }
                .padding(.horizontal, 14)
                .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .modifier(MomentActionPillMaterial(overPhoto: overPhoto, glassMode: store.prefs.glassMode, reduceTransparency: reduceTransparency))
            .accessibilityLabel(likeAccessibilityLabel)
            .accessibilityIdentifier("moments.likeButton.\(post.id)")

            // Comment pill
            Button {
                CuvenHaptics.lightTap()
                if canViewerComment {
                    areAllCommentsExpanded = true
                    isCommentFieldFocused = true
                } else {
                    withAnimation(.easeOut(duration: 0.18)) {
                        areAllCommentsExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.right")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(overPhoto ? .white : CuvenColors.inkPrimary)

                    if !post.comments.isEmpty {
                        Text("\(post.comments.count)")
                            .font(.system(size: 15, weight: .semibold).monospacedDigit())
                            .foregroundStyle(overPhoto ? .white : CuvenColors.inkPrimary)
                    }
                }
                .padding(.horizontal, 14)
                .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .modifier(MomentActionPillMaterial(overPhoto: overPhoto, glassMode: store.prefs.glassMode, reduceTransparency: reduceTransparency))
            .accessibilityLabel(post.comments.isEmpty ? "Comment" : "Comment, \(post.comments.count) \(post.comments.count == 1 ? "comment" : "comments")")
            .accessibilityIdentifier("moments.commentButton.\(post.id)")

            // Share pill (`moments.js:623-630`)
            ShareLink(item: shareSummaryText) {
                Image(systemName: "paperplane")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(overPhoto ? .white : CuvenColors.inkPrimary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .modifier(MomentActionPillMaterial(overPhoto: overPhoto, glassMode: store.prefs.glassMode, reduceTransparency: reduceTransparency))
            .accessibilityLabel("Share moment")

            Spacer(minLength: 4)

            // Carousel page dots (`mo-pips`, `moments.css:204-206, 258-259`)
            if overPhoto && post.media.count > 1 && mediaDisplayStyle == .carousel {
                HStack(spacing: 5) {
                    ForEach(0..<post.media.count, id: \.self) { idx in
                        Circle()
                            .fill(idx == currentSlideIndex ? Color.white : Color.white.opacity(0.50))
                            .frame(width: idx == currentSlideIndex ? 7 : 6, height: idx == currentSlideIndex ? 7 : 6)
                            .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.28), in: Capsule())
                .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, overPhoto ? 0 : 8)
    }

    // MARK: - 5. `@Tagged` Friend Chips (`moments.js:534-540`)

    private var taggedFriendsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: "person.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CuvenColors.inkSecondary)

                Text("With")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(CuvenColors.inkSecondary)

                ForEach(resolvedTaggedUsers) { taggedUser in
                    Button {
                        CuvenHaptics.selectionChanged()
                        onOpenProfile(taggedUser)
                    } label: {
                        Text("@\(taggedUser.display.isEmpty ? taggedUser.username : taggedUser.display)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(MomentsPalette.accessibleBlueText)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(CuvenColors.incomingBubble, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - 6. Caption with 2-Line Clamp + `"more"` (`moments.js:504, 600-608`)

    private var captionBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            (Text(authorDisplayName).fontWeight(.bold) + Text(" ") + Text(post.text))
                .font(.system(size: 15))
                .foregroundStyle(CuvenColors.inkPrimary)
                .lineSpacing(2.5)
                .lineLimit(isCaptionExpanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)

            if post.text.count > 92 && !isCaptionExpanded {
                Button("more") {
                    withAnimation(.easeOut(duration: 0.18)) {
                        isCaptionExpanded = true
                    }
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(CuvenColors.inkSecondary)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - 7. Expandable Inline Comments Drawer & Composer (`moments.js:505-571`)

    @ViewBuilder
    private var commentsSection: some View {
        if !post.comments.isEmpty {
            let visibleComments = areAllCommentsExpanded ? post.comments : Array(post.comments.suffix(2))
            VStack(alignment: .leading, spacing: 4) {
                if !areAllCommentsExpanded && post.comments.count > 2 {
                    Button {
                        CuvenHaptics.selectionChanged()
                        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : CuvenSprings.sheetPresent) {
                            areAllCommentsExpanded = true
                        }
                    } label: {
                        Text("View all \(post.comments.count) comments")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(CuvenColors.inkSecondary)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }

                ForEach(visibleComments) { comment in
                    (Text(comment.authorDisplay).fontWeight(.semibold) + Text(" ") + Text(comment.text))
                        .font(.system(size: 15))
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var commentComposerOrRestrictionRow: some View {
        if canViewerComment {
            HStack(spacing: 10) {
                CuvenAvatarView(
                    name: store.currentUser?.display ?? "You",
                    urlString: store.currentUser?.avatarURL,
                    size: 26,
                    isOnline: false
                )

                TextField("Add a comment…", text: $commentDraft)
                    .font(.system(size: 15))
                    .foregroundStyle(CuvenColors.inkPrimary)
                    .focused($isCommentFieldFocused)
                    .submitLabel(.send)
                    .onSubmit {
                        submitComment()
                    }
                    .onChange(of: commentDraft) { _, newValue in
                        if newValue.count > 300 {
                            commentDraft = String(newValue.prefix(300))
                        }
                    }

                if !commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        submitComment()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(CuvenColors.onCtaInk)
                            .frame(width: 32, height: 32)
                            .background(CuvenColors.ctaInk, in: Circle())
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSubmittingComment)
                    .accessibilityLabel("Post comment")
                }
            }
            .frame(minHeight: 38)
            .padding(.leading, 16)
            .padding(.trailing, 8)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 14, weight: .medium))
                Text(post.commentPolicy == "off"
                     ? "Comments are off"
                     : "Only \(authorDisplayName)'s friends can comment")
                    .font(.system(size: 14))
            }
            .foregroundStyle(CuvenColors.inkSecondary)
            .frame(minHeight: 32, alignment: .leading)
            .padding(.horizontal, 16)
        }
    }

    // MARK: - 8. Timestamp, Scheduled Status & Audience Indicator (`moments.js:530-532`)

    private var timestampAndAudienceFooter: some View {
        HStack(spacing: 6) {
            if isScheduledFuture, let scheduledAt = post.scheduledAt {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Scheduled for \(MomentsTimeFormatter.scheduledWhenText(timestamp: scheduledAt, use24Hour: store.prefs.use24HourTime))")
                        .fontWeight(.semibold)
                }
                .foregroundStyle(MomentsPalette.accessibleBlueText)
            } else {
                Text(MomentsTimeFormatter.agoLong(timestamp: post.createdAt))
                    .foregroundStyle(CuvenColors.inkSecondary)
            }

            Text("·")
                .foregroundStyle(CuvenColors.inkSecondary)

            HStack(spacing: 4) {
                Image(systemName: post.audience == "friends" ? "person.2.fill" : "globe")
                    .font(.system(size: 11, weight: .medium))
                Text(post.audience == "friends" ? "Friends" : "Everyone")
            }
            .foregroundStyle(CuvenColors.inkSecondary)
        }
        .font(CuvenFonts.cappedCaption(weight: .regular))
        .padding(.horizontal, 16)
    }

    // MARK: - Interactions & Animations

    private func triggerDoubleTapLikeBurst() {
        CuvenHaptics.rigidImpact()

        if !isLikedByMe {
            Task {
                await store.toggleMomentLike(momentID: post.id)
            }
        }

        showHeartBurst = true
        if reduceMotion {
            heartBurstScale = 1.0
            heartBurstOpacity = 1.0
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                withAnimation(.easeOut(duration: 0.12)) {
                    heartBurstOpacity = 0.0
                }
                try? await Task.sleep(nanoseconds: 140_000_000)
                showHeartBurst = false
            }
            return
        }

        heartBurstScale = 0.30
        heartBurstOpacity = 0.0
        particleSpread = 0.15

        withAnimation(.spring(response: 0.28, dampingFraction: 0.58)) {
            heartBurstScale = 1.14
            heartBurstOpacity = 1.0
            particleSpread = 1.0
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 260_000_000)
            withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                heartBurstScale = 0.98
            }
            try? await Task.sleep(nanoseconds: 280_000_000)
            withAnimation(.easeOut(duration: 0.24)) {
                heartBurstScale = 1.08
                heartBurstOpacity = 0.0
            }
            try? await Task.sleep(nanoseconds: 260_000_000)
            showHeartBurst = false
        }
    }

    private func toggleLikeFromButton() {
        let wasLiked = isLikedByMe
        if !wasLiked {
            CuvenHaptics.rigidImpact()
            if !reduceMotion {
                likeIconBounce = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 220_000_000)
                    likeIconBounce = false
                }
            }
        } else {
            CuvenHaptics.lightTap()
        }
        Task {
            await store.toggleMomentLike(momentID: post.id)
        }
    }

    private func submitComment() {
        let trimmed = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSubmittingComment else { return }
        isSubmittingComment = true
        commentDraft = ""
        CuvenHaptics.lightTap()
        Task {
            await store.addMomentComment(momentID: post.id, text: trimmed)
            isSubmittingComment = false
        }
    }

    private func photoAccessibilityLabel(for item: MomentMedia, index: Int) -> String {
        let prefix = post.media.count > 1 ? "Photo \(index + 1) of \(post.media.count)" : "Photo"
        if let alt = item.altText, !alt.isEmpty {
            return "\(prefix): \(alt)"
        }
        return prefix
    }

    private var likeAccessibilityLabel: String {
        let actionWord = isLikedByMe ? "Unlike" : "Like"
        if post.likedUserIDs.isEmpty {
            return actionWord
        }
        return "\(actionWord), \(post.likedUserIDs.count) \(post.likedUserIDs.count == 1 ? "like" : "likes")"
    }

    private var shareSummaryText: String {
        if post.text.isEmpty {
            return "\(authorDisplayName)'s moment on Cuven (@\(post.author.username))"
        }
        let snippet = post.text.count > 160 ? String(post.text.prefix(157)) + "…" : post.text
        return "\(authorDisplayName) on Cuven: “\(snippet)” (@\(post.author.username))"
    }
}

// MARK: - Frosted Dark Pill Modifier over Photo vs Standard Surface Pill (`moments.css:265-273`)

private struct MomentActionPillMaterial: ViewModifier {
    let overPhoto: Bool
    let glassMode: GlassAppearanceMode
    let reduceTransparency: Bool

    func body(content: Content) -> some View {
        if overPhoto {
            if reduceTransparency {
                content
                    .background(Color(white: 0.14), in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(Color.white.opacity(0.24), lineWidth: 0.75)
                    }
            } else {
                content
                    .background(.ultraThinMaterial, in: Capsule())
                    .background(Color.black.opacity(0.36), in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.24), radius: 8, x: 0, y: 3)
            }
        } else {
            content
                .cuvenLiquidGlass(mode: glassMode, cornerRadius: 22, interactiveBounce: true)
        }
    }
}

// MARK: - Adaptive 1 / 2 / 3 / 4+ Photo Collage Grid (`DISPATCH.md` Item 1)

struct MomentCollageGridView: View {
    let media: [MomentMedia]
    let serverBaseURL: URL
    let onTapPhoto: (Int) -> Void
    let onDoubleTapPhoto: () -> Void
    let onTapAlt: (String) -> Void

    private let spacing: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            switch media.count {
            case 0:
                EmptyView()
            case 1:
                collageTile(index: 0, width: w, height: h, extraCount: 0)
            case 2:
                let tileW = (w - spacing) * 0.5
                HStack(spacing: spacing) {
                    collageTile(index: 0, width: tileW, height: h, extraCount: 0)
                    collageTile(index: 1, width: tileW, height: h, extraCount: 0)
                }
            case 3:
                let leftW = (w - spacing) * 0.60
                let rightW = w - spacing - leftW
                let rightH = (h - spacing) * 0.5
                HStack(spacing: spacing) {
                    collageTile(index: 0, width: leftW, height: h, extraCount: 0)
                    VStack(spacing: spacing) {
                        collageTile(index: 1, width: rightW, height: rightH, extraCount: 0)
                        collageTile(index: 2, width: rightW, height: rightH, extraCount: 0)
                    }
                }
            default:
                let tileW = (w - spacing) * 0.5
                let tileH = (h - spacing) * 0.5
                let overflow = max(0, media.count - 4)
                VStack(spacing: spacing) {
                    HStack(spacing: spacing) {
                        collageTile(index: 0, width: tileW, height: tileH, extraCount: 0)
                        collageTile(index: 1, width: tileW, height: tileH, extraCount: 0)
                    }
                    HStack(spacing: spacing) {
                        collageTile(index: 2, width: tileW, height: tileH, extraCount: 0)
                        collageTile(index: 3, width: tileW, height: tileH, extraCount: overflow)
                    }
                }
            }
        }
    }

    private func collageTile(index: Int, width: CGFloat, height: CGFloat, extraCount: Int) -> some View {
        let item = media[index]
        return ZStack(alignment: .topLeading) {
            MomentsMediaThumbnailView(
                urlString: item.url,
                serverBaseURL: serverBaseURL,
                filterName: item.filterName,
                altLabel: item.altText ?? "Photo \(index + 1) of \(media.count)",
                contentMode: .fill
            )
            .frame(width: max(1, width), height: max(1, height))
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                onDoubleTapPhoto()
            }
            .onTapGesture(count: 1) {
                onTapPhoto(index)
            }

            if extraCount > 0 {
                Color.black.opacity(0.46)
                    .frame(width: max(1, width), height: max(1, height))
                    .overlay {
                        Text("+\(extraCount)")
                            .font(.system(size: 24, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                    }
                    .allowsHitTesting(false)
            }

            if let alt = item.altText, !alt.isEmpty {
                Button {
                    onTapAlt(alt)
                } label: {
                    Text("ALT")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.64), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(8)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: max(1, width), height: max(1, height))
    }
}

// MARK: - ALT Accessibility Description Sheet (`moments.js:715-718`)

private struct AltDescriptionReaderSheet: View {
    let descriptionText: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(descriptionText)
                    .font(CuvenFonts.cappedBody(weight: .regular))
                    .foregroundStyle(CuvenColors.inkPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .background(CuvenColors.paperBackground)
            .navigationTitle("Description")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Moment Lightbox Overlay (Wraps Canonical `FullscreenMediaLightboxView` + Like/Comment Bar)

struct MomentMediaLightboxOverlay: View {
    let store: AppStore
    let post: MomentPost
    let initialIndex: Int
    let onDismiss: () -> Void

    @State private var commentText: String = ""

    private var livePost: MomentPost {
        store.moments.first(where: { $0.id == post.id }) ?? post
    }

    private var isLiked: Bool {
        guard let me = store.currentUser?.id else { return false }
        return livePost.likedUserIDs.contains(me)
    }

    private var canViewerComment: Bool {
        let isMine = livePost.author.id == store.currentUser?.id
        switch livePost.commentPolicy {
        case "off":
            return false
        case "friends":
            if isMine { return true }
            let authorID = livePost.author.id
            if store.contacts.contains(where: { $0.user.id == authorID && $0.status == .accepted }) {
                return true
            }
            return store.rooms.contains(where: { $0.kind == .dm && $0.peerUserID == authorID })
        default:
            return true
        }
    }

    private var clampedMediaItem: MomentMedia? {
        guard !livePost.media.isEmpty else { return nil }
        let idx = min(max(0, initialIndex), livePost.media.count - 1)
        return livePost.media[idx]
    }

    var body: some View {
        GeometryReader { proxy in
            let safeTrailing = proxy.safeAreaInsets.trailing
            ZStack(alignment: .bottom) {
                FullscreenMediaLightboxView(
                    mediaURLs: livePost.media.map(\.url),
                    initialIndex: min(max(0, initialIndex), max(0, livePost.media.count - 1)),
                    onDismiss: onDismiss
                )

                // Moment-specific Like + Quick Reply footer (`moments.js:479-489`),
                // elevated clear of multi-photo gallery dots and Duo right system column.
                VStack(spacing: 10) {
                    if let alt = clampedMediaItem?.altText, !alt.isEmpty {
                        Text(alt)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.88))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 16)
                            .padding(.trailing, max(16, safeTrailing + 12))
                    }

                    HStack(spacing: 10) {
                        if canViewerComment {
                            HStack(spacing: 8) {
                                TextField("Add a comment…", text: $commentText)
                                    .font(.system(size: 15))
                                    .foregroundStyle(.white)
                                    .tint(.white)
                                    .submitLabel(.send)
                                    .onSubmit { sendLightboxComment() }

                                if !commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Button {
                                        sendLightboxComment()
                                    } label: {
                                        Image(systemName: "arrow.up.circle.fill")
                                            .font(.system(size: 24))
                                            .foregroundStyle(.white)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Post comment")
                                }
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 44)
                            .background(.ultraThinMaterial, in: Capsule())
                        }

                        Button {
                            CuvenHaptics.rigidImpact()
                            Task { await store.toggleMomentLike(momentID: livePost.id) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isLiked ? "heart.fill" : "heart")
                                    .foregroundStyle(isLiked ? CuvenColors.dangerRed : .white)
                                if !livePost.likedUserIDs.isEmpty {
                                    Text("\(livePost.likedUserIDs.count)")
                                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(.white)
                                }
                            }
                            .padding(.horizontal, 14)
                            .frame(minWidth: 44, minHeight: 44)
                            .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isLiked ? "Unlike" : "Like")
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, max(16, safeTrailing + 12))
                    .padding(.bottom, livePost.media.count > 1 ? max(78, proxy.safeAreaInsets.bottom + 68) : max(20, proxy.safeAreaInsets.bottom + 12))
                }
            }
        }
    }

    private func sendLightboxComment() {
        let trimmed = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        commentText = ""
        CuvenHaptics.lightTap()
        Task {
            await store.addMomentComment(momentID: livePost.id, text: trimmed)
        }
    }
}

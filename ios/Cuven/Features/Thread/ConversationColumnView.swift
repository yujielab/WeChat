import SwiftUI
import UIKit
import CuvenCore

// MARK: - Conversation Thread Column (`PROJECT.md § 5.4-5.5`, `thread.js`, `chat.css`, `posture.css`)
//
// Apple HIG & iOS 27.1 SDK Grounding:
// - Apple HIG › Designing for iPhone Duo:
//   * Constant `525pt` foreground content width on `951×669` `duoOpen` across `List | Thread` (`342 | 609`)
//     and `Thread | Details` (`525 | 426`) — zero bubble reflow during column pan!
//   * `duoHalfLaptop` tabletop horizontal hinge split: messages & header above `metrics.hingeDivisionRect`,
//     empty hinge crease gutter, and tabletop composer + quick controls flat below the fold.
//   * Right-edge system column clearance (`84pt` inner / `91pt` outer) when `DuoRailView` owns trailing chrome.
// - Apple HIG › Materials & Gestures:
//   * `92pt` Large-Avatar (`58pt`) Liquid Glass Header Pill (`thread.headerPill`) with `-10pt` overlapping
//     `Name · Status` + `#1877F2` `(i)` Room Info button.
//   * Stationary counter-translated `thread.backButton` (`offset(x: panLeadOffset)`).
//   * `460ms` long-press `LiftedBubbleContextMenu` over `26pt` Gaussian-blurred conversation backdrop.

public struct ConversationColumnView: View {
    @Bindable private var store: AppStore
    private let roomID: String
    private let metrics: DuoLayoutMetrics
    private let panLeadOffset: CGFloat
    private let onBack: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var voicePlayer = VoiceMessagePlayer()
    @State private var expandedPhotoStackIDs: Set<String> = []
    @State private var timeRevealOffset: CGFloat = 0
    @State private var isDraggingTimeReveal: Bool = false

    @State private var isNearBottom: Bool = true
    @State private var initialUnreadCountSnapshot: Int = 0
    @State private var pendingNewMessagesBelow: Int = 0
    @State private var unseenMentionIDs: [String] = []
    @State private var flashedMessageID: String? = nil

    @State private var liftedContextTarget: LiftedBubbleTarget? = nil
    @State private var activeLightbox: ThreadLightboxPresentation? = nil
    @State private var activeExplainRequest: ExplainSelectionRequest? = nil
    @State private var isExplainModalPresented: Bool = false
    @State private var activePeerProfileUser: CuvenUser? = nil
    @State private var isPeerProfileModalPresented: Bool = false

    private static let bottomAnchorID = "cuven.thread.bottomAnchor"

    /// Canonical `PROJECT.md § 5.4` initializer.
    public init(
        store: AppStore,
        roomID: String,
        metrics: DuoLayoutMetrics,
        panLeadOffset: CGFloat = 0,
        onBack: @escaping () -> Void
    ) {
        self.store = store
        self.roomID = roomID
        self.metrics = metrics
        self.panLeadOffset = panLeadOffset
        self.onBack = onBack
    }

    // MARK: - Derived Room, Peer & Spatial Properties

    private var room: Room? {
        store.rooms.first { $0.id == roomID }
    }

    private var messages: [Message] {
        store.messagesByRoom[roomID] ?? []
    }

    private var messagesByID: [String: Message] {
        var dict: [String: Message] = [:]
        dict.reserveCapacity(messages.count)
        for msg in messages {
            dict[msg.id] = msg
        }
        return dict
    }

    private var contactsByUserID: [String: CuvenUser] {
        var dict: [String: CuvenUser] = [:]
        for item in store.contacts {
            dict[item.user.id] = item.user
        }
        if let me = store.currentUser {
            dict[me.id] = me
        }
        return dict
    }

    private var dmPeerUser: CuvenUser? {
        guard let room, room.kind == .dm else { return nil }
        if let peerID = room.peerUserID, let found = contactsByUserID[peerID] {
            return found
        }
        let myID = store.currentUser?.id
        if let memberID = room.memberIDs.first(where: { $0 != myID }),
           let found = contactsByUserID[memberID]
        {
            return found
        }
        return CuvenUser(
            id: room.peerUserID ?? "peer_\(room.id)",
            username: room.title.lowercased().replacingOccurrences(of: " ", with: ""),
            display: room.title,
            avatarURL: room.avatarURL,
            isOnline: false
        )
    }

    private var isPeerOnline: Bool {
        dmPeerUser?.isOnline ?? false
    }

    private var activeBackdropPreset: BackdropPreset {
        room?.backdrop ?? store.prefs.defaultBackdrop
    }

    private var liveTypingPreview: String? {
        guard let raw = store.typingPreviewByRoom[roomID]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        return raw
    }

    private var headerSubtitleStatus: String {
        if liveTypingPreview != nil {
            return "typing…"
        }
        guard let room else { return "" }
        if room.kind == .group {
            let count = max(room.memberIDs.count, 2)
            return "\(count) members"
        }
        if let peerID = room.peerUserID,
           let activeNote = store.notes.first(where: { $0.userID == peerID && EditPolicyValidator.isNoteActive($0) }),
           !activeNote.text.isEmpty
        {
            return activeNote.text
        }
        if isPeerOnline {
            return "Active now"
        }
        return room.subtitle
    }

    /// True when `DuoRightEdgeChromeOverlay` (`DuoRailView`) is actively rendering Thread's controls in the right rail.
    private var isThreadOwnedByDuoRail: Bool {
        metrics.hasRightSystemColumn
    }

    /// True when `ThreadComposerBar` should display the leading stationary `thread.backButton`.
    private var shouldShowComposerBackButton: Bool {
        metrics.visibleColumnCount == 1 && !isThreadOwnedByDuoRail
    }

    /// Trailing horizontal inset preserving exact `525pt` content width on `duoOpen` and clearing Duo's right rail.
    private var effectiveTrailingInset: CGFloat {
        if metrics.visibleColumnCount >= 2 {
            // `StripContainerView.columnScopedMetrics` continuously interpolates `safeAreaRight` (`84 -> 0`),
            // keeping `columnWidth - safeAreaRight == 525.0pt` at every single animation frame!
            return metrics.safeAreaRight
        }
        if metrics.hasRightSystemColumn {
            return max(metrics.safeAreaRight, metrics.posture == .duoClosed ? 91 : 84)
        }
        return metrics.safeAreaRight
    }

    private var otherRoomsUnreadCount: Int {
        store.rooms.reduce(into: 0) { acc, candidate in
            guard !candidate.isHidden, candidate.id != roomID else { return }
            acc += max(candidate.unreadCount, candidate.isMarkedUnread ? 1 : 0)
        }
    }

    private var displayItems: [ThreadDisplayItem] {
        ThreadGroupingEngine.buildDisplayItems(
            messages: messages,
            currentUserID: store.currentUser?.id,
            roomKind: room?.kind ?? .dm,
            unreadCount: initialUnreadCountSnapshot,
            use24HourTime: store.prefs.use24HourTime,
            expandedPhotoStackIDs: expandedPhotoStackIDs
        )
    }

    // MARK: - Body

    public var body: some View {
        GeometryReader { columnGeo in
            let usableWidth = max(
                240,
                columnGeo.size.width - metrics.safeAreaLeft - effectiveTrailingInset
            )
            let contentWidth = metrics.threadContentWidth > 0
                ? min(usableWidth, metrics.threadContentWidth)
                : usableWidth
            let maxBubbleWidth = min(380, floor(contentWidth * 0.78))

            ZStack(alignment: .topLeading) {
                // Layer 1 & 2: Full-bleed Backdrop + Foreground Thread Content (blurred 26pt when bubble is lifted)
                ZStack(alignment: .topLeading) {
                    CuvenBackdropView(preset: activeBackdropPreset)

                    if metrics.posture == .duoHalfLaptop,
                       let foldRect = metrics.hingeDivisionRect,
                       foldRect.minY > 140
                    {
                        tabletopLaptopLayout(
                            totalSize: columnGeo.size,
                            contentWidth: contentWidth,
                            maxBubbleWidth: maxBubbleWidth,
                            foldRect: foldRect
                        )
                    } else {
                        standardVerticalThreadLayout(
                            contentWidth: contentWidth,
                            maxBubbleWidth: maxBubbleWidth
                        )
                    }
                }
                .blur(radius: (liftedContextTarget != nil && !reduceTransparency) ? 26 : 0)
                .animation(
                    reduceMotion ? .easeOut(duration: 0.14) : .easeOut(duration: 0.2),
                    value: liftedContextTarget?.message.id
                )

                // Layer 3: 460ms Lifted Bubble Context Menu Overlay (`26pt` blurred backdrop + 1:1 bubble + 6 tapbacks)
                if let lifted = liftedContextTarget {
                    let liveMessage = messagesByID[lifted.message.id] ?? lifted.message
                    LiftedBubbleContextMenu(
                        message: liveMessage,
                        isOutgoing: lifted.isOutgoing,
                        measuredBubbleSize: lifted.measuredSize,
                        serverBaseURL: store.serverBaseURL,
                        currentUserID: store.currentUser?.id,
                        glassMode: store.prefs.glassMode,
                        use24HourTime: store.prefs.use24HourTime,
                        smartAssistEnabled: store.prefs.smartAssistEnabled,
                        startWithHistoryExpanded: lifted.expandEditHistoryImmediately,
                        onSelectReaction: { emoji in
                            Task {
                                await store.toggleReaction(emoji, on: liveMessage.id, in: roomID)
                            }
                        },
                        onReply: {
                            withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
                                store.editingMessageByRoom.removeValue(forKey: roomID)
                                store.replyingToMessageByRoom[roomID] = liveMessage
                            }
                        },
                        onCopy: {
                            UIPasteboard.general.string = liveMessage.text
                        },
                        onExplainWithAI: {
                            let seed = preferredExplainSeed(for: liveMessage)
                            presentExplainSheet(initialText: seed, contextMessage: liveMessage.text)
                        },
                        onEdit: {
                            withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
                                store.replyingToMessageByRoom.removeValue(forKey: roomID)
                                store.editingMessageByRoom[roomID] = liveMessage
                            }
                        },
                        onUnsend: {
                            Task {
                                await store.revokeMessage(liveMessage.id, in: roomID)
                            }
                        },
                        onDismiss: {
                            liftedContextTarget = nil
                        }
                    )
                    .zIndex(40)
                }

                // Layer 4: Fullscreen Media Lightbox (`FullscreenMediaLightboxView`)
                if let lightbox = activeLightbox {
                    FullscreenMediaLightboxView(
                        mediaURLs: lightbox.urls,
                        initialIndex: lightbox.initialIndex,
                        onDismiss: {
                            withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
                                activeLightbox = nil
                            }
                        }
                    )
                    .zIndex(60)
                    .transition(.opacity)
                }
            }
            .frame(width: columnGeo.size.width, height: columnGeo.size.height)
        }
        .cuvenAdaptiveModal(
            isPresented: $isExplainModalPresented,
            metrics: metrics,
            tall: true
        ) {
            if let req = activeExplainRequest {
                WordPickerExplainSheet(
                    store: store,
                    initialText: req.initialText,
                    roomContext: req.roomContext,
                    onClose: {
                        withAnimation(CuvenSprings.adaptive(CuvenSprings.sheetPresent, reduceMotion: reduceMotion)) {
                            isExplainModalPresented = false
                        }
                    }
                )
            }
        }
        .cuvenAdaptiveModal(
            isPresented: $isPeerProfileModalPresented,
            metrics: metrics,
            tall: true
        ) {
            if let peer = activePeerProfileUser {
                UserMomentsProfileView(
                    store: store,
                    user: peer,
                    metrics: metrics,
                    onBack: {
                        withAnimation(CuvenSprings.adaptive(CuvenSprings.sheetPresent, reduceMotion: reduceMotion)) {
                            isPeerProfileModalPresented = false
                        }
                    },
                    onStartChat: { _ in
                        withAnimation(CuvenSprings.adaptive(CuvenSprings.sheetPresent, reduceMotion: reduceMotion)) {
                            isPeerProfileModalPresented = false
                        }
                    }
                )
            }
        }
        .onAppear {
            configureRoomOnOpen()
        }
        .onChange(of: roomID) { _, _ in
            voicePlayer.stop()
            liftedContextTarget = nil
            expandedPhotoStackIDs.removeAll()
            configureRoomOnOpen()
        }
        .onDisappear {
            voicePlayer.stop()
        }
    }

    // MARK: - 1. Standard Vertical Thread Layout (`iPhoneCompact`, `iPhoneSplit`, `duoClosed`, `duoHalfBook`, `duoOpen`)

    private func standardVerticalThreadLayout(
        contentWidth: CGFloat,
        maxBubbleWidth: CGFloat
    ) -> some View {
        ScrollViewReader { scrollProxy in
            ZStack(alignment: .top) {
                // Message Stream (`thread.messageList`) extending under top header & bottom composer glass
                VStack(spacing: 0) {
                    messageScrollStream(
                        scrollProxy: scrollProxy,
                        maxBubbleWidth: maxBubbleWidth,
                        topInset: max(metrics.safeAreaTop, 8) + 96,
                        bottomInset: 16
                    )

                    ThreadComposerBar(
                        store: store,
                        roomID: roomID,
                        room: room,
                        showsLeadingBackButton: shouldShowComposerBackButton,
                        otherUnreadCount: otherRoomsUnreadCount,
                        panLeadOffset: panLeadOffset,
                        onBack: onBack,
                        onSubmittedMessage: {
                            scrollToBottom(using: scrollProxy, animated: true)
                        },
                        onJumpToMessage: { targetID in
                            jumpAndFlashMessage(id: targetID, using: scrollProxy)
                        }
                    )
                    .padding(.bottom, max(4, metrics.safeAreaBottom > 0 ? metrics.safeAreaBottom - 6 : 6))
                }
                .overlay(alignment: .bottomTrailing) {
                    floatingJumpControls(scrollProxy: scrollProxy)
                        .padding(.trailing, 14)
                        .padding(.bottom, max(74, metrics.safeAreaBottom + 66))
                }

                // Floating `92pt` Large-Avatar Liquid Glass Header (`thread.headerPill`)
                conversationHeaderNav
                    .padding(.top, max(4, metrics.safeAreaTop))
            }
            .frame(width: contentWidth)
            .padding(.leading, metrics.safeAreaLeft)
            .padding(.trailing, effectiveTrailingInset)
        }
    }

    // MARK: - 2. `duoHalfLaptop` Tabletop Split Adaptation (`posture.css:26-74`)

    private func tabletopLaptopLayout(
        totalSize: CGSize,
        contentWidth: CGFloat,
        maxBubbleWidth: CGFloat,
        foldRect: CGRect
    ) -> some View {
        let upperPaneHeight = max(160, foldRect.minY)
        let hingeHeight = max(0, foldRect.height)
        let lowerPaneHeight = max(140, totalSize.height - upperPaneHeight - hingeHeight)

        return ScrollViewReader { scrollProxy in
            VStack(spacing: 0) {
                // Upper Half (Above Horizontal Hinge): `92pt` Header + Scrollable Messages
                ZStack(alignment: .top) {
                    messageScrollStream(
                        scrollProxy: scrollProxy,
                        maxBubbleWidth: maxBubbleWidth,
                        topInset: max(metrics.safeAreaTop, 6) + 92,
                        bottomInset: 18
                    )

                    conversationHeaderNav
                        .padding(.top, max(4, metrics.safeAreaTop))
                }
                .frame(width: contentWidth, height: upperPaneHeight)
                .clipped()

                // Physical Horizontal Hinge Crease Gutter ("Nothing sits in the bend" — `posture.css:30`)
                Color.clear
                    .frame(width: contentWidth, height: hingeHeight)
                    .accessibilityHidden(true)

                // Lower Tabletop Deck (Below Horizontal Hinge): Quick Action Strip + Composer Flat on Table
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        floatingJumpControls(scrollProxy: scrollProxy)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)

                    Spacer(minLength: 0)

                    ThreadComposerBar(
                        store: store,
                        roomID: roomID,
                        room: room,
                        showsLeadingBackButton: shouldShowComposerBackButton,
                        otherUnreadCount: otherRoomsUnreadCount,
                        panLeadOffset: panLeadOffset,
                        onBack: onBack,
                        onSubmittedMessage: {
                            scrollToBottom(using: scrollProxy, animated: true)
                        },
                        onJumpToMessage: { targetID in
                            jumpAndFlashMessage(id: targetID, using: scrollProxy)
                        }
                    )
                    .padding(.bottom, max(8, metrics.safeAreaBottom))
                }
                .frame(width: contentWidth, height: lowerPaneHeight)
            }
            .padding(.leading, metrics.safeAreaLeft)
            .padding(.trailing, effectiveTrailingInset)
        }
    }

    // MARK: - `92pt` Large-Avatar Liquid Glass Header (`chat.css:13-98`, `thread.headerPill`)

    private var conversationHeaderNav: some View {
        let sideSlotWidth: CGFloat = isThreadOwnedByDuoRail ? 0 : 96

        return HStack(alignment: .center, spacing: 8) {
            // Leading Slot: Audio + Video Call Liquid Glass Capsule (`thread.callAudioButton`, `thread.callVideoButton`)
            if !isThreadOwnedByDuoRail {
                HStack(spacing: 2) {
                    Button {
                        CuvenHaptics.lightTap()
                        store.startCall(in: roomID, kind: .audio)
                    } label: {
                        Image(systemName: "phone")
                            .font(.system(size: 17.5, weight: .medium))
                            .foregroundStyle(CuvenColors.inkPrimary)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("thread.callAudioButton")
                    .accessibilityLabel("Voice call")

                    Button {
                        CuvenHaptics.lightTap()
                        store.startCall(in: roomID, kind: .video)
                    } label: {
                        Image(systemName: "video")
                            .font(.system(size: 17.5, weight: .medium))
                            .foregroundStyle(CuvenColors.inkPrimary)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("thread.callVideoButton")
                    .accessibilityLabel("Video call")
                }
                .padding(4)
                .cuvenLiquidGlass(mode: store.prefs.glassMode, cornerRadius: 26, interactiveBounce: true)
                .frame(width: sideSlotWidth, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }

            // Center Slot: `58pt` Elevated Avatar + `-10pt` Overlapping `Name · Status` + `#1877F2` `(i)` Pill
            VStack(spacing: -10) {
                Button {
                    handleHeaderIdentityTapped()
                } label: {
                    CuvenAvatarView(
                        name: room?.title ?? "Chat",
                        urlString: room?.avatarURL,
                        size: 58,
                        isOnline: isPeerOnline,
                        isGroupSquircle: room?.kind == .group,
                        showElevationRing: true
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)

                HStack(spacing: 0) {
                    Button {
                        handleHeaderIdentityTapped()
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(room?.title ?? "Conversation")
                                .font(CuvenFonts.cappedSubheadline(weight: .bold))
                                .foregroundStyle(CuvenColors.inkPrimary)
                                .lineLimit(1)

                            if !headerSubtitleStatus.isEmpty {
                                Text("·")
                                    .font(CuvenFonts.cappedCaption2(weight: .semibold))
                                    .foregroundStyle(CuvenColors.inkSecondary)

                                Text(headerSubtitleStatus)
                                    .font(CuvenFonts.cappedCaption2(weight: liveTypingPreview != nil ? .semibold : .regular))
                                    .foregroundStyle(
                                        liveTypingPreview != nil
                                            ? CuvenColors.accessibleBlueText
                                            : CuvenColors.inkSecondary
                                    )
                                    .lineLimit(1)
                            }
                        }
                        .padding(.leading, 12)
                        .padding(.trailing, 5)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(room?.title ?? "Conversation"), \(headerSubtitleStatus)")

                    // `#1877F2` (`CuvenColors.sidebarBlue`) `(i)` Room Info Toggle (`chat.css:78-91`)
                    Button {
                        CuvenHaptics.lightTap()
                        toggleArtifactMode(.roomInfo)
                    } label: {
                        Image(systemName: store.activeArtifactMode == .roomInfo ? "info.circle.fill" : "info.circle")
                            .font(.system(size: 16.5, weight: .semibold))
                            .foregroundStyle(CuvenColors.sidebarBlue)
                            .padding(.leading, 3)
                            .padding(.trailing, 10)
                            .padding(.vertical, 6)
                            .frame(minWidth: 34, minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Chat info")
                    .accessibilityAddTraits(store.activeArtifactMode == .roomInfo ? .isSelected : [])
                }
                .background(CuvenColors.elevatedSurface, in: Capsule())
                .overlay(Capsule().strokeBorder(CuvenColors.cardLine, lineWidth: 1))
                .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 3)
                .zIndex(1)
            }
            .frame(maxWidth: 264)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("thread.headerPill")

            // Trailing Slot: Collaborative Drawing Board Button (`thread.drawButton`)
            if !isThreadOwnedByDuoRail {
                let isDrawOpen = (store.activeArtifactMode == .drawingBoard)
                Button {
                    CuvenHaptics.lightTap()
                    toggleArtifactMode(.drawingBoard)
                } label: {
                    ZStack {
                        if isDrawOpen {
                            Circle()
                                .fill(CuvenColors.ctaInk)
                                .frame(width: 44, height: 44)
                        }
                        Image(systemName: "pencil.and.scribble")
                            .font(.system(size: 17.5, weight: .semibold))
                            .foregroundStyle(isDrawOpen ? CuvenColors.onCtaInk : CuvenColors.inkPrimary)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .modifier(
                        ConditionalHeaderGlassCircle(
                            isEnabled: !isDrawOpen,
                            glassMode: store.prefs.glassMode
                        )
                    )
                }
                .buttonStyle(.plain)
                .frame(width: sideSlotWidth, alignment: .trailing)
                .accessibilityIdentifier("thread.drawButton")
                .accessibilityLabel("Drawing board")
                .accessibilityAddTraits(isDrawOpen ? .isSelected : [])
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 92)
    }

    // MARK: - Message Scroll Stream (`thread.messageList`) & Time-Reveal Gesture

    private func messageScrollStream(
        scrollProxy: ScrollViewProxy,
        maxBubbleWidth: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                Color.clear
                    .frame(height: topInset)
                    .accessibilityHidden(true)

                if displayItems.isEmpty && liveTypingPreview == nil {
                    emptyThreadWelcomeCard
                        .padding(.top, 42)
                } else {
                    ForEach(displayItems) { item in
                        MessageBubbleView(
                            item: item,
                            currentUserID: store.currentUser?.id,
                            messagesByID: messagesByID,
                            contactsByUserID: contactsByUserID,
                            serverBaseURL: store.serverBaseURL,
                            maxBubbleWidth: maxBubbleWidth,
                            glassMode: store.prefs.glassMode,
                            use24HourTime: store.prefs.use24HourTime,
                            smartAssistEnabled: store.prefs.smartAssistEnabled,
                            editingMessageID: store.editingMessageByRoom[roomID]?.id,
                            liftedMessageID: liftedContextTarget?.message.id,
                            flashedMessageID: flashedMessageID,
                            timeRevealOffset: timeRevealOffset,
                            voicePlayer: voicePlayer,
                            onReply: { targetMsg in
                                withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
                                    store.editingMessageByRoom.removeValue(forKey: roomID)
                                    store.replyingToMessageByRoom[roomID] = targetMsg
                                }
                            },
                            onJumpToMessage: { targetID in
                                jumpAndFlashMessage(id: targetID, using: scrollProxy)
                            },
                            onOpenContextMenu: { targetMsg, isOut, measuredSize in
                                liftedContextTarget = LiftedBubbleTarget(
                                    message: targetMsg,
                                    isOutgoing: isOut,
                                    measuredSize: measuredSize,
                                    expandEditHistoryImmediately: false
                                )
                            },
                            onQuickHeartReaction: { targetMsg in
                                Task {
                                    await store.toggleReaction("❤️", on: targetMsg.id, in: roomID)
                                }
                            },
                            onOpenExplain: { targetMsg, seedWord in
                                presentExplainSheet(initialText: seedWord, contextMessage: targetMsg.text)
                            },
                            onOpenEditHistory: { targetMsg in
                                let isOut = (targetMsg.senderID == store.currentUser?.id)
                                liftedContextTarget = LiftedBubbleTarget(
                                    message: targetMsg,
                                    isOutgoing: isOut,
                                    measuredSize: nil,
                                    expandEditHistoryImmediately: true
                                )
                            },
                            onOpenLightbox: { urls, index in
                                withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
                                    activeLightbox = ThreadLightboxPresentation(urls: urls, initialIndex: index)
                                }
                            },
                            onExpandPhotoStack: { stackID in
                                withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
                                    _ = expandedPhotoStackIDs.insert(stackID)
                                }
                            },
                            onRetryFailed: { failedMsg in
                                Task {
                                    await store.retryFailedMessage(failedMsg.localID ?? failedMsg.id, in: roomID)
                                }
                            }
                        )
                        .id(messageRowScrollID(for: item))
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .asymmetric(
                                    insertion: .scale(scale: 0.94, anchor: .bottom).combined(with: .opacity),
                                    removal: .opacity
                                )
                        )
                    }
                }

                // Real-time Honk Live Typing Ghost Bubble (`HonkLiveTypingBubble`)
                if let typing = liveTypingPreview {
                    HonkLiveTypingBubble(
                        previewText: typing,
                        peerName: room?.title ?? "Peer",
                        peerAvatarURL: dmPeerUser?.avatarURL ?? room?.avatarURL,
                        showGroupChrome: room?.kind == .group
                    )
                    .padding(.horizontal, 4)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                // Bottom Scroll Sentinel (`atBottom` tracker)
                Color.clear
                    .frame(height: max(8, bottomInset))
                    .id(Self.bottomAnchorID)
                    .onAppear {
                        isNearBottom = true
                        pendingNewMessagesBelow = 0
                    }
                    .onDisappear {
                        isNearBottom = false
                    }
            }
            .padding(.horizontal, 8)
        }
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(dragLeftTimestampRevealGesture)
        .accessibilityIdentifier("thread.messageList")
        .onChange(of: messages.count) { oldCount, newCount in
            guard newCount > oldCount else { return }
            let newest = messages.last
            let fromMe = (newest?.senderID == store.currentUser?.id)
            if fromMe || isNearBottom {
                scrollToBottom(using: scrollProxy, animated: !reduceMotion)
            } else {
                pendingNewMessagesBelow += (newCount - oldCount)
            }
        }
        .onAppear {
            scrollToBottom(using: scrollProxy, animated: false)
        }
    }

    private var emptyThreadWelcomeCard: some View {
        VStack(spacing: 10) {
            CuvenAvatarView(
                name: room?.title ?? "Chat",
                urlString: room?.avatarURL,
                size: 64,
                isOnline: isPeerOnline,
                isGroupSquircle: room?.kind == .group
            )
            Text("Say hello to \(room?.title ?? "start chatting")")
                .font(CuvenFonts.cappedHeadline(weight: .semibold))
                .foregroundStyle(CuvenColors.inkPrimary)
            Text("Messages, live sketches, voice notes, and stickers appear here.")
                .font(CuvenFonts.cappedFootnote())
                .foregroundStyle(CuvenColors.inkSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: 300)
        .cuvenLiquidGlass(mode: store.prefs.glassMode, cornerRadius: 24, interactiveBounce: false)
        .frame(maxWidth: .infinity)
    }

    /// Interactive drag-left gesture revealing tabular inline timestamps (`time-reveal.js` parity).
    private var dragLeftTimestampRevealGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard dx < -10, abs(dx) > abs(dy) * 1.4 else { return }
                isDraggingTimeReveal = true
                let rawPull = min(90, -dx - 10)
                timeRevealOffset = CuvenSprings.rubberBand(overshoot: rawPull, dimension: 72, resistance: 0.60)
            }
            .onEnded { _ in
                guard isDraggingTimeReveal else { return }
                isDraggingTimeReveal = false
                withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
                    timeRevealOffset = 0
                }
            }
    }

    // MARK: - Floating `@mention` & Jump-to-Latest Capsules (`thread.js:261-304`)

    @ViewBuilder
    private func floatingJumpControls(scrollProxy: ScrollViewProxy) -> some View {
        if !unseenMentionIDs.isEmpty {
            Button {
                CuvenHaptics.selectionChanged()
                let nextID = unseenMentionIDs.removeFirst()
                jumpAndFlashMessage(id: nextID, using: scrollProxy)
            } label: {
                HStack(spacing: 5) {
                    Text("@")
                        .font(.system(size: 14, weight: .bold))
                    Text("\(unseenMentionIDs.count)")
                        .font(.system(size: 12.5, weight: .bold).monospacedDigit())
                }
                .foregroundStyle(CuvenColors.onCtaInk)
                .padding(.horizontal, 12)
                .frame(minHeight: 38)
                .background(CuvenColors.sidebarBlue, in: Capsule())
                .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(unseenMentionIDs.count) unread mentions, tap to jump")
        } else if pendingNewMessagesBelow > 0 {
            Button {
                CuvenHaptics.lightTap()
                pendingNewMessagesBelow = 0
                scrollToBottom(using: scrollProxy, animated: true)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                    Text("\(pendingNewMessagesBelow) new \(pendingNewMessagesBelow == 1 ? "message" : "messages")")
                        .font(CuvenFonts.cappedFootnote(weight: .semibold))
                }
                .foregroundStyle(CuvenColors.inkPrimary)
                .padding(.horizontal, 14)
                .frame(minHeight: 38)
                .cuvenLiquidGlass(mode: store.prefs.glassMode, cornerRadius: 19, interactiveBounce: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(pendingNewMessagesBelow) new messages, jump to latest")
        } else if !isNearBottom {
            Button {
                CuvenHaptics.lightTap()
                scrollToBottom(using: scrollProxy, animated: true)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CuvenColors.inkPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .cuvenLiquidGlass(mode: store.prefs.glassMode, cornerRadius: 22, interactiveBounce: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Jump to latest message")
        }
    }

    // MARK: - Helpers & Navigation

    private func configureRoomOnOpen() {
        initialUnreadCountSnapshot = room?.unreadCount ?? 0
        pendingNewMessagesBelow = 0

        if let myID = store.currentUser?.id {
            unseenMentionIDs = messages
                .suffix(max(0, initialUnreadCountSnapshot))
                .filter { $0.senderID != myID && $0.mentions.contains(myID) }
                .map(\.id)
        } else {
            unseenMentionIDs = []
        }
    }

    private func messageRowScrollID(for item: ThreadDisplayItem) -> String {
        switch item {
        case .bubble(let runItem):
            return runItem.message.id
        case .photoStack(_, let photos, _, _, _, _, _):
            return photos.last?.id ?? item.id
        default:
            return item.id
        }
    }

    private func scrollToBottom(using proxy: ScrollViewProxy, animated: Bool) {
        if animated && !reduceMotion {
            withAnimation(CuvenSprings.smooth) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }

    private func jumpAndFlashMessage(id targetID: String, using proxy: ScrollViewProxy) {
        withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
            proxy.scrollTo(targetID, anchor: .center)
            flashedMessageID = targetID
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            if flashedMessageID == targetID {
                withAnimation(.easeOut(duration: 0.25)) {
                    flashedMessageID = nil
                }
            }
        }
    }

    private func handleHeaderIdentityTapped() {
        CuvenHaptics.lightTap()
        if room?.kind == .dm, let peer = dmPeerUser {
            activePeerProfileUser = peer
            withAnimation(CuvenSprings.adaptive(CuvenSprings.sheetPresent, reduceMotion: reduceMotion)) {
                isPeerProfileModalPresented = true
            }
        } else {
            toggleArtifactMode(.roomInfo)
        }
    }

    private func toggleArtifactMode(_ mode: ArtifactMode) {
        if store.activeArtifactMode == mode && (store.activeColumnIndex == 3 || metrics.visibleColumnCount >= 2) {
            store.closeArtifact()
        } else {
            store.openArtifact(mode, for: roomID)
        }
    }

    private func presentExplainSheet(initialText: String, contextMessage: String) {
        let seed = initialText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !seed.isEmpty else { return }
        activeExplainRequest = ExplainSelectionRequest(
            initialText: seed,
            roomContext: contextMessage
        )
        withAnimation(CuvenSprings.adaptive(CuvenSprings.sheetPresent, reduceMotion: reduceMotion)) {
            isExplainModalPresented = true
        }
    }

    private func preferredExplainSeed(for message: Message) -> String {
        if let firstKeyword = message.highlightedKeywords.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return firstKeyword
        }
        let words = message.text
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        if let candidate = words.first(where: { $0.count >= 4 }) ?? words.first {
            return String(candidate.prefix(48))
        }
        return String(message.text.prefix(48))
    }
}

// MARK: - Private Presentation Value Types

private struct LiftedBubbleTarget: Equatable {
    let message: Message
    let isOutgoing: Bool
    let measuredSize: CGSize?
    let expandEditHistoryImmediately: Bool
}

private struct ThreadLightboxPresentation: Equatable {
    let urls: [String]
    let initialIndex: Int
}

private struct ExplainSelectionRequest: Equatable {
    let initialText: String
    let roomContext: String
}

private struct ConditionalHeaderGlassCircle: ViewModifier {
    let isEnabled: Bool
    let glassMode: GlassAppearanceMode

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .cuvenLiquidGlass(mode: glassMode, cornerRadius: 22, interactiveBounce: true)
        } else {
            content
        }
    }
}

import SwiftUI
import CuvenCore

// MARK: - Conversation Row with 1:1 Physics Swipe & Live Context Preview (`chatlist.row.<roomID>`)
//
// Grounding References:
// - Apple Human Interface Guidelines: Gestures & Designing Fluid Interfaces (1:1 finger tracking,
//   rubberband stretch, momentum velocity projection, full-swipe haptic snap, mid-flight catch,
//   40pt leading-edge pass-through for column swipe-back)
// - Apple Human Interface Guidelines: Context Menus (live room preview card + grouped actions)
// - Apple Human Interface Guidelines: Designing for iPhone Duo (gliding active-room selection
//   capsule in split mode; compact 66pt split height vs 76pt stack height)
// - Cuven Web Reference: `public/js/views/chatList.js:265-808`, `public/css/list.css:99-140, 224-239`

public struct ChatListRowView: View {
    private let store: AppStore
    private let room: Room
    private let metrics: DuoLayoutMetrics
    private let activeSelectionNamespace: Namespace.ID
    @Binding private var openSwipedRoomID: String?
    private let onDeleteRoom: (Room) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var rowWidth: CGFloat = 340
    @State private var swipeOffset: CGFloat = 0
    @State private var dragStartOffset: CGFloat?
    @State private var isGestureLockedHorizontal = false
    @State private var isGestureRejected = false
    @State private var crossedFullThreshold = false
    @State private var isCollapsingDelete = false
    @State private var velocityTracker = CuvenGestureVelocityTracker()

    public init(
        store: AppStore,
        room: Room,
        metrics: DuoLayoutMetrics,
        activeSelectionNamespace: Namespace.ID,
        openSwipedRoomID: Binding<String?>,
        onDeleteRoom: @escaping (Room) -> Void
    ) {
        self.store = store
        self.room = room
        self.metrics = metrics
        self.activeSelectionNamespace = activeSelectionNamespace
        self._openSwipedRoomID = openSwipedRoomID
        self.onDeleteRoom = onDeleteRoom
    }

    private var isSplitMode: Bool {
        metrics.visibleColumnCount == 2
    }

    private var isSelectedInSplit: Bool {
        isSplitMode && store.selectedRoomID == room.id
    }

    private var avatarSize: CGFloat {
        isSplitMode ? 44 : 48
    }

    private var minRowHeight: CGFloat {
        isSplitMode ? 66 : 76
    }

    private var effectiveUnreadCount: Int {
        max(room.unreadCount, room.isMarkedUnread ? 1 : 0)
    }

    private var hasUnread: Bool {
        effectiveUnreadCount > 0
    }

    private var isPeerOnline: Bool {
        guard room.kind == .dm, let peerID = room.peerUserID else { return false }
        return store.contacts.first(where: { $0.user.id == peerID })?.user.isOnline ?? false
    }

    private var liveTypingText: String? {
        guard let raw = store.typingPreviewByRoom[room.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private var activeDraftText: String? {
        guard store.selectedRoomID != room.id,
              let draft = store.draftsByRoom[room.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !draft.isEmpty else {
            return nil
        }
        return draft.replacingOccurrences(of: "\n", with: " ")
    }

    private var lastRoomMessage: Message? {
        store.messagesByRoom[room.id]?.last(where: { $0.deliveryState != .revoked })
    }

    private var hasUnreadMention: Bool {
        guard hasUnread, room.kind == .group, let me = store.currentUser else { return false }
        guard let messages = store.messagesByRoom[room.id] else { return false }
        return messages.suffix(8).contains { msg in
            msg.mentions.contains(me.id) || msg.mentions.contains(me.username)
        }
    }

    private var isTrailingFullSwipe: Bool {
        -swipeOffset > max(rowWidth, 240) * ChatListSwipeMath.fullSwipeRatio
    }

    private var isLeadingFullSwipe: Bool {
        swipeOffset > max(rowWidth, 240) * ChatListSwipeMath.fullSwipeRatio
    }

    public var body: some View {
        ZStack {
            // 1. Clipped Action Trays Behind Foreground Row (`list.css:129-136`)
            if swipeOffset < -0.5 {
                trailingDeleteTray
            } else if swipeOffset > 0.5 {
                leadingActionsTray
            }

            // 2. Foreground Interactive Row (`list.css:104-124`)
            foregroundRowContent
                .offset(x: swipeOffset)
                .gesture(horizontalSwipeGesture)
        }
        .clipShape(RoundedRectangle(cornerRadius: ChatListRadii.row, style: .continuous))
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { rowWidth = max(proxy.size.width, 240) }
                    .onChange(of: proxy.size.width) { _, newWidth in
                        rowWidth = max(newWidth, 240)
                    }
            }
        )
        .opacity(isCollapsingDelete ? 0 : 1)
        .frame(maxHeight: isCollapsingDelete ? 0 : .infinity)
        .clipped()
        .onChange(of: openSwipedRoomID) { _, activeID in
            if activeID != room.id && abs(swipeOffset) > 0.5 && dragStartOffset == nil {
                settleSwipe(to: 0)
            }
        }
        .contextMenu {
            Button {
                CuvenHaptics.lightTap()
                closeSwipeIfNeeded()
                store.toggleRoomUnread(room.id)
            } label: {
                Label(
                    hasUnread ? "Mark as Read" : "Mark as Unread",
                    systemImage: hasUnread ? "checkmark.message" : "envelope.badge"
                )
            }

            Button {
                CuvenHaptics.rigidImpact()
                closeSwipeIfNeeded()
                withAnimation(CuvenSprings.pressBounce) {
                    store.toggleRoomPin(room.id)
                }
            } label: {
                Label(
                    room.isPinned ? "Unpin" : "Pin",
                    systemImage: room.isPinned ? "pin.slash" : "pin"
                )
            }

            Button {
                CuvenHaptics.lightTap()
                closeSwipeIfNeeded()
                store.toggleRoomMute(room.id)
            } label: {
                Label(
                    room.isMuted ? "Unmute" : "Mute",
                    systemImage: room.isMuted ? "bell" : "bell.slash"
                )
            }

            Divider()

            Button(role: .destructive) {
                triggerDeleteCollapse()
            } label: {
                Label("Delete Conversation", systemImage: "trash")
            }
        } preview: {
            RoomContextPreviewCard(store: store, room: room)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Foreground Row Anatomy

    private var foregroundRowContent: some View {
        HStack(spacing: isSplitMode ? 11 : 12) {
            CuvenAvatarView(
                name: room.title,
                urlString: room.avatarURL,
                size: avatarSize,
                isOnline: isPeerOnline
            )

            VStack(alignment: .leading, spacing: 5) {
                // Top Row: Title + Pin/Mute Flags + Timestamp (`list.css:110-116`)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(room.title)
                        .font(CuvenFonts.cappedBody())
                        .fontWeight(.semibold)
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .lineLimit(1)

                    if room.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(ChatListPalette.tertiaryInk)
                            .accessibilityHidden(true)
                    }

                    if room.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(ChatListPalette.tertiaryInk)
                            .transition(.scale.combined(with: .opacity))
                            .accessibilityHidden(true)
                    }

                    Spacer(minLength: 4)

                    Text(
                        ChatListTimeFormatter.listTime(
                            from: room.lastMessageTimestamp,
                            use24Hour: store.prefs.use24HourTime
                        )
                    )
                    .font(CuvenFonts.cappedCaption().monospacedDigit())
                    .fontWeight(hasUnread ? .semibold : .regular)
                    .foregroundStyle(hasUnread ? ChatListPalette.unreadBadgeBackground : CuvenColors.inkSecondary)
                }

                // Bottom Row: Honk Live Typing / Draft / Mention / Message Preview + Unread Badge (`list.css:117-123`)
                HStack(alignment: .center, spacing: 8) {
                    previewSubtitleView
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if hasUnread {
                        if room.isMarkedUnread && room.unreadCount == 0 {
                            Circle()
                                .fill(room.isMuted ? ChatListPalette.tertiaryInk : ChatListPalette.messagesTitleBlue)
                                .frame(width: 10, height: 10)
                                .accessibilityIdentifier("chatlist.rowUnreadDot.\(room.id)")
                        } else {
                            Text(effectiveUnreadCount > 99 ? "99+" : "\(effectiveUnreadCount)")
                                .font(.system(size: 11, weight: .bold).monospacedDigit())
                                .foregroundStyle(room.isMuted ? CuvenColors.inkSecondary : ChatListPalette.unreadBadgeForeground)
                                .padding(.horizontal, 6)
                                .frame(minWidth: 19, minHeight: 19)
                                .background(
                                    Capsule()
                                        .fill(room.isMuted ? ChatListPalette.subtleChipFill : ChatListPalette.unreadBadgeBackground)
                                )
                                .accessibilityIdentifier("chatlist.rowUnreadBadge.\(room.id)")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, isSplitMode ? 11 : 13)
        .padding(.vertical, isSplitMode ? 10 : 12)
        .frame(minHeight: minRowHeight)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: ChatListRadii.row, style: .continuous)
                    .fill(CuvenColors.paperBackground)

                // Gliding split-mode active conversation capsule (`list.css:235-238`)
                if isSelectedInSplit && abs(swipeOffset) < 2 {
                    RoundedRectangle(cornerRadius: ChatListRadii.row, style: .continuous)
                        .fill(ChatListPalette.splitSelectionFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: ChatListRadii.row, style: .continuous)
                                .strokeBorder(CuvenColors.hairlineSeparator, lineWidth: 1)
                        )
                        .matchedGeometryEffect(
                            id: "chatlist.activeRowCapsule",
                            in: activeSelectionNamespace
                        )
                }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: ChatListRadii.row, style: .continuous))
        .onTapGesture {
            handleRowTap()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelectedInSplit ? [.isSelected] : [])
        .accessibilityAction(named: Text(hasUnread ? "Mark as Read" : "Mark as Unread")) {
            store.toggleRoomUnread(room.id)
        }
        .accessibilityAction(named: Text(room.isPinned ? "Unpin" : "Pin")) {
            store.toggleRoomPin(room.id)
        }
        .accessibilityAction(named: Text(room.isMuted ? "Unmute" : "Mute")) {
            store.toggleRoomMute(room.id)
        }
        .accessibilityAction(named: Text("Delete Conversation")) {
            triggerDeleteCollapse()
        }
        .accessibilityIdentifier("chatlist.row.\(room.id)")
    }

    @ViewBuilder
    private var previewSubtitleView: some View {
        if let liveTypingText {
            HStack(spacing: 6) {
                HonkTypingPulseDots()
                Text("typing… \(liveTypingText)")
                    .font(CuvenFonts.cappedCaption())
                    .fontWeight(.medium)
                    .foregroundStyle(ChatListPalette.accessibleBlueText)
                    .lineLimit(1)
            }
            .accessibilityIdentifier("chatlist.rowTyping.\(room.id)")
        } else if let draft = activeDraftText {
            (
                Text("[Draft] ")
                    .font(CuvenFonts.cappedCaption())
                    .fontWeight(.semibold)
                    .foregroundStyle(ChatListPalette.accessibleRedText)
                + Text(draft)
                    .font(CuvenFonts.cappedCaption())
                    .foregroundStyle(CuvenColors.inkSecondary)
            )
            .lineLimit(1)
        } else if hasUnreadMention {
            (
                Text("[Mentioned you] ")
                    .font(CuvenFonts.cappedCaption())
                    .fontWeight(.semibold)
                    .foregroundStyle(ChatListPalette.accessibleRedText)
                + Text(room.lastMessagePreview)
                    .font(CuvenFonts.cappedCaption())
                    .foregroundStyle(CuvenColors.inkPrimary)
            )
            .lineLimit(1)
        } else if lastRoomMessage?.deliveryState == .failed {
            (
                Text("[Not sent] ")
                    .font(CuvenFonts.cappedCaption())
                    .fontWeight(.semibold)
                    .foregroundStyle(ChatListPalette.accessibleRedText)
                + Text(room.lastMessagePreview)
                    .font(CuvenFonts.cappedCaption())
                    .foregroundStyle(CuvenColors.inkSecondary)
            )
            .lineLimit(1)
        } else if lastRoomMessage?.deliveryState == .sending || lastRoomMessage?.deliveryState == .queued {
            Text("Sending… \(room.lastMessagePreview)")
                .font(CuvenFonts.cappedCaption())
                .foregroundStyle(CuvenColors.inkSecondary)
                .lineLimit(1)
        } else {
            let fallbackText = room.lastMessagePreview.isEmpty
                ? (room.kind == .group ? "\(room.memberIDs.count) members" : room.subtitle)
                : room.lastMessagePreview
            Text(fallbackText)
                .font(CuvenFonts.cappedCaption())
                .fontWeight(hasUnread ? .medium : .regular)
                .foregroundStyle(hasUnread ? CuvenColors.inkPrimary : CuvenColors.inkSecondary)
                .lineLimit(1)
        }
    }

    // MARK: - Clipped Swipe Action Trays

    private var trailingDeleteTray: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)

            Button {
                triggerDeleteCollapse()
            } label: {
                VStack(spacing: 5) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .scaleEffect(isTrailingFullSwipe ? 1.18 : 1.0)
                        .animation(CuvenSprings.pressBounce, value: isTrailingFullSwipe)
                    Text("Delete")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(Color.white)
                .frame(width: max(ChatListSwipeMath.trailingDeleteRevealWidth, -swipeOffset))
                .frame(maxHeight: .infinity)
                .background(CuvenColors.dangerRed)
            }
            .buttonStyle(.plain)
            .frame(width: max(0, -swipeOffset))
            .clipped()
            .accessibilityLabel("Delete")
            .accessibilityIdentifier("chatlist.rowDeleteAction.\(room.id)")
        }
    }

    private var leadingActionsTray: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    CuvenHaptics.rigidImpact()
                    settleSwipe(to: 0)
                    withAnimation(CuvenSprings.pressBounce) {
                        store.toggleRoomPin(room.id)
                    }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: room.isPinned ? "pin.slash.fill" : "pin.fill")
                            .font(.system(size: 17, weight: .semibold))
                        Text(room.isPinned ? "Unpin" : "Pin")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ChatListPalette.facebookBlue)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(room.isPinned ? "Unpin" : "Pin")
                .accessibilityIdentifier("chatlist.rowPinAction.\(room.id)")

                Button {
                    CuvenHaptics.lightTap()
                    settleSwipe(to: 0)
                    store.toggleRoomUnread(room.id)
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: hasUnread ? "checkmark.message.fill" : "envelope.badge.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .scaleEffect(isLeadingFullSwipe ? 1.18 : 1.0)
                            .animation(CuvenSprings.pressBounce, value: isLeadingFullSwipe)
                        Text(hasUnread ? "Read" : "Unread")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(ChatListPalette.unreadBadgeForeground)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ChatListPalette.unreadBadgeBackground)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(hasUnread ? "Read" : "Unread")
                .accessibilityIdentifier("chatlist.rowUnreadAction.\(room.id)")
            }
            .frame(width: max(0, swipeOffset))
            .clipped()

            Spacer(minLength: 0)
        }
    }

    // MARK: - 1:1 Gesture Mechanics (`chatList.js:652-733`)

    private var horizontalSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onChanged { value in
                guard !isCollapsingDelete, !isGestureRejected else { return }

                if dragStartOffset == nil {
                    let dx = value.translation.width
                    let dy = value.translation.height

                    // Vertical scroll dominates: close any open swipe and reject horizontal tracking
                    if abs(dy) > abs(dx) {
                        if abs(swipeOffset) > 0.5 {
                            settleSwipe(to: 0)
                        }
                        isGestureRejected = true
                        return
                    }

                    // Preserve 40pt leading-edge swipe-back for `StripContainerView` (`strip.js`)
                    if abs(swipeOffset) < 1 && dx > 0 && value.startLocation.x <= 40 {
                        isGestureRejected = true
                        return
                    }

                    if openSwipedRoomID != nil && openSwipedRoomID != room.id {
                        openSwipedRoomID = room.id
                    }

                    dragStartOffset = swipeOffset
                    isGestureLockedHorizontal = true
                    velocityTracker.reset()
                    let fullThreshold = max(rowWidth, 240) * ChatListSwipeMath.fullSwipeRatio
                    crossedFullThreshold = abs(swipeOffset) > fullThreshold
                }

                guard isGestureLockedHorizontal, let baseOffset = dragStartOffset else { return }
                velocityTracker.addSample(value.location)
                let nextOffset = ChatListSwipeMath.interactiveOffset(
                    startOffset: baseOffset,
                    translationX: value.translation.width,
                    rowWidth: rowWidth
                )
                swipeOffset = nextOffset

                let fullThreshold = max(rowWidth, 240) * ChatListSwipeMath.fullSwipeRatio
                let isNowPastFull = abs(nextOffset) > fullThreshold
                if isNowPastFull != crossedFullThreshold {
                    crossedFullThreshold = isNowPastFull
                    CuvenHaptics.rigidImpact()
                }
            }
            .onEnded { value in
                defer {
                    dragStartOffset = nil
                    isGestureLockedHorizontal = false
                    isGestureRejected = false
                    crossedFullThreshold = false
                    velocityTracker.reset()
                }
                guard !isCollapsingDelete, isGestureLockedHorizontal else { return }

                let trackedVelocityX = velocityTracker.velocity().x
                let resolvedVelocityX = abs(trackedVelocityX) > 12 ? trackedVelocityX : value.velocity.width
                let outcome = ChatListSwipeMath.resolveRelease(
                    currentOffset: swipeOffset,
                    velocityX: resolvedVelocityX,
                    rowWidth: rowWidth
                )

                switch outcome {
                case .fullSwipeDelete:
                    triggerDeleteCollapse()

                case .openTrailingDelete:
                    openSwipedRoomID = room.id
                    settleSwipe(to: -ChatListSwipeMath.trailingDeleteRevealWidth)

                case .openLeadingActions:
                    openSwipedRoomID = room.id
                    settleSwipe(to: ChatListSwipeMath.leadingActionsRevealWidth)

                case .fullSwipeToggleUnread:
                    CuvenHaptics.success()
                    store.toggleRoomUnread(room.id)
                    settleSwipe(to: 0)

                case .closed:
                    settleSwipe(to: 0)
                }
            }
    }

    private func handleRowTap() {
        // Tapping an open swiped row closes it instead of navigating (`chatList.js:309-313`)
        if abs(swipeOffset) > 2 {
            settleSwipe(to: 0)
            return
        }
        if openSwipedRoomID != nil {
            openSwipedRoomID = nil
        }
        CuvenHaptics.selectionChanged()
        if reduceMotion {
            store.selectRoom(room.id)
        } else {
            withAnimation(CuvenSprings.railMorph) {
                store.selectRoom(room.id)
            }
        }
    }

    private func settleSwipe(to target: CGFloat) {
        if target == 0 && openSwipedRoomID == room.id {
            openSwipedRoomID = nil
        }
        if reduceMotion {
            swipeOffset = target
        } else {
            withAnimation(CuvenSprings.stripSlide) {
                swipeOffset = target
            }
        }
    }

    private func closeSwipeIfNeeded() {
        if abs(swipeOffset) > 0.5 {
            settleSwipe(to: 0)
        }
    }

    private func triggerDeleteCollapse() {
        guard !isCollapsingDelete else { return }
        CuvenHaptics.rigidImpact()
        if openSwipedRoomID == room.id {
            openSwipedRoomID = nil
        }
        if reduceMotion {
            swipeOffset = 0
            onDeleteRoom(room)
        } else {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.92)) {
                swipeOffset = -max(rowWidth, 320)
                isCollapsingDelete = true
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(220))
                onDeleteRoom(room)
                isCollapsingDelete = false
                swipeOffset = 0
            }
        }
    }

    private var accessibilitySummary: String {
        var parts: [String] = [room.title]
        if isPeerOnline { parts.append("Online") }
        if hasUnread { parts.append("\(effectiveUnreadCount) unread") }
        if hasUnreadMention { parts.append("Mentioned you") }
        if let typing = liveTypingText {
            parts.append("typing \(typing)")
        } else if !room.lastMessagePreview.isEmpty {
            parts.append(room.lastMessagePreview)
        }
        let time = ChatListTimeFormatter.listTime(
            from: room.lastMessageTimestamp,
            use24Hour: store.prefs.use24HourTime
        )
        if !time.isEmpty { parts.append(time) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Animated Honk Live Typing Pulse Indicator

private struct HonkTypingPulseDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseOn = false

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(ChatListPalette.accessibleBlueText)
                    .frame(width: 4.5, height: 4.5)
                    .scaleEffect(pulseOn ? 1.15 : 0.65)
                    .opacity(pulseOn ? 1.0 : 0.4)
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 0.52)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.14),
                        value: pulseOn
                    )
            }
        }
        .onAppear {
            pulseOn = true
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Blurred Context Menu Live Room Preview Card (`UIContextMenuInteraction` / SwiftUI `.contextMenu(..., preview:)`)

struct RoomContextPreviewCard: View {
    let store: AppStore
    let room: Room

    private var recentMessages: [Message] {
        Array((store.messagesByRoom[room.id] ?? []).filter { $0.deliveryState != .revoked }.suffix(4))
    }

    private var isPeerOnline: Bool {
        guard room.kind == .dm, let peerID = room.peerUserID else { return false }
        return store.contacts.first(where: { $0.user.id == peerID })?.user.isOnline ?? false
    }

    private var liveTyping: String? {
        guard let t = store.typingPreviewByRoom[room.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty else {
            return nil
        }
        return t
    }

    var body: some View {
        ZStack {
            if let backdrop = room.backdrop {
                CuvenBackdropView(preset: backdrop, customImageURL: nil)
                    .opacity(0.45)
            } else {
                CuvenColors.paperBackground
            }

            VStack(alignment: .leading, spacing: 12) {
                // Header pill
                HStack(spacing: 10) {
                    CuvenAvatarView(
                        name: room.title,
                        urlString: room.avatarURL,
                        size: 38,
                        isOnline: isPeerOnline
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(room.title)
                                .font(CuvenFonts.cappedBody())
                                .fontWeight(.semibold)
                                .foregroundStyle(CuvenColors.inkPrimary)
                                .lineLimit(1)
                            if room.isMuted {
                                Image(systemName: "bell.slash.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(ChatListPalette.tertiaryInk)
                            }
                        }

                        Text(
                            isPeerOnline
                                ? "Online"
                                : (room.kind == .group ? "\(room.memberIDs.count) members" : (room.subtitle.isEmpty ? "Direct message" : room.subtitle))
                        )
                        .font(CuvenFonts.cappedCaption())
                        .foregroundStyle(isPeerOnline ? CuvenColors.onlineGreen : CuvenColors.inkSecondary)
                        .lineLimit(1)
                    }

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(CuvenColors.elevatedSurface.opacity(0.92))
                )

                Spacer(minLength: 4)

                // Mini live message transcript
                VStack(alignment: .leading, spacing: 7) {
                    if recentMessages.isEmpty {
                        if !room.lastMessagePreview.isEmpty {
                            HStack {
                                Text(room.lastMessagePreview)
                                    .font(CuvenFonts.cappedCaption())
                                    .foregroundStyle(CuvenColors.incomingBubbleText)
                                    .lineLimit(3)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .fill(CuvenColors.incomingBubble)
                                    )
                                Spacer(minLength: 36)
                            }
                        } else {
                            Text("No messages yet — tap to start chatting.")
                                .font(CuvenFonts.cappedCaption())
                                .foregroundStyle(CuvenColors.inkSecondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 20)
                        }
                    } else {
                        ForEach(recentMessages) { msg in
                            let isOutgoing = msg.senderID == store.currentUser?.id
                            HStack {
                                if isOutgoing { Spacer(minLength: 42) }

                                Text(previewBubbleText(for: msg))
                                    .font(CuvenFonts.cappedCaption())
                                    .foregroundStyle(isOutgoing ? CuvenColors.outgoingBubbleText : CuvenColors.incomingBubbleText)
                                    .lineLimit(2)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7.5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .fill(isOutgoing ? CuvenColors.outgoingBubble : CuvenColors.incomingBubble)
                                    )

                                if !isOutgoing { Spacer(minLength: 42) }
                            }
                        }
                    }

                    // Live Honk typing preview bubble inside context preview!
                    if let liveTyping {
                        HStack(spacing: 6) {
                            HonkTypingPulseDots()
                            Text(liveTyping)
                                .font(CuvenFonts.cappedCaption())
                                .foregroundStyle(CuvenColors.inkSecondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(ChatListPalette.accessibleBlueText.opacity(0.45), lineWidth: 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(CuvenColors.incomingBubble.opacity(0.75))
                                )
                        )
                    }
                }

                // Smart Insight footer chip if available
                if let insight = store.insightsByRoom[room.id] {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ChatListPalette.messagesTitleBlue)
                        Text(insight.summary)
                            .font(CuvenFonts.cappedCaption())
                            .foregroundStyle(CuvenColors.inkSecondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(CuvenColors.elevatedSurface.opacity(0.9))
                    )
                }
            }
            .padding(14)
        }
        .frame(width: 316, height: 332)
        .clipShape(RoundedRectangle(cornerRadius: ChatListRadii.contextPreview, style: .continuous))
    }

    private func previewBubbleText(for message: Message) -> String {
        switch message.kind {
        case .text:
            return message.text
        case .image:
            return message.text.isEmpty ? "📷 Photo" : "📷 \(message.text)"
        case .drawing:
            return "🎨 Drawing"
        case .sticker:
            return "✨ Sticker"
        case .voice:
            return "🎙️ Voice message"
        case .video:
            return "🎬 Video"
        case .file:
            return "📎 File"
        case .call:
            return "📞 Call"
        case .system:
            return message.text
        }
    }
}

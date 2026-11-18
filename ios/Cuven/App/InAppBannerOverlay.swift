//
//  InAppBannerOverlay.swift
//  Cuven
//
//  Apple HIG & iOS 27.2 SDK Grounding:
//  - Human Interface Guidelines › Notifications & Managing notifications (non-intrusive drop-in banner
//    for background conversations, tap to jump, pull down for inline reply, flick up to dismiss)
//  - Human Interface Guidelines › Designing for iPhone Duo (iOS 27.2 SDK: centered clear of Duo's
//    right-edge status/rail column on `duoClosed`/`duoOpen`, and confined to the active half-pane on
//    `duoHalfBook` so banners never straddle the physical fold crease)
//  - Cuven Web Parity: `public/js/views/banner.js:1-215`, `public/css/banner.css:1-141`
//

import CuvenCore
import SwiftUI

/// Interactive top Liquid Glass notification banner (`banner.js` parity) for newly arriving messages
/// in conversations that are not currently visible on screen.
///
/// Gestures:
/// - **Tap**: Dismisses the banner and navigates directly to the conversation.
/// - **Pull down (`> 44pt` or `vy > 450 pt/s`)**: Expands an inline quick-reply field (`"Reply to …"`)
///   with circular `#1877F2` send button and checkmark confirmation.
/// - **Flick up (`dy < -28pt` or `vy < -450 pt/s`)**: Dismisses upward at gesture velocity.
public struct InAppBannerOverlay: View {
    private let store: AppStore
    public let metrics: DuoLayoutMetrics

    public struct BannerPayload: Identifiable, Equatable, Sendable {
        public let id: String
        public let roomID: String
        public let title: String
        public let avatarURL: String?
        public let isGroup: Bool
        public let bodyText: String
    }

    /// Thresholds matching `public/js/views/banner.js:14-18`.
    private static let pullExpandThreshold: CGFloat = 44
    private static let flickDismissOffset: CGFloat = 28
    private static let flickVelocityThreshold: CGFloat = 450
    private static let autoDismissNanoseconds: UInt64 = 2_600_000_000

    @State private var hasSeededBaseline: Bool = false
    @State private var seenMessageIDByRoom: [String: String] = [:]
    @State private var activeBanner: BannerPayload?
    @State private var isExpandedForReply: Bool = false
    @State private var replyDraft: String = ""
    @State private var didSendReplyCheckmark: Bool = false
    @State private var dragOffsetY: CGFloat = 0
    @State private var isDraggingBanner: Bool = false
    @State private var autoDismissToken: UUID = UUID()
    @State private var velocityTracker = CuvenGestureVelocityTracker()

    @FocusState private var isReplyFieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    public init(store: AppStore, metrics: DuoLayoutMetrics) {
        self.store = store
        self.metrics = metrics
    }

    /// Room currently being read on screen (`shell.js:72` `state.open`).
    private var currentlyVisibleThreadRoomID: String? {
        guard store.activePage == .chats else { return nil }
        if metrics.visibleColumnCount >= 2 {
            // In 2-column split, Thread (Column 2) is visible when windowStart >= 1 (`List|Thread` or `Thread|Artifact`)
            let start = StripContainerView.windowStart(
                focus: store.activeColumnIndex,
                visibleCount: metrics.visibleColumnCount
            )
            return start >= 1 ? store.selectedRoomID : nil
        } else {
            return store.activeColumnIndex >= 2 ? store.selectedRoomID : nil
        }
    }

    /// Computes horizontal bounds clear of Duo's right-edge system column and `duoHalfBook` crease (`banner.css:8-21`).
    private var bannerHorizontalPlacement: (leadingPadding: CGFloat, trailingPadding: CGFloat, maxCardWidth: CGFloat) {
        if metrics.posture == .duoHalfBook, let div = metrics.hingeDivisionRect {
            // Keep banner on the leading pane clear of the book crease
            let leadingW = max(240, div.minX)
            let trailingReserve = max(0, metrics.viewportSize.width - leadingW)
            return (
                leadingPadding: metrics.safeAreaLeft + 12,
                trailingPadding: trailingReserve + 12,
                maxCardWidth: min(420, leadingW - metrics.safeAreaLeft - 24)
            )
        }

        let rightReserve = metrics.hasRightSystemColumn
            ? max(metrics.safeAreaRight, metrics.railWidth + 24)
            : metrics.safeAreaRight
        let usableWidth = max(240, metrics.viewportSize.width - metrics.safeAreaLeft - rightReserve)
        return (
            leadingPadding: metrics.safeAreaLeft + 12,
            trailingPadding: rightReserve + 12,
            maxCardWidth: min(420, usableWidth - 24)
        )
    }

    private var newestMessageDigest: [String: String] {
        var map: [String: String] = [:]
        for room in store.rooms {
            if let lastID = store.messagesByRoom[room.id]?.last?.id {
                map[room.id] = lastID
            } else if !room.lastMessagePreview.isEmpty {
                map[room.id] = "\(room.lastMessageTimestamp):\(room.lastMessagePreview)"
            }
        }
        return map
    }

    public var body: some View {
        let placement = bannerHorizontalPlacement

        ZStack(alignment: .top) {
            if let banner = activeBanner {
                bannerCard(for: banner)
                    .frame(maxWidth: placement.maxCardWidth)
                    .padding(.leading, placement.leadingPadding)
                    .padding(.trailing, placement.trailingPadding)
                    .padding(.top, max(metrics.safeAreaTop, 8) + 8)
                    .offset(y: dragOffsetY)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .move(edge: .top).combined(with: .opacity)
                            )
                    )
            }
        }
        .frame(
            width: metrics.viewportSize.width,
            height: metrics.viewportSize.height,
            alignment: .top
        )
        .allowsHitTesting(activeBanner != nil)
        .onAppear {
            seedBaselineMessagesIfNeeded()
        }
        .onChange(of: store.isBootstrapping) { wasBootstrapping, isNowBootstrapping in
            if wasBootstrapping && !isNowBootstrapping {
                seenMessageIDByRoom = newestMessageDigest
                hasSeededBaseline = true
            }
        }
        .onChange(of: newestMessageDigest) { _, updatedDigest in
            evaluateIncomingMessages(updatedDigest: updatedDigest)
        }
        .onChange(of: currentlyVisibleThreadRoomID) { _, openedRoomID in
            if let openedRoomID, activeBanner?.roomID == openedRoomID {
                dismissBanner()
            }
        }
        .task(id: autoDismissToken) {
            guard activeBanner != nil, !isExpandedForReply, !isDraggingBanner else { return }
            try? await Task.sleep(nanoseconds: Self.autoDismissNanoseconds)
            guard !Task.isCancelled else { return }
            if !isExpandedForReply && !isDraggingBanner && !isReplyFieldFocused {
                dismissBanner()
            }
        }
    }

    // MARK: - Banner Card UI (`banner.css:31-126`)

    @ViewBuilder
    private func bannerCard(for banner: BannerPayload) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard !isDraggingBanner else { return }
                let targetRoomID = banner.roomID
                CuvenHaptics.lightTap()
                dismissBanner()
                store.navigateToPage(.chats)
                store.selectRoom(targetRoomID)
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    CuvenAvatarView(
                        name: banner.title,
                        urlString: banner.avatarURL,
                        size: 40,
                        isOnline: false,
                        isGroupSquircle: banner.isGroup
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(banner.title)
                                .font(CuvenFonts.cappedSubheadline(weight: .semibold))
                                .foregroundStyle(CuvenColors.inkPrimary)
                                .lineLimit(1)

                            Spacer(minLength: 4)

                            Text("now")
                                .font(CuvenFonts.cappedCaption())
                                .foregroundStyle(CuvenColors.inkSecondary)
                        }

                        Text(banner.bodyText)
                            .font(CuvenFonts.cappedSubheadline())
                            .foregroundStyle(CuvenColors.inkPrimary)
                            .lineLimit(isExpandedForReply ? 6 : 2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("shell.inAppBanner.main")
            .accessibilityLabel("\(banner.title): \(banner.bodyText). Open chat")

            if isExpandedForReply {
                inlineReplyRow(for: banner)
                    .padding(.top, 12)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .move(edge: .top))
                    )
            } else {
                HStack {
                    Spacer()
                    Capsule(style: .continuous)
                        .fill(CuvenColors.inkTertiary.opacity(0.75))
                        .frame(width: 36, height: 4)
                    Spacer()
                }
                .padding(.top, 8)
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, isExpandedForReply ? 12 : 8)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    colorScheme == .dark
                        ? Color(red: 38 / 255, green: 38 / 255, blue: 42 / 255).opacity(0.86)
                        : Color(red: 250 / 255, green: 250 / 255, blue: 252 / 255).opacity(0.88)
                )
        }
        .cuvenLiquidGlass(
            mode: store.prefs.glassMode,
            cornerRadius: 24,
            interactiveBounce: false
        )
        .gesture(bannerVerticalDragGesture)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shell.inAppBanner")
    }

    @ViewBuilder
    private func inlineReplyRow(for banner: BannerPayload) -> some View {
        let trimmedReply = replyDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        HStack(spacing: 8) {
            TextField("Reply to \(banner.title)", text: $replyDraft)
                .font(CuvenFonts.cappedBody())
                .foregroundStyle(CuvenColors.inkPrimary)
                .focused($isReplyFieldFocused)
                .submitLabel(.send)
                .disabled(didSendReplyCheckmark)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(
                    CuvenColors.elevatedSurface,
                    in: Capsule(style: .continuous)
                )
                .onSubmit {
                    submitInlineReply(for: banner)
                }
                .accessibilityIdentifier("shell.inAppBanner.replyField")

            Button {
                submitInlineReply(for: banner)
            } label: {
                Image(systemName: didSendReplyCheckmark ? "checkmark" : "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle()
                            .fill(didSendReplyCheckmark ? CuvenColors.onlineGreen : CuvenColors.sidebarBlue)
                    )
                    .opacity((trimmedReply.isEmpty && !didSendReplyCheckmark) ? 0.35 : 1.0)
            }
            .buttonStyle(.plain)
            .disabled(trimmedReply.isEmpty || didSendReplyCheckmark)
            .accessibilityIdentifier("shell.inAppBanner.sendButton")
            .accessibilityLabel(didSendReplyCheckmark ? "Sent" : "Send reply")
        }
    }

    // MARK: - Banner Gesture Physics (`banner.js:118-168`)

    private var bannerVerticalDragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if !isDraggingBanner {
                    isDraggingBanner = true
                    velocityTracker.reset()
                }
                velocityTracker.addSample(value.location)
                let dy = value.translation.height
                if dy < 0 {
                    dragOffsetY = dy
                } else {
                    dragOffsetY = CuvenSprings.rubberBand(overshoot: dy, dimension: 160)
                    if dy > Self.pullExpandThreshold && !isExpandedForReply {
                        expandReplyComposer()
                    }
                }
            }
            .onEnded { value in
                isDraggingBanner = false
                let dy = value.translation.height
                let vy = velocityTracker.velocity().y
                velocityTracker.reset()

                if dy < -Self.flickDismissOffset || vy < -Self.flickVelocityThreshold {
                    dismissBanner()
                    return
                }
                if !isExpandedForReply && (dy > Self.pullExpandThreshold || vy > Self.flickVelocityThreshold) {
                    expandReplyComposer()
                }
                withAnimation(CuvenSprings.adaptive(CuvenSprings.pressBounce, reduceMotion: reduceMotion)) {
                    dragOffsetY = 0
                }
                rearmAutoDismissTimer()
            }
    }

    // MARK: - Message Arrival & Reply Actions

    private func seedBaselineMessagesIfNeeded() {
        guard !hasSeededBaseline else { return }
        seenMessageIDByRoom = newestMessageDigest
        hasSeededBaseline = true
    }

    private func evaluateIncomingMessages(updatedDigest: [String: String]) {
        guard hasSeededBaseline, !store.isBootstrapping else {
            seenMessageIDByRoom = updatedDigest
            return
        }

        let previous = seenMessageIDByRoom
        seenMessageIDByRoom = updatedDigest
        let myID = store.currentUser?.id

        for room in store.rooms where !room.isHidden && !room.isMuted {
            guard let latestKey = updatedDigest[room.id],
                  previous[room.id] != latestKey else {
                continue
            }

            // Never interrupt the conversation already open on screen (`banner.js:6`)
            guard room.id != currentlyVisibleThreadRoomID else {
                continue
            }

            guard let latestMsg = store.messagesByRoom[room.id]?.last,
                  latestMsg.senderID != myID,
                  latestMsg.deliveryState != .revoked else {
                continue
            }

            let preview = bannerPreviewText(for: latestMsg)
            guard !preview.isEmpty else { continue }

            let payload = BannerPayload(
                id: latestMsg.id,
                roomID: room.id,
                title: room.kind == .group ? "\(room.title) · \(latestMsg.senderDisplay)" : room.title,
                avatarURL: room.avatarURL,
                isGroup: room.kind == .group,
                bodyText: preview
            )

            // If user is mid-reply on another room's banner, don't sweep their draft away (`banner.js:34-37`)
            if isExpandedForReply, let current = activeBanner, current.roomID != room.id {
                return
            }

            presentBanner(payload)
            return
        }
    }

    private func bannerPreviewText(for message: Message) -> String {
        switch message.kind {
        case .text:
            return message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .image:
            return message.mediaURLs.count > 1 ? "Sent \(message.mediaURLs.count) photos" : "Sent a photo"
        case .drawing:
            return "Sent a drawing"
        case .sticker:
            return "Sent a sticker"
        case .voice:
            return "Sent a voice message"
        case .video:
            return "Sent a video"
        case .file:
            return "Sent a file"
        case .call:
            return message.text.isEmpty ? "Call update" : message.text
        case .system:
            return ""
        }
    }

    private func presentBanner(_ payload: BannerPayload) {
        withAnimation(CuvenSprings.adaptive(CuvenSprings.gentle, reduceMotion: reduceMotion)) {
            activeBanner = payload
            dragOffsetY = 0
            if !isExpandedForReply {
                replyDraft = ""
                didSendReplyCheckmark = false
            }
        }
        rearmAutoDismissTimer()
    }

    private func expandReplyComposer() {
        guard !isExpandedForReply else { return }
        CuvenHaptics.lightTap()
        withAnimation(CuvenSprings.adaptive(CuvenSprings.pressBounce, reduceMotion: reduceMotion)) {
            isExpandedForReply = true
        }
        isReplyFieldFocused = true
    }

    private func submitInlineReply(for banner: BannerPayload) {
        let trimmed = replyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !didSendReplyCheckmark else { return }
        didSendReplyCheckmark = true
        isReplyFieldFocused = false
        CuvenHaptics.success()

        Task {
            await store.sendText(trimmed, in: banner.roomID)
            let delayNs: UInt64 = reduceMotion ? 280_000_000 : 620_000_000
            try? await Task.sleep(nanoseconds: delayNs)
            dismissBanner()
        }
    }

    private func dismissBanner() {
        isReplyFieldFocused = false
        withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
            activeBanner = nil
            isExpandedForReply = false
            replyDraft = ""
            didSendReplyCheckmark = false
            dragOffsetY = 0
        }
    }

    private func rearmAutoDismissTimer() {
        autoDismissToken = UUID()
    }
}

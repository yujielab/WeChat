import SwiftUI
import UIKit
import CuvenCore

// MARK: - Lifted Bubble Tapback & Action Context Menu (`thread.js:1845-1970` + Apple HIG Context Menus)

public struct LiftedBubbleContextMenu: View {
    public static let canonicalReactions: [(emoji: String, label: String)] = [
        ("❤️", "Love"),
        ("😂", "Laugh"),
        ("👍", "Like"),
        ("😮", "Wow"),
        ("😢", "Sad"),
        ("🙏", "Thanks")
    ]

    public let message: Message
    public let isOutgoing: Bool
    public let measuredBubbleSize: CGSize?
    public let serverBaseURL: URL
    public let currentUserID: String?
    public let glassMode: GlassAppearanceMode
    public let use24HourTime: Bool
    public let smartAssistEnabled: Bool
    public var startWithHistoryExpanded: Bool

    public let onSelectReaction: (String) -> Void
    public let onReply: () -> Void
    public let onCopy: () -> Void
    public let onExplainWithAI: () -> Void
    public let onEdit: () -> Void
    public let onUnsend: () -> Void
    public let onDismiss: () -> Void

    @State private var appeared: Bool = false
    @State private var interactionArmed: Bool = false
    @State private var showEditHistory: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        message: Message,
        isOutgoing: Bool,
        measuredBubbleSize: CGSize? = nil,
        serverBaseURL: URL = URL(string: "https://wechat.cuven.us")!,
        currentUserID: String?,
        glassMode: GlassAppearanceMode = .clear,
        use24HourTime: Bool = true,
        smartAssistEnabled: Bool = true,
        startWithHistoryExpanded: Bool = false,
        onSelectReaction: @escaping (String) -> Void,
        onReply: @escaping () -> Void,
        onCopy: @escaping () -> Void,
        onExplainWithAI: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onUnsend: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.message = message
        self.isOutgoing = isOutgoing
        self.measuredBubbleSize = measuredBubbleSize
        self.serverBaseURL = serverBaseURL
        self.currentUserID = currentUserID
        self.glassMode = glassMode
        self.use24HourTime = use24HourTime
        self.smartAssistEnabled = smartAssistEnabled
        self.startWithHistoryExpanded = startWithHistoryExpanded
        self.onSelectReaction = onSelectReaction
        self.onReply = onReply
        self.onCopy = onCopy
        self.onExplainWithAI = onExplainWithAI
        self.onEdit = onEdit
        self.onUnsend = onUnsend
        self.onDismiss = onDismiss
    }

    private var currentUsersEmoji: String? {
        guard let currentUserID else { return nil }
        return message.reactions.first(where: { $0.userID == currentUserID })?.emoji
    }

    private var editEligibility: MessageEditEligibility {
        MessageEditRules.eligibility(for: message, currentUserID: currentUserID)
    }

    private var hasEditHistory: Bool {
        message.editCount > 0 || !message.editHistory.isEmpty
    }

    public var body: some View {
        ZStack {
            // Scrim over ConversationColumnView's 26pt Gaussian-blurred thread backdrop (`ctx-backdrop`)
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(CuvenColors.overlayScrim)
                .ignoresSafeArea()
                .opacity(appeared ? 1.0 : 0.0)
                .allowsHitTesting(interactionArmed)
                .onTapGesture {
                    guard interactionArmed else { return }
                    dismissWithSpring()
                }
                .accessibilityLabel("Dismiss message actions")
                .accessibilityAddTraits(.isButton)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 0) {
                    // Full sent + edited timestamp (`ctx-time`, 8pt above tapback bar per `thread.js:1930`)
                    Text(
                        ThreadTimeFormatter.fullContextTimestamp(
                            from: message.createdAt,
                            editHistory: message.editHistory,
                            editCount: message.editCount,
                            use24Hour: use24HourTime
                        )
                    )
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(CuvenColors.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .opacity(appeared ? 1 : 0)
                    .padding(.bottom, 8)

                    // 6 Floating Liquid Glass Emoji Tapback Beads (`❤️ 😂 👍 😮 😢 🙏`) — 8pt above bubble (`RAISE = 8`)
                    tapbackBeadsBar
                        .allowsHitTesting(interactionArmed)
                        .padding(.bottom, 8)

                    // Lifted Bubble Preview locked to exact 1:1 laid-out dimensions (zero text reflow!)
                    liftedBubblePreview
                        .scaleEffect(appeared ? (reduceMotion ? 1.0 : 1.02) : 0.98, anchor: isOutgoing ? .bottomTrailing : .bottomLeading)
                        .shadow(color: Color.black.opacity(0.24), radius: 20, x: 0, y: 10)
                        .allowsHitTesting(false)
                        .padding(.bottom, 12)

                    // Context Menu Action Card + Expandable Edit History Viewer — 12pt below bubble (`GAP = 12`)
                    actionMenuCard
                        .allowsHitTesting(interactionArmed)
                        .scaleEffect(appeared ? 1.0 : 0.92, anchor: isOutgoing ? .topTrailing : .topLeading)
                        .opacity(appeared ? 1.0 : 0.0)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 56)
                .frame(maxWidth: 525)
                .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
            }
        }
        .onAppear {
            showEditHistory = startWithHistoryExpanded
            interactionArmed = false
            withAnimation(reduceMotion ? .easeOut(duration: 0.14) : CuvenSprings.bubblePop) {
                appeared = true
            }
        }
        .task {
            // Prevent initial finger release after 460ms long-press from ever auto-selecting a bead or action!
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            interactionArmed = true
        }
    }

    // MARK: - 6 Staggered Liquid Glass Tapback Beads

    private var tapbackBeadsBar: some View {
        CuvenGlassGroup(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Array(Self.canonicalReactions.enumerated()), id: \.element.emoji) { idx, entry in
                    let isSelected = currentUsersEmoji == entry.emoji
                    Button {
                        guard interactionArmed else { return }
                        CuvenHaptics.selectionChanged()
                        onSelectReaction(entry.emoji)
                        dismissWithSpring()
                    } label: {
                        Text(entry.emoji)
                            .font(.system(size: 24))
                            .frame(width: 44, height: 44)
                            .background {
                                if isSelected {
                                    Circle()
                                        .fill(CuvenColors.sidebarBlue.opacity(0.22))
                                }
                            }
                            .overlay {
                                if isSelected {
                                    Circle()
                                        .strokeBorder(CuvenColors.sidebarBlue, lineWidth: 1.75)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .scaleEffect(appeared ? 1.0 : 0.35)
                    .opacity(appeared ? 1.0 : 0.0)
                    .animation(
                        reduceMotion
                            ? .easeOut(duration: 0.12)
                            : CuvenSprings.bubblePop.delay(Double(idx) * 0.018),
                        value: appeared
                    )
                    .accessibilityLabel("\(entry.label) reaction")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .cuvenLiquidGlass(mode: glassMode, cornerRadius: 28, interactiveBounce: true)
        }
    }

    // MARK: - 1:1 Exact-Dimension Lifted Bubble Snapshot (`thread.js:1852-1864`)

    @ViewBuilder
    private var liftedBubblePreview: some View {
        let lockedSize: CGSize? = {
            guard let s = measuredBubbleSize, s.width > 16, s.height > 16 else { return nil }
            return CGSize(width: ceil(s.width), height: min(ceil(s.height), 340))
        }()

        switch message.kind {
        case .text:
            if ThreadGroupingEngine.isJumboEmojiOnly(message.text) && message.replyToMessageID == nil {
                Text(message.text)
                    .font(.system(size: 44))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .modifier(ExactLiftedFrameModifier(lockedSize: lockedSize, isOutgoing: isOutgoing))
            } else {
                Text(message.text)
                    .font(CuvenFonts.cappedBody())
                    .foregroundStyle(isOutgoing ? ThreadSurfaceTokens.outgoingForeground : ThreadSurfaceTokens.incomingForeground)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 10)
                    .padding(.bottom, 11)
                    .padding(.horizontal, 15)
                    .modifier(ExactLiftedFrameModifier(lockedSize: lockedSize, isOutgoing: isOutgoing))
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(isOutgoing ? ThreadSurfaceTokens.outgoingFill : ThreadSurfaceTokens.incomingFill)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }

        case .image, .drawing, .video:
            let firstURL = message.mediaURLs.first ?? ""
            let fallbackSize = lockedSize ?? CGSize(width: 220, height: 170)
            ThreadMediaImageView(
                urlString: firstURL,
                serverBaseURL: serverBaseURL,
                contentMode: message.kind == .drawing ? .fit : .fill,
                isDrawing: message.kind == .drawing
            )
            .frame(width: fallbackSize.width, height: fallbackSize.height)
            .background(message.kind == .drawing ? Color.white : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(CuvenColors.hairlineSeparator, lineWidth: 0.75)
            )

        case .sticker:
            if let stickerID = message.stickerID, !stickerID.isEmpty,
               let stickerSet = message.stickerSet, !stickerSet.isEmpty {
                AnimatedStickerRenderer(
                    stickerID: stickerID,
                    setName: stickerSet,
                    emoji: message.text.isEmpty ? "✨" : message.text,
                    format: message.stickerFormat ?? .staticWebP,
                    size: lockedSize?.width ?? 124,
                    serverBaseURL: serverBaseURL
                )
            } else {
                Text(message.text.isEmpty ? "✨" : message.text)
                    .font(.system(size: 64))
                    .frame(width: lockedSize?.width ?? 112, height: lockedSize?.height ?? 112)
            }

        case .voice, .file, .call, .system:
            Text(ThreadGroupingEngine.quotePreviewText(for: message))
                .font(CuvenFonts.cappedBody())
                .foregroundStyle(isOutgoing ? ThreadSurfaceTokens.outgoingForeground : ThreadSurfaceTokens.incomingForeground)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .modifier(ExactLiftedFrameModifier(lockedSize: lockedSize, isOutgoing: isOutgoing))
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(isOutgoing ? ThreadSurfaceTokens.outgoingFill : ThreadSurfaceTokens.incomingFill)
                )
        }
    }

    // MARK: - Action Menu Card & Inline Edit History

    private var actionMenuCard: some View {
        VStack(spacing: 0) {
            menuActionRow(title: "Reply", systemImage: "arrowshape.turn.up.left") {
                CuvenHaptics.lightTap()
                onReply()
                dismissWithSpring()
            }

            if !message.text.isEmpty {
                Divider().overlay(CuvenColors.hairlineSeparator)
                menuActionRow(title: "Copy", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = message.text
                    CuvenHaptics.success()
                    onCopy()
                    dismissWithSpring()
                }
            }

            if message.kind == .text && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && smartAssistEnabled {
                Divider().overlay(CuvenColors.hairlineSeparator)
                menuActionRow(title: "Explain with AI", systemImage: "sparkles", tint: CuvenColors.sidebarBlue) {
                    CuvenHaptics.selectionChanged()
                    onExplainWithAI()
                }
            }

            // Edit governance: 15-minute window & 5-edit ceiling
            switch editEligibility {
            case .editable(let remaining):
                Divider().overlay(CuvenColors.hairlineSeparator)
                menuActionRow(
                    title: message.editCount > 0 ? "Edit (\(remaining) left)" : "Edit",
                    systemImage: "pencil"
                ) {
                    CuvenHaptics.lightTap()
                    onEdit()
                    dismissWithSpring()
                }
            case .limitReached:
                Divider().overlay(CuvenColors.hairlineSeparator)
                disabledGovernanceRow(title: "Edit limit reached (5/5)", systemImage: "pencil.slash")
            case .windowExpired:
                Divider().overlay(CuvenColors.hairlineSeparator)
                disabledGovernanceRow(title: "Edit window ended (15m)", systemImage: "clock.badge.exclamationmark")
            case .notApplicable:
                EmptyView()
            }

            // Expandable Edit History Viewer (`thread.js:2122-2133`)
            if hasEditHistory {
                Divider().overlay(CuvenColors.hairlineSeparator)
                Button {
                    CuvenHaptics.lightTap()
                    withAnimation(reduceMotion ? .easeOut(duration: 0.15) : CuvenSprings.sheetPresent) {
                        showEditHistory.toggle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        Text("Edit History (\(message.editCount))")
                            .font(CuvenFonts.cappedCallout(weight: .medium))
                            .foregroundStyle(CuvenColors.inkPrimary)
                        Spacer()
                        Image(systemName: showEditHistory ? "chevron.up" : "clock.arrow.circlepath")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(CuvenColors.accessibleBlueText)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showEditHistory {
                    editHistoryTimelineView
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            if MessageEditRules.canUnsend(message: message, currentUserID: currentUserID) {
                Divider().overlay(CuvenColors.hairlineSeparator)
                menuActionRow(
                    title: "Unsend",
                    systemImage: "arrow.uturn.backward",
                    tint: CuvenColors.dangerRedText
                ) {
                    CuvenHaptics.rigidImpact()
                    onUnsend()
                    dismissWithSpring()
                }
            }
        }
        .frame(width: 248)
        .cuvenLiquidGlass(mode: .tinted, cornerRadius: 22, interactiveBounce: false)
    }

    private var editHistoryTimelineView: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(message.editHistory.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 3) {
                    Text(ThreadTimeFormatter.separatorMark(from: entry.editedAt, opensNewDay: true, use24Hour: use24HourTime))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(CuvenColors.inkSecondary)
                    Text(entry.text)
                        .font(.system(size: 13.5))
                        .foregroundStyle(CuvenColors.inkPrimary.opacity(0.75))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(CuvenColors.fieldBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Current")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CuvenColors.accessibleBlueText)
                Text(message.text)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(isOutgoing ? ThreadSurfaceTokens.outgoingForeground : ThreadSurfaceTokens.incomingForeground)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isOutgoing ? ThreadSurfaceTokens.outgoingFill : ThreadSurfaceTokens.incomingFill)
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CuvenColors.paperBackground.opacity(0.45))
    }

    private func menuActionRow(
        title: String,
        systemImage: String,
        tint: Color = CuvenColors.inkPrimary,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard interactionArmed else { return }
            action()
        } label: {
            HStack(spacing: 12) {
                Text(title)
                    .font(CuvenFonts.cappedCallout(weight: .regular))
                    .foregroundStyle(tint)
                Spacer()
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(tint)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func disabledGovernanceRow(title: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(CuvenColors.inkSecondary)
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .foregroundStyle(CuvenColors.inkSecondary)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
    }

    private func dismissWithSpring() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.1) : .easeOut(duration: 0.18)) {
            appeared = false
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 80 : 140))
            onDismiss()
        }
    }
}

private struct ExactLiftedFrameModifier: ViewModifier {
    let lockedSize: CGSize?
    let isOutgoing: Bool

    func body(content: Content) -> some View {
        if let lockedSize {
            content
                .frame(width: lockedSize.width, height: lockedSize.height, alignment: .topLeading)
        } else {
            content
                .frame(maxWidth: 320, alignment: isOutgoing ? .trailing : .leading)
        }
    }
}


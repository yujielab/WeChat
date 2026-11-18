import SwiftUI
import CuvenCore

// MARK: - Message Bubble Row & Rich Content Renderer

struct MessageBubbleView: View {
    let item: ThreadDisplayItem
    let currentUserID: String?
    let messagesByID: [String: Message]
    let contactsByUserID: [String: CuvenUser]
    let serverBaseURL: URL
    let maxBubbleWidth: CGFloat
    let glassMode: GlassAppearanceMode
    let use24HourTime: Bool
    let smartAssistEnabled: Bool
    let editingMessageID: String?
    let liftedMessageID: String?
    let flashedMessageID: String?
    let timeRevealOffset: CGFloat
    let voicePlayer: VoiceMessagePlayer

    let onReply: (Message) -> Void
    let onJumpToMessage: (String) -> Void
    let onOpenContextMenu: (Message, Bool, CGSize?) -> Void
    let onQuickHeartReaction: (Message) -> Void
    let onOpenExplain: (Message, String) -> Void
    let onOpenEditHistory: (Message) -> Void
    let onOpenLightbox: ([String], Int) -> Void
    let onExpandPhotoStack: (String) -> Void
    let onRetryFailed: (Message) -> Void

    @State private var expandedCallGroup: Bool = false
    @State private var swipeReplyOffset: CGFloat = 0
    @State private var swipeReplyArmed: Bool = false
    @State private var isLongPressing: Bool = false
    @State private var stickerBounceTrigger: Int = 0
    @State private var measuredBubbleSize: CGSize = .zero

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let swipeReplyThreshold: CGFloat = 56

    var body: some View {
        switch item {
        case .timestampSeparator(_, let label, _):
            Text(label)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(ThreadSurfaceTokens.timestampInk(for: colorScheme))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 18)
                .padding(.bottom, 10)
                .accessibilityAddTraits(.isHeader)

        case .unreadDivider(let count):
            HStack(spacing: 10) {
                Rectangle()
                    .fill(CuvenColors.accessibleBlueText.opacity(0.28))
                    .frame(height: 0.75)
                Text(count > 1 ? "\(count) new messages below" : "New messages below")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CuvenColors.accessibleBlueText)
                Rectangle()
                    .fill(CuvenColors.accessibleBlueText.opacity(0.28))
                    .frame(height: 0.75)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 8)

        case .systemNotice(_, let text, _, let isRevoked):
            Text(text)
                .font(.system(size: 12.5, weight: .regular))
                .italic(isRevoked)
                .foregroundStyle(isRevoked ? CuvenColors.inkSecondary : CuvenColors.noticeText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background {
                    if !isRevoked {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(CuvenColors.noticeBackground)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 4)

        case .callGroup(_, let calls, let isOutgoing):
            callGroupRow(calls: calls, isOutgoing: isOutgoing)

        case .photoStack(let stackID, let photos, let urls, let isOutgoing, let senderDisplay, let senderID, let isStatusTarget):
            if let primary = photos.last {
                let inlineClock = ThreadTimeFormatter.clockString(from: primary.createdAt, use24Hour: use24HourTime)
                ZStack(alignment: .trailing) {
                    HStack {
                        if isOutgoing { Spacer(minLength: 28) }
                        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
                            PhotoStackFanView(
                                messages: photos,
                                mediaURLs: urls,
                                isOutgoing: isOutgoing,
                                senderDisplay: senderDisplay,
                                senderAvatarURL: contactsByUserID[senderID]?.avatarURL,
                                serverBaseURL: serverBaseURL,
                                maxMediaWidth: min(256, maxBubbleWidth),
                                use24HourTime: use24HourTime,
                                onOpenLightbox: onOpenLightbox,
                                onExpandInline: { onExpandPhotoStack(stackID) }
                            )
                            .background(
                                GeometryReader { stackGeo in
                                    Color.clear
                                        .onAppear { measuredBubbleSize = stackGeo.size }
                                        .onChange(of: stackGeo.size) { _, newSize in measuredBubbleSize = newSize }
                                }
                            )
                            .opacity(liftedMessageID == primary.id ? 0.0 : 1.0)
                            .onLongPressGesture(minimumDuration: 0.46) {
                                CuvenHaptics.softImpact()
                                onOpenContextMenu(primary, isOutgoing, measuredBubbleSize)
                            }

                            reactionChipView(for: primary, isOutgoing: isOutgoing)

                            if isStatusTarget {
                                deliveryReceiptLine(for: primary)
                            }
                        }
                        if !isOutgoing { Spacer(minLength: 28) }
                    }
                    .offset(x: isOutgoing ? -timeRevealOffset : -min(timeRevealOffset * 0.35, 18))

                    inlineTimestampOverlay(clock: inlineClock)
                }
                .padding(.horizontal, 4)
                .padding(.top, 8)
            }

        case .bubble(let runItem):
            singleBubbleRow(runItem)
        }
    }

    // MARK: - Single Message Bubble Row

    @ViewBuilder
    private func singleBubbleRow(_ runItem: MessageRunItem) -> some View {
        let message = runItem.message
        let isOutgoing = runItem.isOutgoing
        let inlineClock = ThreadTimeFormatter.clockString(from: message.createdAt, use24Hour: use24HourTime)
        let isBeingEdited = editingMessageID == message.id
        let isFlashed = flashedMessageID == message.id

        ZStack(alignment: .leading) {
            // Swipe-to-reply spring indicator revealed behind leading edge
            if swipeReplyOffset > 6 {
                let progress = min(1.0, swipeReplyOffset / swipeReplyThreshold)
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(swipeReplyArmed ? Color.white : CuvenColors.inkSecondary)
                    .frame(width: 30, height: 30)
                    .background(
                        Circle()
                            .fill(swipeReplyArmed ? CuvenColors.sidebarBlue : CuvenColors.fieldBackground)
                    )
                    .scaleEffect(swipeReplyArmed ? 1.12 : (0.65 + 0.35 * progress))
                    .opacity(Double(progress))
                    .padding(.leading, 8)
            }

            ZStack(alignment: .trailing) {
                HStack(alignment: .bottom, spacing: 8) {
                    if isOutgoing {
                        Spacer(minLength: 36)
                        if message.deliveryState == .failed {
                            failedRetryButton(for: message)
                        }
                    } else {
                        groupAvatarSlot(for: runItem)
                    }

                    VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 2) {
                        if runItem.showGroupSenderName {
                            Text(message.senderDisplay.isEmpty ? "Member" : message.senderDisplay)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(CuvenColors.inkSecondary)
                                .padding(.leading, 12)
                                .padding(.bottom, 1)
                        }

                        // Reply quote block above non-text media bubbles
                        if message.kind != .text, let replyID = message.replyToMessageID {
                            replyQuoteBanner(replyID: replyID, insideOutgoingTextBubble: false)
                        }

                        bubbleSurface(for: runItem, isBeingEdited: isBeingEdited, isFlashed: isFlashed)
                            .background(
                                GeometryReader { bubGeo in
                                    Color.clear
                                        .onAppear {
                                            if bubGeo.size.width > 0 { measuredBubbleSize = bubGeo.size }
                                        }
                                        .onChange(of: bubGeo.size) { _, newSize in
                                            if newSize.width > 0 { measuredBubbleSize = newSize }
                                        }
                                }
                            )
                            .opacity(liftedMessageID == message.id ? 0.0 : 1.0)
                            .scaleEffect(isLongPressing && !reduceMotion ? 0.97 : 1.0)
                            .animation(CuvenSprings.pressBounce, value: isLongPressing)

                        reactionChipView(for: message, isOutgoing: isOutgoing)

                        if message.editCount > 0 {
                            Button {
                                CuvenHaptics.lightTap()
                                onOpenEditHistory(message)
                            } label: {
                                Text("Edited")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(CuvenColors.accessibleBlueText)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Edited message, tap to view edit history")
                        }

                        if runItem.isLatestOutgoingStatusTarget {
                            deliveryReceiptLine(for: message)
                        }
                    }
                    .frame(maxWidth: maxBubbleWidth, alignment: isOutgoing ? .trailing : .leading)

                    if !isOutgoing {
                        Spacer(minLength: 36)
                    }
                }
                .offset(x: swipeReplyOffset + (isOutgoing ? -timeRevealOffset : -min(timeRevealOffset * 0.3, 16)))

                inlineTimestampOverlay(clock: inlineClock)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, runItem.isFirstInRun ? 11 : 3)
        .simultaneousGesture(swipeToReplyGesture(for: message))
    }

    // MARK: - Bubble Surface Per MessageKind

    @ViewBuilder
    private func bubbleSurface(
        for runItem: MessageRunItem,
        isBeingEdited: Bool,
        isFlashed: Bool
    ) -> some View {
        let message = runItem.message
        let isOutgoing = runItem.isOutgoing
        let shape = BubbleTailShape(
            isOutgoing: isOutgoing,
            isFirstInRun: runItem.isFirstInRun,
            isLastInRun: runItem.isLastInRun,
            showTail: runItem.hasTail
        )

        Group {
            switch message.kind {
            case .text:
                if ThreadGroupingEngine.isJumboEmojiOnly(message.text) && message.replyToMessageID == nil {
                    Text(message.text)
                        .font(.system(size: 44))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        if let replyID = message.replyToMessageID {
                            replyQuoteBanner(replyID: replyID, insideOutgoingTextBubble: isOutgoing)
                        }
                        styledMessageText(for: message, isOutgoing: isOutgoing)
                            .tint(isOutgoing ? Color.white : CuvenColors.sidebarBlue)
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 11)
                    .padding(.leading, isOutgoing ? 15 : (15 + (runItem.hasTail ? 6.5 : 0)))
                    .padding(.trailing, isOutgoing ? (15 + (runItem.hasTail ? 6.5 : 0)) : 15)
                    .background(
                        shape.fill(isOutgoing ? ThreadSurfaceTokens.outgoingFill : ThreadSurfaceTokens.incomingFill)
                    )
                    .overlay {
                        if isBeingEdited {
                            shape.stroke(CuvenColors.systemBlue, lineWidth: 2)
                        } else if isFlashed {
                            shape.fill(Color.white.opacity(0.24))
                        }
                    }
                    .contentShape(shape)
                    .gesture(
                        SpatialTapGesture(count: 2)
                            .onEnded { tapValue in
                                guard message.deliveryState != .revoked else { return }
                                if smartAssistEnabled {
                                    CuvenHaptics.selectionChanged()
                                    let w = max(1.0, measuredBubbleSize.width)
                                    let h = max(1.0, measuredBubbleSize.height)
                                    let seedPhrase = WordExplainTokenizer.wordNearNormalizedPoint(
                                        in: message.text,
                                        normalizedX: tapValue.location.x / w,
                                        normalizedY: tapValue.location.y / h,
                                        highlightedKeywords: message.highlightedKeywords
                                    )
                                    let finalSeed = seedPhrase.isEmpty ? preferredInitialExplainSeed(for: message) : seedPhrase
                                    onOpenExplain(message, finalSeed)
                                } else {
                                    CuvenHaptics.lightTap()
                                    onQuickHeartReaction(message)
                                }
                            }
                    )
                }

            case .image:
                let mediaSize = ThreadGroupingEngine.mediaDisplaySize(
                    width: message.mediaWidth,
                    height: message.mediaHeight,
                    maxWidth: min(260, maxBubbleWidth),
                    maxHeight: 310
                )
                let firstURL = message.mediaURLs.first ?? ""
                Button {
                    CuvenHaptics.lightTap()
                    onOpenLightbox(message.mediaURLs.isEmpty ? [firstURL] : message.mediaURLs, 0)
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        ThreadMediaImageView(
                            urlString: firstURL,
                            serverBaseURL: serverBaseURL,
                            contentMode: .fill,
                            isDrawing: false
                        )
                        .frame(width: mediaSize.width, height: mediaSize.height)
                        .clipped()
                        .brightness(message.deliveryState == .sending ? -0.12 : 0)

                        if message.deliveryState == .sending {
                            ProgressView()
                                .tint(.white)
                                .padding(8)
                                .background(Color.black.opacity(0.45), in: Circle())
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(CuvenColors.hairlineSeparator, lineWidth: 0.75)
                    )
                }
                .buttonStyle(.plain)

            case .drawing:
                let canvasSize = ThreadGroupingEngine.mediaDisplaySize(
                    width: message.mediaWidth ?? 800,
                    height: message.mediaHeight ?? 600,
                    maxWidth: min(244, maxBubbleWidth),
                    maxHeight: 244
                )
                let drawingURL = message.mediaURLs.first ?? ""
                Button {
                    CuvenHaptics.lightTap()
                    onOpenLightbox([drawingURL], 0)
                } label: {
                    ThreadMediaImageView(
                        urlString: drawingURL,
                        serverBaseURL: serverBaseURL,
                        contentMode: .fit,
                        isDrawing: true
                    )
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(CuvenColors.cardLine, lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ink drawing message, tap to view full screen")

            case .sticker:
                stickerBubbleContent(for: message)

            case .voice:
                voiceBubbleContent(for: message, isOutgoing: isOutgoing, hasTail: runItem.hasTail, shape: shape)

            case .video:
                let videoSize = ThreadGroupingEngine.mediaDisplaySize(
                    width: message.mediaWidth ?? 720,
                    height: message.mediaHeight ?? 1280,
                    maxWidth: min(236, maxBubbleWidth),
                    maxHeight: 290
                )
                let videoURL = message.mediaURLs.first ?? ""
                Button {
                    CuvenHaptics.lightTap()
                    onOpenLightbox([videoURL], 0)
                } label: {
                    ZStack {
                        ThreadMediaImageView(
                            urlString: videoURL,
                            serverBaseURL: serverBaseURL,
                            contentMode: .fill,
                            isDrawing: false
                        )
                        .frame(width: videoSize.width, height: videoSize.height)
                        .clipped()

                        Image(systemName: "play.fill")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(CuvenColors.inkPrimary)
                            .offset(x: 1.5)
                            .frame(width: 50, height: 50)
                            .cuvenLiquidGlass(mode: glassMode, cornerRadius: 25, interactiveBounce: true)

                        if let dur = message.durationSeconds, dur > 0 {
                            VStack {
                                Spacer()
                                HStack {
                                    Text(ThreadTimeFormatter.durationString(seconds: dur))
                                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    Spacer()
                                }
                                .padding(8)
                            }
                        }
                    }
                    .frame(width: videoSize.width, height: videoSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(CuvenColors.hairlineSeparator, lineWidth: 0.75)
                    )
                }
                .buttonStyle(.plain)

            case .file:
                HStack(spacing: 12) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(CuvenColors.systemBlue)
                        .frame(width: 42, height: 42)
                        .background(CuvenColors.fieldBackground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(message.text.isEmpty ? "Shared Document" : message.text)
                            .font(CuvenFonts.cappedSubheadline(weight: .semibold))
                            .foregroundStyle(CuvenColors.inkPrimary)
                            .lineLimit(2)
                        Text("Tap to preview")
                            .font(.system(size: 12))
                            .foregroundStyle(CuvenColors.inkSecondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: 250, alignment: .leading)
                .background(CuvenColors.cardSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(CuvenColors.cardLine, lineWidth: 1)
                )

            case .call:
                let isMissed = message.text.lowercased().contains("missed") || message.text.lowercased().contains("unanswered")
                let isVideo = message.text.lowercased().contains("video")
                HStack(spacing: 7) {
                    Image(systemName: isVideo ? "video.fill" : "phone.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(message.text.isEmpty ? (isVideo ? "Video call" : "Voice call") : message.text)
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(isMissed ? CuvenColors.dangerRedText : CuvenColors.inkSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(CuvenColors.fieldBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            case .system:
                EmptyView()
            }
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.46, maximumDistance: 12)
                .onChanged { pressing in
                    isLongPressing = pressing
                }
                .onEnded { _ in
                    isLongPressing = false
                    guard message.kind != .system && message.deliveryState != .revoked else { return }
                    CuvenHaptics.softImpact()
                    onOpenContextMenu(message, isOutgoing, measuredBubbleSize)
                }
        )
    }

    // MARK: - Rich Text Builder (@mentions + Underlined AI `highlightedKeywords` + Links)

    private func styledMessageText(for message: Message, isOutgoing: Bool) -> Text {
        let raw = message.text
        var attributed = AttributedString(raw)
        let baseColor = isOutgoing ? ThreadSurfaceTokens.outgoingForeground : ThreadSurfaceTokens.incomingForeground
        attributed.foregroundColor = baseColor

        // 1. Highlight HTTP(S) URLs (`chat.css:103` `--link-out: #ffffff` so blue-on-blue never vanishes)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            for match in detector.matches(in: raw, options: [], range: nsRange) {
                if let swiftRange = Range(match.range, in: raw),
                   let attrRange = Range(swiftRange, in: attributed),
                   let url = match.url,
                   (url.scheme == "https" || url.scheme == "http")
                {
                    attributed[attrRange].link = url
                    attributed[attrRange].foregroundColor = isOutgoing ? Color.white : CuvenColors.accessibleBlueText
                    attributed[attrRange].underlineStyle = .single
                }
            }
        }

        // 2. Style AI `highlightedKeywords` (`src/assist.js` + `thread.css:860-868`)
        if smartAssistEnabled && !message.highlightedKeywords.isEmpty {
            for keyword in message.highlightedKeywords where !keyword.isEmpty {
                var searchStart = raw.startIndex
                while let found = raw.range(of: keyword, options: [], range: searchStart..<raw.endIndex) {
                    if let attrRange = Range(found, in: attributed), attributed[attrRange].link == nil {
                        attributed[attrRange].inlinePresentationIntent = .stronglyEmphasized
                        attributed[attrRange].underlineStyle = Text.LineStyle(
                            pattern: .solid,
                            color: isOutgoing ? Color.white.opacity(0.85) : CuvenColors.sidebarBlue.opacity(0.75)
                        )
                        attributed[attrRange].backgroundColor = isOutgoing
                            ? Color.white.opacity(0.18)
                            : CuvenColors.sidebarBlue.opacity(0.12)
                    }
                    searchStart = found.upperBound
                }
            }
        }

        // 3. Style `@mention` pills (`thread.css:915-918`)
        if raw.contains("@") {
            let pattern = "@[\\p{L}\\p{N}_.-]{1,24}"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
                for match in regex.matches(in: raw, range: nsRange) {
                    if let swiftRange = Range(match.range, in: raw),
                       let attrRange = Range(swiftRange, in: attributed)
                    {
                        let token = String(raw[swiftRange])
                        let mentionsCurrentUser: Bool = {
                            guard let currentUserID else { return false }
                            return message.mentions.contains(currentUserID)
                                && (token.lowercased().contains(currentUserID.lowercased()) || message.mentions.count == 1)
                        }()
                        attributed[attrRange].inlinePresentationIntent = .stronglyEmphasized
                        if mentionsCurrentUser {
                            attributed[attrRange].backgroundColor = isOutgoing
                                ? Color.white
                                : CuvenColors.unreadBadgeBackground
                            attributed[attrRange].foregroundColor = isOutgoing
                                ? CuvenColors.outgoingBubble
                                : CuvenColors.unreadBadgeText
                        } else {
                            attributed[attrRange].backgroundColor = isOutgoing
                                ? Color.white.opacity(0.22)
                                : CuvenColors.sidebarBlue.opacity(0.15)
                            if !isOutgoing {
                                attributed[attrRange].foregroundColor = CuvenColors.accessibleBlueText
                            }
                        }
                    }
                }
            }
        }

        return Text(attributed)
            .font(CuvenFonts.cappedBody())
    }

    private func preferredInitialExplainSeed(for message: Message) -> String {
        if let firstKeyword = message.highlightedKeywords.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return firstKeyword
        }
        let words = message.text
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        if let meaningful = words.first(where: { $0.count >= 4 }) ?? words.first {
            return String(meaningful.prefix(48))
        }
        return String(message.text.prefix(48))
    }

    // MARK: - Sticker & Voice Bubble Renderers

    @ViewBuilder
    private func stickerBubbleContent(for message: Message) -> some View {
        let assetURL = message.mediaURLs.first ?? ""
        Button {
            CuvenHaptics.lightTap()
            stickerBounceTrigger += 1
        } label: {
            ZStack {
                if let stickerID = message.stickerID, !stickerID.isEmpty,
                   let stickerSet = message.stickerSet, !stickerSet.isEmpty
                {
                    AnimatedStickerRenderer(
                        stickerID: stickerID,
                        setName: stickerSet,
                        emoji: message.text.isEmpty ? "✨" : message.text,
                        format: message.stickerFormat ?? .staticWebP,
                        size: 128,
                        serverBaseURL: serverBaseURL
                    )
                } else if !assetURL.isEmpty {
                    ThreadMediaImageView(
                        urlString: assetURL,
                        serverBaseURL: serverBaseURL,
                        contentMode: .fit,
                        isDrawing: false
                    )
                    .frame(width: 124, height: 124)
                } else {
                    Text(message.text.isEmpty ? "✨" : message.text)
                        .font(.system(size: 68))
                        .frame(width: 112, height: 112)
                }
            }
            .scaleEffect(stickerBounceTrigger % 2 == 1 && !reduceMotion ? 1.08 : 1.0)
            .animation(CuvenSprings.bubblePop, value: stickerBounceTrigger)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sticker \(message.text.isEmpty ? (message.stickerSet ?? "") : message.text)")
    }

    @ViewBuilder
    private func voiceBubbleContent(
        for message: Message,
        isOutgoing: Bool,
        hasTail: Bool,
        shape: BubbleTailShape
    ) -> some View {
        let duration = max(1.0, message.durationSeconds ?? 4.0)
        let bars = VoiceMessagePlayer.waveformHeights(messageID: message.id, durationSeconds: duration)
        let isPlaying = voicePlayer.isPlayingMessage(message.id)
        let progress = voicePlayer.progress(for: message.id)
        let fgColor = isOutgoing ? ThreadSurfaceTokens.outgoingForeground : ThreadSurfaceTokens.incomingForeground

        HStack(spacing: 10) {
            Button {
                CuvenHaptics.lightTap()
                voicePlayer.togglePlayback(
                    messageID: message.id,
                    mediaURLString: message.mediaURLs.first,
                    serverBaseURL: serverBaseURL,
                    fallbackDuration: duration
                )
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .offset(x: isPlaying ? 0 : 1)
                    .foregroundStyle(isOutgoing ? ThreadSurfaceTokens.outgoingFill : ThreadSurfaceTokens.incomingFill)
                    .frame(width: 32, height: 32)
                    .background(fgColor, in: Circle())
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(isPlaying ? "Pause voice message" : "Play voice message")

            GeometryReader { geo in
                HStack(alignment: .center, spacing: 2.5) {
                    ForEach(Array(bars.enumerated()), id: \.offset) { idx, barHeight in
                        let threshold = Double(idx) / Double(max(1, bars.count))
                        let active = progress > threshold || (isPlaying && idx == 0)
                        Capsule(style: .continuous)
                            .fill(fgColor.opacity(active ? 1.0 : 0.35))
                            .frame(width: 2.6, height: barHeight)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let ratio = Double(drag.location.x / max(1, geo.size.width))
                            voicePlayer.seek(messageID: message.id, to: ratio, fallbackDuration: duration)
                        }
                )
            }
            .frame(width: min(148, CGFloat(bars.count) * 5.2), height: 26)

            Text(ThreadTimeFormatter.durationString(seconds: isPlaying ? max(1, duration * (1.0 - progress)) : duration))
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                .foregroundStyle(fgColor.opacity(0.84))
        }
        .padding(.vertical, 6)
        .padding(.leading, isOutgoing ? 8 : (8 + (hasTail ? 6.5 : 0)))
        .padding(.trailing, isOutgoing ? (14 + (hasTail ? 6.5 : 0)) : 14)
        .background(
            shape.fill(isOutgoing ? ThreadSurfaceTokens.outgoingFill : ThreadSurfaceTokens.incomingFill)
        )
    }

    // MARK: - Reply Quote, Reactions, Call Group & Receipt Subviews

    @ViewBuilder
    private func replyQuoteBanner(replyID: String, insideOutgoingTextBubble: Bool) -> some View {
        let target = messagesByID[replyID]
        let isRecalled = target == nil || target?.deliveryState == .revoked
        let authorName: String = {
            guard let target else { return "Reply" }
            if let currentUserID, target.senderID == currentUserID { return "You" }
            return target.senderDisplay.isEmpty ? "Friend" : target.senderDisplay
        }()
        let preview = ThreadGroupingEngine.quotePreviewText(for: target)

        Button {
            guard !isRecalled else { return }
            CuvenHaptics.lightTap()
            onJumpToMessage(replyID)
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(insideOutgoingTextBubble ? Color.white.opacity(0.82) : CuvenColors.sidebarBlue)
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 1.5) {
                    if !isRecalled {
                        Text(authorName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(insideOutgoingTextBubble ? Color.white : CuvenColors.accessibleBlueText)
                            .lineLimit(1)
                    }
                    Text(preview)
                        .font(.system(size: 12))
                        .italic(isRecalled)
                        .foregroundStyle(
                            insideOutgoingTextBubble
                                ? Color.white.opacity(isRecalled ? 0.65 : 0.86)
                                : CuvenColors.inkSecondary
                        )
                        .lineLimit(1)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        insideOutgoingTextBubble
                            ? Color.white.opacity(0.16)
                            : Color.primary.opacity(0.06)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isRecalled)
    }

    @ViewBuilder
    private func reactionChipView(for message: Message, isOutgoing: Bool) -> some View {
        if !message.reactions.isEmpty {
            let uniqueEmojis = orderedReactionGroups(message.reactions)
            let hasMyReaction = currentUserID != nil && message.reactions.contains(where: { $0.userID == currentUserID })

            Button {
                CuvenHaptics.lightTap()
                onOpenContextMenu(message, isOutgoing, measuredBubbleSize)
            } label: {
                HStack(spacing: 3) {
                    ForEach(uniqueEmojis, id: \.emoji) { group in
                        Text(group.emoji)
                            .font(.system(size: 13.5))
                    }
                    if message.reactions.count > 1 {
                        Text("\(message.reactions.count)")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(CuvenColors.inkSecondary)
                            .padding(.leading, 1)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(CuvenColors.incomingBubble, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(
                            hasMyReaction ? CuvenColors.sidebarBlue.opacity(0.65) : CuvenColors.paperBackground,
                            lineWidth: hasMyReaction ? 1.5 : 2
                        )
                )
                .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)
            }
            .buttonStyle(.plain)
            .padding(.top, -9)
            .padding(isOutgoing ? .trailing : .leading, 12)
            .frame(maxWidth: .infinity, alignment: isOutgoing ? .leading : .trailing)
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel("Reactions: \(message.reactions.map(\.emoji).joined(separator: " "))")
        }
    }

    @ViewBuilder
    private func deliveryReceiptLine(for message: Message) -> some View {
        let status = message.deliveryState
        HStack(spacing: 4) {
            switch status {
            case .queued, .sending:
                ProgressView()
                    .controlSize(.mini)
                Text(status == .queued ? "Queued" : "Sending…")
            case .sent:
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                Text("Sent")
            case .delivered:
                HStack(spacing: -4) {
                    Image(systemName: "checkmark")
                    Image(systemName: "checkmark")
                }
                .font(.system(size: 10, weight: .semibold))
                Text("Delivered")
            case .read:
                HStack(spacing: -4) {
                    Image(systemName: "checkmark")
                    Image(systemName: "checkmark")
                }
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(CuvenColors.readTickBlue)
                Text("Read")
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                Text("Not sent")
            case .revoked:
                EmptyView()
            }
        }
        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
        .foregroundStyle(
            status == .failed
                ? CuvenColors.dangerRedText
                : ThreadSurfaceTokens.timestampInk(for: colorScheme)
        )
        .padding(.top, 2)
        .padding(.trailing, 4)
    }

    @ViewBuilder
    private func failedRetryButton(for message: Message) -> some View {
        Button {
            CuvenHaptics.lightTap()
            onRetryFailed(message)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                Text("Retry")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(CuvenColors.dangerRedText)
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(CuvenColors.dangerRed.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
    }

    @ViewBuilder
    private func groupAvatarSlot(for runItem: MessageRunItem) -> some View {
        if runItem.showGroupAvatar {
            let senderUser = contactsByUserID[runItem.message.senderID]
            CuvenAvatarView(
                name: runItem.message.senderDisplay.isEmpty ? "Member" : runItem.message.senderDisplay,
                urlString: senderUser?.avatarURL,
                size: 28,
                isOnline: senderUser?.isOnline ?? false
            )
        } else if runItem.showGroupSenderName {
            Color.clear.frame(width: 28, height: 28)
        }
    }

    @ViewBuilder
    private func callGroupRow(calls: [Message], isOutgoing: Bool) -> some View {
        let latest = calls[calls.count - 1]
        let isVideo = latest.text.lowercased().contains("video")
        HStack {
            if isOutgoing { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                if expandedCallGroup {
                    ForEach(calls) { call in
                        HStack(spacing: 7) {
                            Image(systemName: call.text.lowercased().contains("video") ? "video.fill" : "phone.fill")
                                .font(.system(size: 12))
                            Text(call.text.isEmpty ? "Missed call" : call.text)
                                .font(.system(size: 12.5))
                            Spacer(minLength: 8)
                            Text(ThreadTimeFormatter.clockString(from: call.createdAt, use24Hour: use24HourTime))
                                .font(.system(size: 11.5).monospacedDigit())
                                .foregroundStyle(CuvenColors.inkSecondary)
                        }
                        .foregroundStyle(CuvenColors.dangerRedText)
                    }
                    Divider()
                }

                Button {
                    CuvenHaptics.lightTap()
                    withAnimation(.easeOut(duration: 0.22)) {
                        expandedCallGroup.toggle()
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: isVideo ? "video.fill" : "phone.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text(latest.text.isEmpty ? "Missed calls" : latest.text)
                            .font(.system(size: 13, weight: .medium))
                        Text("(\(calls.count))")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        Image(systemName: expandedCallGroup ? "chevron.down" : "chevron.up")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(CuvenColors.dangerRedText)
                    .frame(minHeight: 32)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(CuvenColors.fieldBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if !isOutgoing { Spacer(minLength: 40) }
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func inlineTimestampOverlay(clock: String) -> some View {
        if timeRevealOffset > 2 {
            let progress = min(1.0, timeRevealOffset / 56.0)
            Text(clock)
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(ThreadSurfaceTokens.timestampInk(for: colorScheme))
                .opacity(Double(progress))
                .offset(x: max(0, 56 - timeRevealOffset))
                .allowsHitTesting(false)
        }
    }

    // MARK: - 1:1 Spring Swipe-Right to Reply Gesture

    private func swipeToReplyGesture(for message: Message) -> some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .local)
            .onChanged { value in
                // Leave leading 40pt edge exclusively to StripContainerView's interactive column back-pan!
                guard value.startLocation.x >= 40 else { return }
                guard message.kind != .system && message.deliveryState != .revoked else { return }

                let dx = value.translation.width
                let dy = value.translation.height
                guard dx > 0, dx > abs(dy) * 1.35 else { return }

                let damped: CGFloat
                if dx <= swipeReplyThreshold {
                    damped = dx
                } else {
                    damped = swipeReplyThreshold + (dx - swipeReplyThreshold) * 0.25
                }
                swipeReplyOffset = min(84, damped)

                let armed = dx >= swipeReplyThreshold
                if armed && !swipeReplyArmed {
                    swipeReplyArmed = true
                    CuvenHaptics.lightTap()
                } else if !armed && swipeReplyArmed {
                    swipeReplyArmed = false
                }
            }
            .onEnded { _ in
                guard swipeReplyOffset > 0 else { return }
                let shouldTrigger = swipeReplyArmed
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : CuvenSprings.bubblePop) {
                    swipeReplyOffset = 0
                    swipeReplyArmed = false
                }
                if shouldTrigger {
                    onReply(message)
                }
            }
    }

    private func orderedReactionGroups(_ list: [MessageReaction]) -> [(emoji: String, count: Int)] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for reaction in list {
            if counts[reaction.emoji] == nil {
                order.append(reaction.emoji)
            }
            counts[reaction.emoji, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 1) }
    }
}

import SwiftUI

/// A row in the conversation: built once per render from the messages.
enum ThreadItem: Identifiable {
    /// A mark: the day (only on a day's first) and the time.
    case mark(id: String, day: String, time: String)
    case unread(id: String)
    case message(Message, RowLayout)

    var id: String {
        switch self {
        case .mark(let id, _, _): return id
        case .unread(let id): return id
        case .message(let m, _): return m.localId.map { "l:\($0)" } ?? m.id
        }
    }
}

struct RowLayout: Equatable {
    var mine: Bool
    var joinTop: Bool
    var joinBottom: Bool
    var showAvatar: Bool
    var showName: Bool
    var status: String?
    var failed: Bool
    /// Space above: 3 within one person's run, 12 when the other speaks, 0 under a mark.
    var gap: CGFloat
}

enum ThreadBuilder {
    /// Oldest first (ui/chat-time.js): a mark after five minutes of quiet or
    /// on a new day — the day's first names the day — and runs of one
    /// person's messages inside a stretch.
    static func items(_ messages: [Message], me: String?, isGroup: Bool, peerRead: Int, peerReadAt: Int,
                      receipts: Bool, unreadFrom: Int?) -> [ThreadItem] {
        var out: [ThreadItem] = []
        // Where your latest message stands shows under it only while it's the
        // latest thing said (or still going, or failed): chat-time.js.
        let lastSaid = messages.last(where: { !$0.isSystem })
        let lastMine = lastSaid?.sender == me ? lastSaid : nil
        var unreadPlaced = false
        let cal = Calendar.current

        func marks(_ prev: Message?, _ m: Message) -> Bool {
            guard let prev else { return true }
            return m.ts - prev.ts >= Fmt.gap || !cal.isDate(prev.date, inSameDayAs: m.date)
        }
        func joins(_ a: Message?, _ b: Message?) -> Bool {
            guard let a, let b, !a.isSystem, !b.isSystem, a.sender == b.sender else { return false }
            return !marks(a, b)
        }

        for (i, m) in messages.enumerated() {
            let prev = i > 0 ? messages[i - 1] : nil
            let next = i + 1 < messages.count ? messages[i + 1] : nil
            var gap: CGFloat = 12
            if marks(prev, m) {
                let opens = prev == nil || !cal.isDate(prev!.date, inSameDayAs: m.date)
                out.append(.mark(id: "t\(m.ts)", day: opens ? Fmt.markDay(m.date) : "", time: Fmt.clock(m.date)))
                gap = 0
            }
            if let from = unreadFrom, !unreadPlaced, m.ts > from, m.sender != me, !m.isSystem {
                out.append(.unread(id: "unread"))
                unreadPlaced = true
                gap = 4
            }
            if m.isSystem {
                out.append(.message(m, RowLayout(mine: false, joinTop: false, joinBottom: false, showAvatar: false,
                                                 showName: false, status: nil, failed: false, gap: gap)))
                continue
            }
            let mine = m.sender == me
            let joinTop = joins(prev, m) && gap != 4
            let joinBottom = joins(m, next) && !(unreadFrom.map { !unreadPlaced && next!.ts > $0 && next!.sender != me } ?? false)
            if joinTop { gap = 3 }
            var status: String?
            if m.local == .failed {
                status = String(localized: "Not sent")
            } else if mine && m.id == lastMine?.id {
                if m.local == .sending { status = String(localized: "Sending…") }
                else if !isGroup && receipts && peerRead >= m.ts {
                    status = peerReadAt > 0
                        ? String(localized: "Read \(Fmt.briefly(Date(timeIntervalSince1970: TimeInterval(peerReadAt) / 1000)))")
                        : String(localized: "Read")
                } else { status = String(localized: "Delivered") }
            }
            out.append(.message(m, RowLayout(mine: mine, joinTop: joinTop, joinBottom: joinBottom,
                                             showAvatar: !mine && !joinBottom, showName: isGroup && !mine && !joinTop,
                                             status: status, failed: m.local == .failed, gap: gap)))
        }
        return out
    }
}

// MARK: - Marks

/// "Today 11:07": the system face, 12pt medium, grey, on nothing; the day carries the weight.
struct TimeMark: View {
    let day: String
    let time: String

    var body: some View {
        Group {
            if day.isEmpty {
                Text(time)
            } else {
                Text(day).font(.system(size: 12, weight: .semibold)) + Text(" " + time)
            }
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundStyle(Theme.timeInk)
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .accessibilityAddTraits(.isHeader)
    }
}

/// "New messages below": a full-width band, blue words, a hairline under it.
struct UnreadDivider: View {
    var body: some View {
        Text("New messages below")
            .font(AppFont.make(13, .bold))
            .tracking(0.26)
            .foregroundStyle(Theme.chipAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(Theme.bg)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            .padding(.top, 18)
            .padding(.bottom, 12)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Row

struct MessageRow: View {
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    let message: Message
    let layout: RowLayout
    let width: CGFloat
    var highlighted = false
    var onLongPress: (CGRect) -> Void
    var onReply: () -> Void
    var onOpenMedia: (CGRect) -> Void
    var onJumpTo: (String) -> Void

    @State private var swipe: CGFloat = 0
    @State private var burst = 0
    @State private var pressed = false
    @State private var probe = ProbeBox()

    static let avatarSize: CGFloat = 32
    private var avatarRoom: CGFloat { layout.mine ? 0 : Self.avatarSize + 10 }
    private var maxBubble: CGFloat { min((width - avatarRoom) * 0.82, 459) }

    var body: some View {
        if message.isSystem {
            Text(message.body)
                .font(.footnoteC)
                .lineSpacing(2)
                .foregroundStyle(Theme.noticeText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Theme.noticeBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: Theme.bubbleShadow, radius: 0.25, y: 1)
                .frame(maxWidth: width * 0.82)
                .frame(maxWidth: .infinity)
                .padding(.top, max(8, layout.gap))
                .padding(.bottom, 8)
        } else {
            VStack(alignment: layout.mine ? .trailing : .leading, spacing: 0) {
                if layout.showName {
                    Text(model.name(of: message.sender))
                        .font(.captionC)
                        .foregroundStyle(Theme.label2)
                        .lineLimit(1)
                        .padding(.leading, avatarRoom + 12)
                        .padding(.bottom, 2)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    if !layout.mine { avatar }
                    VStack(alignment: layout.mine ? .trailing : .leading, spacing: 0) {
                        bubble
                        if !message.reactions.isEmpty {
                            reactions
                                .padding(.top, -9)
                                .padding(layout.mine ? .leading : .trailing, 12)
                                .frame(maxWidth: maxBubble, alignment: layout.mine ? .leading : .trailing)
                                .fixedSize(horizontal: true, vertical: false)
                                .zIndex(1)
                                .transition(.asymmetric(insertion: .scale(scale: 0.4, anchor: .top).combined(with: .opacity).combined(with: .offset(y: -6)),
                                                        removal: .opacity))
                        }
                    }
                    .frame(maxWidth: maxBubble, alignment: layout.mine ? .trailing : .leading)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .frame(maxWidth: .infinity, alignment: layout.mine ? .trailing : .leading)

                if let status = layout.status {
                    HStack(spacing: 5) {
                        if layout.failed { SymbolView(.exclaim, size: 13) }
                        Text(status).contentTransition(.opacity)
                        if layout.failed {
                            Button("Retry") { model.retry(message) }
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.blueText)
                                .buttonStyle(.plain)
                        }
                    }
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(layout.failed ? Theme.redText : Theme.timeInk)
                    .padding(.top, 4)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
                }
            }
            .animation(Motion.bouncy, value: message.reactions)
            .animation(.easeOut(duration: 0.15), value: layout.status)
            .padding(.horizontal, 4)
            .padding(.top, layout.gap)
            .offset(x: swipe)
            .background(alignment: .leading) {
                if swipe > 10 {
                    SymbolView(.reply, size: 18)
                        .foregroundStyle(swipe > 56 ? Theme.blue : Theme.label3)
                        .scaleEffect(swipe > 56 ? 1.15 : 0.9)
                        .padding(.leading, 6)
                        .opacity(Double(min(1, swipe / 56)))
                        .animation(Motion.ui, value: swipe > 56)
                }
            }
            .simultaneousGesture(replySwipe)
            .background {
                if highlighted {
                    Theme.blue.opacity(0.08).padding(.horizontal, -40).transition(.opacity)
                }
            }
            .animation(Motion.ui, value: highlighted)
        }
    }

    @ViewBuilder
    private var avatar: some View {
        Group {
            if layout.showAvatar {
                // Their photo opens their page, as in every messenger.
                Button { nav.profile = message.sender } label: {
                    Avatar(user: model.user(message.sender) ?? User(id: message.sender, display: model.name(of: message.sender)),
                           size: Self.avatarSize)
                        .contentShape(Circle().inset(by: -6))
                }
                .buttonStyle(.press(0.94))
                .accessibilityLabel(Text(model.name(of: message.sender)))
            } else {
                Color.clear
            }
        }
        .frame(width: Self.avatarSize, height: Self.avatarSize)
        .zIndex(2)
    }

    private var tailed: Bool {
        !layout.joinBottom && ["text", "voice", "file"].contains(message.type) && !Fmt.isJumboEmoji(message.body)
    }

    private var bubble: some View {
        let style = BubbleStyle(mine: layout.mine, joinTop: layout.joinTop, joinBottom: layout.joinBottom, tail: tailed)
        return BubbleContent(message: message, style: style, maxWidth: maxBubble,
                             onOpenMedia: onOpenMedia, onJumpTo: onJumpTo)
            .opacity(message.local == .sending && !message.isVisual ? 0.75 : 1)
            .scaleEffect(pressed ? 0.97 : 1, anchor: layout.mine ? .bottomTrailing : .bottomLeading)
            .animation(pressed ? .easeOut(duration: 0.28) : Motion.ui, value: pressed)
            .background(FrameProbe(box: probe))
            .overlay {
                HeartBurst(trigger: burst).allowsHitTesting(false)
            }
            .onTapGesture(count: 2) {
                guard !message.isRevoked, !message.isLocal else { return }
                Haptics.press()
                burst += 1
                if !(message.reactions.first(where: { $0.emoji == "❤️" })?.users.contains(model.me?.id ?? "") ?? false) {
                    Task { await model.react(message, "❤️") }
                }
            }
            .onLongPressGesture(minimumDuration: 0.32, maximumDistance: 12) {
                guard !message.isLocal || message.local == .failed else { return }
                Haptics.press()
                pressed = false
                onLongPress(probe.frame)
            } onPressingChanged: { p in
                pressed = p
            }
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: "Reply") { onReply() }
            .accessibilityAction(named: "React with heart") { Task { await model.react(message, "❤️") } }
            .accessibilityAction(named: "More") { onLongPress(probe.frame) }
    }

    /// A small chip hangs off the bubble's lower edge, on the side away from
    /// its tail, cut from the bubble by a ring of the wallpaper.
    private var reactions: some View {
        let me = model.me?.id ?? ""
        let total = message.reactions.reduce(0) { $0 + $1.users.count }
        let mineAny = message.reactions.contains { $0.users.contains(me) }
        return Button {
            if let r = message.reactions.first(where: { $0.users.contains(me) }) ?? message.reactions.first {
                Task { await model.react(message, r.emoji) }
            }
        } label: {
            HStack(spacing: 1) {
                ForEach(message.reactions.prefix(3), id: \.emoji) { r in
                    Text(r.emoji).font(.system(size: 15))
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
                if total > 1 {
                    Text("\(total)")
                        .font(AppFont.make(11, .semibold).monospacedDigit())
                        .foregroundStyle(Theme.label2)
                        .padding(.leading, 4)
                        .contentTransition(.numericText())
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, total > 1 ? 8 : 6)
            .frame(minHeight: 26)
            .background(Theme.bubbleIn, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.label.opacity(mineAny ? 0.3 : 0), lineWidth: 1.5))
            .background(Capsule().fill(Theme.bg).padding(-2))
            .shadow(color: Theme.bubbleShadow, radius: 0.25, y: 1)
        }
        .buttonStyle(.press(0.92))
        .accessibilityLabel(message.reactions.map { "\($0.emoji) \($0.users.count)" }.joined(separator: ", "))
    }

    private var replySwipe: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { v in
                guard !message.isRevoked, abs(v.translation.width) > abs(v.translation.height) * 1.4, v.translation.width > 0 else { return }
                let t = v.translation.width
                let resisted = t < 56 ? t : 56 + (t - 56) * 0.3
                if swipe <= 56 && resisted > 56 { Haptics.selection() }
                swipe = min(resisted, 90)
            }
            .onEnded { _ in
                if swipe > 56 { onReply() }
                withAnimation(Motion.pressOut) { swipe = 0 }
            }
    }
}

/// The heart from a double tap: rises out of the bubble and dissolves (560ms).
struct HeartBurst: View {
    let trigger: Int

    private struct Frame {
        var scale: CGFloat = 0.3
        var y: CGFloat = 0
        var opacity: Double = 0
        var blur: CGFloat = 0
    }

    var body: some View {
        Text("❤️")
            .font(.system(size: 34))
            .keyframeAnimator(initialValue: Frame(), trigger: trigger) { content, f in
                content
                    .scaleEffect(f.scale)
                    .offset(y: f.y)
                    .opacity(f.opacity)
                    .blur(radius: f.blur)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    CubicKeyframe(1.25, duration: 0.157)
                    CubicKeyframe(1.0, duration: 0.179)
                    CubicKeyframe(0.85, duration: 0.224)
                }
                KeyframeTrack(\.y) {
                    CubicKeyframe(-16, duration: 0.157)
                    CubicKeyframe(-28, duration: 0.179)
                    CubicKeyframe(-52, duration: 0.224)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: 0.157)
                    LinearKeyframe(1, duration: 0.179)
                    LinearKeyframe(0, duration: 0.224)
                }
                KeyframeTrack(\.blur) {
                    LinearKeyframe(0, duration: 0.336)
                    LinearKeyframe(4, duration: 0.224)
                }
            }
    }
}

/// The other person's live text, as it's being written (a dashed outline of
/// a bubble), or three dots while they haven't shared the words.
struct LiveTypingBubble: View {
    @Environment(AppModel.self) private var model
    let uid: String
    let text: String
    var showName = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showName {
                Text(model.name(of: uid)).font(.captionC).foregroundStyle(Theme.label2)
                    .padding(.leading, MessageRow.avatarSize + 10 + 12).padding(.bottom, 2)
            }
            HStack(alignment: .bottom, spacing: 10) {
                Avatar(user: model.user(uid), size: MessageRow.avatarSize)
                Group {
                    if text == "…" || text.isEmpty {
                        TypingDots().padding(.vertical, 9)
                    } else {
                        Text(text)
                            .font(.bodyC)
                            .lineSpacing(BodyMetrics.extra)
                            .foregroundStyle(Theme.bubbleInText.opacity(0.7))
                            .contentTransition(.interpolate)
                            .padding(.vertical, BodyMetrics.extra / 2)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 11)
                .padding(.bottom, 12)
                .background {
                    BubbleShape(mine: false, joinTop: false, joinBottom: false, tail: true)
                        .stroke(Theme.label3.opacity(0.6), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                }
                Spacer(minLength: 40)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 12)
        .animation(Motion.quick, value: text)
    }
}

struct TypingDots: View {
    var color: Color = Theme.label3

    var body: some View {
        PhaseAnimator([0, 1, 2]) { phase in
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(color).frame(width: 7, height: 7)
                        .offset(y: phase == i ? -3 : 1)
                        .opacity(phase == i ? 1 : 0.55)
                }
            }
        } animation: { _ in .easeInOut(duration: 0.3) }
    }
}

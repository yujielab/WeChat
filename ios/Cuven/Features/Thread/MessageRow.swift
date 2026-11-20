import SwiftUI

/// A row in the conversation: built once per render from the messages.
enum ThreadItem: Identifiable {
    case day(id: String, text: String)
    case unread(id: String)
    case message(Message, RowLayout)

    var id: String {
        switch self {
        case .day(let id, _): return id
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
}

enum ThreadBuilder {
    /// Oldest first. Messages from one person within five minutes form a
    /// group; a gap of an hour (or a new day) gets a floating time.
    static func items(_ messages: [Message], me: String?, isGroup: Bool, peerRead: Int, receipts: Bool, unreadFrom: Int?) -> [ThreadItem] {
        var out: [ThreadItem] = []
        var prev: Message?
        let lastMine = messages.last(where: { $0.sender == me && !$0.isSystem })
        var unreadPlaced = false
        for (i, m) in messages.enumerated() {
            let next = i + 1 < messages.count ? messages[i + 1] : nil
            if prev == nil || m.ts - (prev?.ts ?? 0) > 3_600_000 || !Calendar.current.isDate(m.date, inSameDayAs: prev!.date) {
                out.append(.day(id: "d\(m.ts)", text: Fmt.dayStamp(m.date)))
                prev = nil
            }
            if let from = unreadFrom, !unreadPlaced, m.ts > from, m.sender != me, !m.isSystem {
                out.append(.unread(id: "unread"))
                unreadPlaced = true
            }
            if m.isSystem {
                out.append(.message(m, RowLayout(mine: false, joinTop: false, joinBottom: false, showAvatar: false, showName: false, status: nil, failed: false)))
                prev = nil
                continue
            }
            let mine = m.sender == me
            let joinTop = prev.map { $0.sender == m.sender && !$0.isSystem && m.ts - $0.ts < 300_000 } ?? false
            let joinBottom = next.map { $0.sender == m.sender && !$0.isSystem && $0.ts - m.ts < 300_000 && Calendar.current.isDate($0.date, inSameDayAs: m.date) && $0.ts - m.ts <= 3_600_000 } ?? false
            var status: String?
            if mine && m.id == lastMine?.id {
                if m.local == .failed { status = String(localized: "Not sent") }
                else if m.local == .sending { status = String(localized: "Sending…") }
                else if !isGroup && receipts && peerRead >= m.ts { status = String(localized: "Read") }
                else { status = String(localized: "Sent") }
            } else if m.local == .failed {
                status = String(localized: "Not sent")
            }
            out.append(.message(m, RowLayout(mine: mine, joinTop: joinTop, joinBottom: joinBottom,
                                             showAvatar: !joinBottom, showName: isGroup && !mine && !joinTop,
                                             status: status, failed: m.local == .failed)))
            prev = m
        }
        return out
    }
}

struct MessageRow: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let layout: RowLayout
    let width: CGFloat
    var highlighted = false
    var onLongPress: (CGRect) -> Void
    var onReply: () -> Void
    var onOpenMedia: (CGRect) -> Void
    var onJumpTo: (String) -> Void

    @State private var swipe: CGFloat = 0
    @State private var heart = false
    @State private var probe = ProbeBox()

    private var maxBubble: CGFloat { min(width * 0.74, 520) }

    var body: some View {
        if message.isSystem {
            Text(message.body)
                .font(.footnoteC)
                .foregroundStyle(Theme.label2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Theme.fillQuiet.opacity(0.6), in: Capsule())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        } else {
            VStack(alignment: layout.mine ? .trailing : .leading, spacing: 3) {
                if layout.showName {
                    Text(model.name(of: message.sender))
                        .font(.caption2C)
                        .foregroundStyle(Theme.label2)
                        .padding(.leading, 52)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    if layout.mine { Spacer(minLength: 40) }
                    if !layout.mine { avatar }
                    bubble
                    if layout.mine { avatar }
                    if !layout.mine { Spacer(minLength: 40) }
                }
                if !message.reactions.isEmpty {
                    reactions
                        .padding(layout.mine ? .trailing : .leading, 44)
                        .padding(.top, -10)
                        .zIndex(1)
                }
                if let status = layout.status {
                    HStack(spacing: 6) {
                        if layout.failed {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.red)
                            Text(status).foregroundStyle(Theme.redText)
                            Button("Retry") { model.retry(message) }
                                .font(.caption2C.weight(.bold))
                                .foregroundStyle(Theme.blue)
                        } else {
                            Text(status).foregroundStyle(Theme.label3)
                                .contentTransition(.opacity)
                        }
                    }
                    .font(.caption2C)
                    .padding(.trailing, 44)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, layout.joinTop ? 1 : 6)
            .padding(.bottom, layout.joinBottom ? 1 : 2)
            .offset(x: swipe)
            .background(alignment: .leading) {
                if swipe > 10 {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(swipe > 56 ? Theme.blue : Theme.label3)
                        .scaleEffect(swipe > 56 ? 1.15 : 0.9)
                        .padding(.leading, 18)
                        .opacity(Double(min(1, swipe / 56)))
                        .animation(Motion.ui, value: swipe > 56)
                }
            }
            .simultaneousGesture(replySwipe)
            .background(highlighted ? Theme.blue.opacity(0.1) : .clear)
            .animation(Motion.ui, value: highlighted)
        }
    }

    private var avatar: some View {
        Group {
            if layout.showAvatar {
                Avatar(user: model.user(message.sender) ?? User(id: message.sender, display: model.name(of: message.sender)), size: 30)
            } else {
                Color.clear
            }
        }
        .frame(width: 30, height: 30)
    }

    private var bubble: some View {
        let style = BubbleStyle(mine: layout.mine, joinTop: layout.joinTop, joinBottom: layout.joinBottom,
                                tail: !layout.joinBottom && (message.type == "text" || message.type == "voice" || message.type == "call" || message.type == "file"))
        return BubbleContent(message: message, style: style, maxWidth: maxBubble,
                             onOpenMedia: onOpenMedia, onJumpTo: onJumpTo)
            .opacity(message.local == .sending && !message.isVisual ? 0.75 : 1)
            .background(FrameProbe(box: probe))
            .overlay {
                if heart {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.red)
                        .shadow(color: .black.opacity(0.2), radius: 8)
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                }
            }
            .onTapGesture(count: 2) {
                guard !message.isRevoked, !message.isLocal else { return }
                Haptics.press()
                withAnimation(Motion.bouncy) { heart = true }
                Task {
                    try? await Task.sleep(for: .milliseconds(560))
                    withAnimation(.easeOut(duration: 0.2)) { heart = false }
                }
                if !(message.reactions.first(where: { $0.emoji == "❤️" })?.users.contains(model.me?.id ?? "") ?? false) {
                    Task { await model.react(message, "❤️") }
                }
            }
            .onLongPressGesture(minimumDuration: 0.32) {
                guard !message.isLocal || message.local == .failed else { return }
                Haptics.press()
                onLongPress(probe.frame)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: "Reply") { onReply() }
            .accessibilityAction(named: "React with heart") { Task { await model.react(message, "❤️") } }
    }

    private var reactions: some View {
        HStack(spacing: 2) {
            ForEach(message.reactions, id: \.emoji) { r in
                let mineR = r.users.contains(model.me?.id ?? "")
                Button {
                    Task { await model.react(message, r.emoji) }
                } label: {
                    HStack(spacing: 2) {
                        Text(r.emoji).font(.system(size: 14))
                        if r.users.count > 1 { Text("\(r.users.count)").font(.caption2C.monospacedDigit()).foregroundStyle(Theme.label2) }
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                    .background(mineR ? Theme.blue.opacity(0.14) : Theme.elevated, in: Capsule())
                    .overlay(Capsule().stroke(Theme.bg, lineWidth: 2))
                }
                .buttonStyle(.press(0.9))
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(Motion.bouncy, value: message.reactions)
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

/// The other person's live text (Honk style), as it's being written.
struct LiveTypingBubble: View {
    @Environment(AppModel.self) private var model
    let uid: String
    let text: String
    @State private var dots = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Avatar(user: model.user(uid), size: 30)
            Group {
                if text == "…" || text.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(0..<3) { i in
                            Circle().fill(Theme.label3).frame(width: 7, height: 7)
                                .offset(y: dots ? -3 : 2)
                                .animation(.easeInOut(duration: 0.45).repeatForever().delay(Double(i) * 0.15), value: dots)
                        }
                    }
                    .padding(.vertical, 6)
                    .onAppear { dots = true }
                } else {
                    Text(text)
                        .font(.bodyC)
                        .foregroundStyle(Theme.bubbleInText.opacity(0.75))
                        .contentTransition(.interpolate)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background {
                BubbleShape(mine: false, joinTop: false, joinBottom: false, tail: true)
                    .strokeBorderCompat(Theme.label3.opacity(0.5))
            }
            Spacer(minLength: 40)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .animation(Motion.quick, value: text)
    }
}

extension Shape {
    func strokeBorderCompat(_ color: Color) -> some View {
        stroke(color, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
    }
}

import SwiftUI

struct FocusTarget: Equatable {
    var message: Message
    var frame: CGRect
}

/// A conversation: the messages (newest at the bottom, anchored there), a
/// header with who it is, and the composer — all in one column.
struct ThreadView: View {
    let roomId: String
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    @Environment(\.column) private var ctx

    @State private var replyTo: Message?
    @State private var editing: Message?
    @State private var focus: FocusTarget?
    @State private var composerHeight: CGFloat = 80
    @State private var atBottom = true
    @State private var unreadFrom: Int?
    @State private var highlight: String?
    @State private var rootProbe = ProbeBox()
    @State private var headerHeight: CGFloat = 92
    @State private var stickersOpen = false
    @State private var seenCount = 0
    @State private var memo = ThreadRowsMemo()

    private var room: Room? { model.room(roomId) }
    /// The thread's sides: the row's 4pt inside an 18pt margin.
    private var side: CGFloat { 18 }

    var body: some View {
        let msgs = model.messages(roomId)
        let items = rows(msgs)
        let thread = model.threads[roomId]
        let contentWidth = ctx.size.width - ctx.insets.leading - contentTrailing - side * 2

        ZStack {
            Theme.bg

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Room for the composer and what's under it (the keyboard
                        // when it's up), so the newest message rises with them.
                        Color.clear
                            .frame(height: bottomRoom)
                            .id("bottom")
                            .onAppear { atBottom = true; seenCount = msgs.count }
                            .onDisappear { atBottom = false; seenCount = msgs.count }

                        LiveTypers(roomId: roomId, isGroup: room?.isGroup ?? false, side: side)

                        ForEach(items.reversed()) { item in
                            row(item, proxy: proxy, width: contentWidth)
                                .scaleEffect(x: 1, y: -1)
                                .id(item.id)
                                .transition(arrival(item))
                        }

                        if thread?.loading == true && thread?.loaded == true {
                            ProgressView().padding().scaleEffect(x: 1, y: -1)
                        }


                        // At the oldest end: loads more as it comes into view (the
                        // heading's room is the bar below).
                        Color.clear
                            .frame(height: 1)
                            .onAppear {
                                Task { await model.loadOlder(roomId) }
                            }
                    }
                    .padding(.leading, ctx.insets.leading)
                    .padding(.trailing, contentTrailing)
                    .animation(Motion.message, value: msgs.last?.id)
                }
                // The heading's room, as a bar at the list's far end (the top,
                // once flipped): what scrolls under it blurs progressively
                // (the system's soft scroll edge), no gradient, no hard line.
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    Color.clear
                        .frame(height: headerHeight + ctx.insets.top + 8)
                        .allowsHitTesting(false)
                }
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .scaleEffect(x: 1, y: -1)
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .overlay {
                    // Loading, couldn't load (with Retry), or nothing said yet.
                    Group {
                        if msgs.isEmpty && thread?.failed == true {
                            VStack(spacing: 12) {
                                Text("Couldn't load messages").font(.subheadC).foregroundStyle(Theme.label2)
                                PillButton(title: "Retry", style: .blue) { Task { await model.loadThread(roomId) } }
                            }
                            .frame(maxHeight: .infinity)
                        } else if thread?.loaded != true && msgs.isEmpty {
                            ThreadSkeleton()
                                .padding(.top, headerHeight + ctx.insets.top + 20)
                                .frame(maxHeight: .infinity, alignment: .top)
                        } else if msgs.isEmpty && (model.typing[roomId]?.isEmpty ?? true) {
                            conversationStart
                                .padding(.top, headerHeight + ctx.insets.top + 24)
                                .frame(maxHeight: .infinity, alignment: .top)
                        }
                    }
                    .padding(.leading, ctx.insets.leading)
                    .padding(.trailing, contentTrailing)
                    .transition(.opacity)
                }
                .overlay(alignment: .bottom) {
                    if !atBottom {
                        let newCount = max(0, msgs.count - seenCount)
                        // The web's .jump: a round button at the trailing end, clear
                        // of the composer; "↓ New messages" is a pill in the middle.
                        jumpPill(newCount: newCount) {
                            withAnimation(Motion.move) { proxy.scrollTo("bottom", anchor: .top) }
                        }
                        .frame(maxWidth: .infinity, alignment: newCount > 0 ? .center : .trailing)
                        .padding(.horizontal, newCount > 0 ? 0 : side + 2)
                        .padding(.bottom, bottomRoom)
                        .padding(.leading, ctx.insets.leading)
                        .padding(.trailing, contentTrailing)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)).combined(with: .offset(y: 12)))
                    }
                }
                .animation(Motion.ui, value: atBottom)
                .onChange(of: msgs.last?.id) { _, _ in
                    if let last = msgs.last, last.sender == model.me?.id {
                        withAnimation(Motion.quick) { proxy.scrollTo("bottom", anchor: .top) }
                    }
                }
            }


            if let room {
                ThreadHeader(room: room, backBadge: otherUnread)
                    .padding(.top, ctx.insets.top + 20)
                    .padding(.leading, ctx.insets.leading)
                    .padding(.trailing, contentTrailing)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = max(60, $0) }
                    .frame(maxHeight: .infinity, alignment: .top)

                Composer(room: room, replyTo: $replyTo, editing: $editing, stickersOpen: $stickersOpen)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
                    .padding(.bottom, bottomInset)
                    .frame(maxHeight: .infinity, alignment: .bottom)

                // iPhone Duo: Back, then the calls, in the system column under the clock.
                if ctx.usesRail {
                    ColumnBar(back: nav.columns == 1
                                ? BarItem(id: "back", sym: .chevronLeft, title: "Back", badge: otherUnread, badgeInk: true) { nav.backFromChat() }
                                : nil,
                              actions: ThreadHeader.callItems(room: room, model: model))
                }
            }

            if let focus {
                FocusMenu(target: focus, origin: rootProbe.frame.origin, width: ctx.size.width - contentTrailing,
                          onClose: { withAnimation(Motion.morph) { self.focus = nil } },
                          onReply: { m in replyTo = m; editing = nil },
                          onEdit: { m in editing = m; replyTo = nil })
                    .zIndex(10)
                    .transition(.opacity)
            }
        }
        .background(FrameProbe(box: rootProbe))
        // The open conversation, for Siri suggestions and Spotlight's "recent".
        .userActivity(ChatActivity.type) { a in
            a.title = room?.title
            a.userInfo = ["room": roomId]
            a.targetContentIdentifier = roomId
            a.isEligibleForPrediction = true
            a.isEligibleForSearch = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .automationFocus)) { _ in
            // Lift the latest message from the other side, as a long press would.
            if let m = model.messages(roomId).last(where: { $0.sender != model.me?.id && $0.type == "text" }) {
                let w = ctx.size.width
                let frame = CGRect(x: rootProbe.frame.minX + 64, y: rootProbe.frame.minY + ctx.size.height * 0.55, width: min(260, w * 0.6), height: 47)
                withAnimation(Motion.morph) { focus = FocusTarget(message: m, frame: frame) }
            }
        }
        .sheet(isPresented: $stickersOpen) {
            StickerPanel(roomId: roomId, replyTo: $replyTo)
                // The sheet runs across the Duo's system column; so do the
                // packs, rather than stopping short and leaving a strip.
                .ignoresSafeArea(.container, edges: ctx.usesRail ? .trailing : [])
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task {
            if let r = room, r.unread > 0 { unreadFrom = r.lastRead }
            await model.loadThread(roomId)
            if nav.isVisible(.chat) { model.markRead(roomId) }
        }
    }

    /// Content runs up to the rail (and the system's column) on the Duo.
    private var contentTrailing: CGFloat {
        guard ctx.usesRail, let rail = ctx.rail else { return ctx.insets.trailing }
        return max(ctx.insets.trailing, rail.centerFromEdge + Bar.railWidth / 2 + 12)
    }

    private var otherUnread: Int {
        model.rooms.filter { $0.id != roomId && !$0.muted }.reduce(0) { $0 + $1.unread }
    }

    /// The rows, built again only when what they're built from changes (not
    /// for the composer growing, the keyboard, or another room's news).
    private func rows(_ msgs: [Message]) -> [ThreadItem] {
        let key = ThreadRowsKey(msgs: msgs, me: model.me?.id, isGroup: room?.isGroup ?? false,
                                peerRead: room?.peerRead ?? 0, peerReadAt: room?.peerReadAt ?? 0,
                                receipts: model.prefs.receipts, unreadFrom: unreadFrom,
                                today: Calendar.current.startOfDay(for: Date()),
                                clock: UserDefaults.standard.string(forKey: "ui:time-format"))
        if memo.key != key {
            memo.items = ThreadBuilder.items(msgs, me: key.me, isGroup: key.isGroup,
                                             peerRead: key.peerRead, peerReadAt: key.peerReadAt,
                                             receipts: key.receipts, unreadFrom: key.unreadFrom)
            memo.key = key
        }
        return memo.items
    }

    /// max(safe-bottom, 16) at the foot; 8 above the keyboard.
    private var bottomInset: CGFloat {
        ctx.keyboard > 0 ? ctx.insets.bottom + 8 : max(ctx.insets.bottom, 16)
    }

    /// From the bottom of the screen to just above the composer.
    private var bottomRoom: CGFloat { composerHeight + bottomInset + 12 }

    /// What you send rises from the field; what arrives slides in from their side.
    private func arrival(_ item: ThreadItem) -> AnyTransition {
        if case .message(_, let layout) = item {
            return .asymmetric(
                insertion: .offset(x: layout.mine ? 0 : -14, y: layout.mine ? 18 : 6)
                    .combined(with: .scale(scale: layout.mine ? 0.94 : 0.98, anchor: layout.mine ? .bottomTrailing : .bottomLeading))
                    .combined(with: .opacity),
                removal: .opacity)
        }
        return .opacity
    }

    @ViewBuilder
    private func row(_ item: ThreadItem, proxy: ScrollViewProxy, width: CGFloat) -> some View {
        switch item {
        case .mark(_, let day, let time):
            TimeMark(day: day, time: time).padding(.horizontal, side)
        case .unread:
            UnreadDivider().padding(.horizontal, side)
        case .message(let m, let layout):
            MessageRow(message: m, layout: layout, width: width,
                       highlighted: highlight == m.id,
                       onLongPress: { frame in
                           withAnimation(Motion.morph) { focus = FocusTarget(message: m, frame: frame) }
                       },
                       onReply: {
                           withAnimation(Motion.ui) { replyTo = m; editing = nil }
                           Haptics.tap()
                       },
                       onOpenMedia: { frame in
                           guard let url = m.meta?.url else { return }
                           withAnimation(Motion.morph) {
                               nav.viewer = ViewerItem(path: url, aspect: m.meta?.aspect ?? 1, source: frame, isVideo: m.type == "video")
                           }
                       },
                       onJumpTo: { id in
                           withAnimation(Motion.move) { proxy.scrollTo(id, anchor: .center) }
                           highlight = id
                           Task {
                               try? await Task.sleep(for: .seconds(0.9))
                               if highlight == id { highlight = nil }
                           }
                       })
                .equatable()
                .padding(.horizontal, side)
        }
    }

    /// "↓ New messages 3": a 36pt glass capsule; a round ↓ when nothing's new.
    private func jumpPill(newCount: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                SymbolView(.chevronDown, size: 15, weight: 2.2)
                if newCount > 0 {
                    Text("New messages").font(.subheadBoldC)
                    Text("\(newCount)")
                        .font(.captionC.monospacedDigit())
                        .foregroundStyle(Theme.onBrand)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Theme.badge, in: Capsule())
                }
            }
            .foregroundStyle(Theme.label)
            .padding(.horizontal, newCount > 0 ? 14 : 0)
            .frame(minWidth: newCount > 0 ? 36 : 44, minHeight: newCount > 0 ? 36 : 44)
            .glassCapsule()
            .contentShape(Capsule().inset(by: -4))
        }
        .buttonStyle(.press(0.94))
        .accessibilityLabel(newCount > 0 ? "\(newCount) new messages" : "Jump to latest")
    }

    private var conversationStart: some View {
        VStack(spacing: 8) {
            if let room {
                Avatar(path: room.avatar, name: room.title, id: room.peer?.id ?? room.id, size: 72, room: room.isGroup)
                Text(room.title).font(.title3C).foregroundStyle(Theme.label)
                Text(room.isGroup ? String(localized: "This is the start of the group") : String(localized: "This is the start of your conversation"))
                    .font(.footnoteC).foregroundStyle(Theme.label2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

/// What a thread's rows are built from. The marks also name the day
/// ("Today") and follow Settings › Time format, so those are in it too.
struct ThreadRowsKey: Equatable {
    var msgs: [Message]
    var me: String?
    var isGroup: Bool
    var peerRead: Int
    var peerReadAt: Int
    var receipts: Bool
    var unreadFrom: Int?
    var today: Date
    var clock: String?
}

/// The rows last built, and from what (kept across body runs, never observed).
final class ThreadRowsMemo {
    var key: ThreadRowsKey?
    var items: [ThreadItem] = []
}

/// Who's writing right now, live: its own view, so their keystrokes (in
/// this room or any other) redraw these bubbles, not the whole conversation.
/// Someone new is let in through `shown` inside an animation, so the rows
/// above slide up with their bubble (an `.animation` on these bubbles alone
/// would leave the rows to jump); someone gone leaves at once, in the same
/// update as the message they sent.
struct LiveTypers: View {
    @Environment(AppModel.self) private var model
    let roomId: String
    let isGroup: Bool
    let side: CGFloat
    /// Who's been let in.
    @State private var shown: Set<String> = []

    var body: some View {
        let live = model.typing[roomId] ?? [:]
        let typers = live.filter { shown.contains($0.key) }.sorted { $0.key < $1.key }
        VStack(spacing: 0) {
            ForEach(typers, id: \.key) { t in
                LiveTypingBubble(uid: t.key, text: t.value.text, showName: isGroup)
                    .padding(.horizontal, side)
                    .scaleEffect(x: 1, y: -1)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomLeading)))
            }
        }
        .animation(Motion.quick, value: typers.map(\.key))
        .onChange(of: Set(live.keys), initial: true) { old, now in
            if old != now && !now.isSubset(of: shown) {
                withAnimation(Motion.quick) { shown = now }
            } else {
                shown = now
            }
        }
    }
}

// MARK: - Heading

/// Their photo large in the middle with their name on a white pill over its
/// foot (how they are after a dot); tapping either opens the details. Back at
/// the top-leading corner and the call at the top-trailing one, where iOS
/// puts them (in the rail on the Duo).
struct ThreadHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    @Environment(\.column) private var ctx
    let room: Room
    /// Unread elsewhere, on the Back button.
    var backBadge = 0

    private var sub: String? {
        if let t = model.typing[room.id], !t.isEmpty { return String(localized: "typing…") }
        if room.isGroup { return room.count > 0 ? String(localized: "\(room.count) members") : nil }
        if model.isOnline(room.peer?.id) { return String(localized: "Active now") }
        return nil
    }

    var body: some View {
        let typing = !(model.typing[room.id]?.isEmpty ?? true)
        ZStack(alignment: .top) {
            if !ctx.usesRail {
                HStack(spacing: 0) {
                    if nav.columns == 1 {
                        GlassIconButton(sym: .chevronLeft, title: "Back", badge: backBadge, badgeInk: true) { nav.backFromChat() }
                    }
                    Spacer(minLength: 0)
                    if model.callsEnabled {
                        // One call button, asking voice or video: a slip can't dial.
                        Menu {
                            ForEach(Self.callItems(room: room, model: model)) { item in
                                Button(action: item.action) {
                                    Label(item.title, systemImage: item.id == "video" ? "video" : "phone")
                                }
                            }
                        } label: {
                            SymbolView(.phone, size: 21)
                                .foregroundStyle(Theme.label)
                                .frame(width: 44, height: 44)
                                .glassCircle()
                        }
                        .accessibilityLabel("Call")
                    }
                }
                .padding(.top, 7)
                .padding(.horizontal, 16)
            }

            VStack(spacing: -10) {
                Button { nav.show(.info) } label: {
                    Avatar(path: room.avatar, name: room.title, id: room.peer?.id ?? room.id, size: 58, room: room.isGroup,
                           online: !room.isGroup && model.isOnline(room.peer?.id))
                        .background(Circle().fill(Theme.elevated).padding(-3).opacity(room.isGroup ? 0 : 1))
                        .shadow(color: .black.opacity(0.22), radius: 12, y: 10)
                }
                .buttonStyle(.press(0.96))
                .accessibilityHidden(true)

                Button { nav.show(.info) } label: {
                    HStack(spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(room.title)
                                .font(AppFont.make(15, .bold))
                                .foregroundStyle(Theme.label)
                                .lineLimit(1)
                            if let sub {
                                Text("· " + sub)
                                    .font(AppFont.make(11, .regular))
                                    .foregroundStyle(typing ? Theme.blueText : Theme.label2)
                                    .lineLimit(1)
                                    .layoutPriority(-1)
                                    .transition(.opacity)
                            }
                        }
                        .padding(.leading, 12)
                        .padding(.trailing, 4)
                        .padding(.top, 5)
                        .padding(.bottom, 6)
                        SymbolView(.info, size: 18)
                            .foregroundStyle(Theme.blue)
                            .padding(.leading, 3)
                            .padding(.trailing, 9)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Capsule())
                }
                .buttonStyle(.press(0.96))
                .accessibilityLabel(Text(room.title))
                .accessibilityHint("Chat info")
                .background(Theme.elevated, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
                .shadow(color: .black.opacity(0.16), radius: 8, y: 6)
                .zIndex(1)
            }
            .frame(maxWidth: min(260, ctx.size.width * 0.54))
        }
        .padding(.bottom, 8)
        .animation(Motion.quick, value: sub)
    }

    /// The calls: a capsule of two, voice then video.
    static func callItems(room: Room, model: AppModel) -> [BarItem] {
        guard model.callsEnabled else { return [] }
        return [
            BarItem(id: "audio", sym: .phone, title: "Voice call") { model.calls.start(room: room, video: false) },
            BarItem(id: "video", sym: .video, title: "Video call") { model.calls.start(room: room, video: true) }
        ]
    }
}

struct ThreadSkeleton: View {
    var body: some View {
        VStack(spacing: 14) {
            ForEach(0..<6, id: \.self) { i in
                HStack {
                    if i % 2 == 0 { Spacer() }
                    RoundedRectangle(cornerRadius: 23, style: .continuous)
                        .fill(Theme.fill4)
                        .frame(width: CGFloat([180, 120, 220, 90, 160, 200][i]), height: i == 2 ? 72 : 47)
                    if i % 2 == 1 { Spacer() }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .allowsHitTesting(false)
    }
}

/// The list's long-press preview: the last few messages, as they read.
struct ThreadPreview: View {
    @Environment(AppModel.self) private var model
    let roomId: String

    var body: some View {
        let msgs = Array(model.messages(roomId).suffix(8))
        let room = model.room(roomId)
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Avatar(path: room?.avatar ?? "", name: room?.title ?? "", id: room?.peer?.id ?? roomId, size: 32)
                Text(room?.title ?? "").font(.headlineC)
                Spacer()
            }
            .padding(.bottom, 6)
            if msgs.isEmpty {
                Text(room?.last?.preview ?? "").font(.subheadC).foregroundStyle(Theme.label2).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(msgs) { m in
                let mine = m.sender == model.me?.id
                HStack {
                    if mine { Spacer(minLength: 30) }
                    Text(m.preview)
                        .font(.subheadC)
                        .foregroundStyle(mine ? .white : Theme.bubbleInText)
                        .lineLimit(3)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(mine ? Theme.bubbleOut : Theme.bubbleIn, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    if !mine { Spacer(minLength: 30) }
                }
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(Theme.bg)
    }
}

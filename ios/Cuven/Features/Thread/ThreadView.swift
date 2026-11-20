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

    private var room: Room? { model.room(roomId) }
    /// The thread's sides: the row's 4pt inside an 18pt margin.
    private var side: CGFloat { 18 }

    var body: some View {
        let msgs = model.messages(roomId)
        let items = ThreadBuilder.items(msgs, me: model.me?.id, isGroup: room?.isGroup ?? false,
                                        peerRead: room?.peerRead ?? 0, peerReadAt: room?.peerReadAt ?? 0,
                                        receipts: model.prefs.receipts, unreadFrom: unreadFrom)
        let typers = (model.typing[roomId] ?? [:]).sorted { $0.key < $1.key }
        let thread = model.threads[roomId]
        let contentWidth = ctx.size.width - ctx.insets.leading - contentTrailing - side * 2

        ZStack {
            Theme.bg

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        Color.clear
                            .frame(height: composerHeight + 12)
                            .id("bottom")
                            .onAppear { atBottom = true; seenCount = msgs.count }
                            .onDisappear { atBottom = false; seenCount = msgs.count }

                        ForEach(typers, id: \.key) { t in
                            LiveTypingBubble(uid: t.key, text: t.value.text, showName: room?.isGroup ?? false)
                                .padding(.horizontal, side)
                                .scaleEffect(x: 1, y: -1)
                                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomLeading)))
                        }

                        ForEach(items.reversed()) { item in
                            row(item, proxy: proxy, width: contentWidth)
                                .scaleEffect(x: 1, y: -1)
                                .id(item.id)
                                .transition(arrival(item))
                        }

                        if thread?.loading == true && thread?.loaded == true {
                            ProgressView().padding().scaleEffect(x: 1, y: -1)
                        }


                        Color.clear
                            .frame(height: headerHeight + ctx.insets.top + 8)
                            .onAppear {
                                Task { await model.loadOlder(roomId) }
                            }
                    }
                    .padding(.leading, ctx.insets.leading)
                    .padding(.trailing, contentTrailing)
                    .animation(Motion.message, value: msgs.last?.id)
                    .animation(Motion.quick, value: typers.map(\.key))
                }
                .scaleEffect(x: 1, y: -1)
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .overlay {
                    if thread?.loaded != true && msgs.isEmpty {
                        ThreadSkeleton()
                            .padding(.top, headerHeight + ctx.insets.top + 20)
                            .padding(.leading, ctx.insets.leading)
                            .padding(.trailing, contentTrailing)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .bottom) {
                    if !atBottom {
                        jumpPill(newCount: max(0, msgs.count - seenCount)) {
                            withAnimation(Motion.move) { proxy.scrollTo("bottom", anchor: .top) }
                        }
                        .padding(.bottom, composerHeight + 12)
                        .padding(.leading, ctx.insets.leading)
                        .padding(.trailing, contentTrailing)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)).combined(with: .offset(y: 8)))
                    }
                }
                .animation(Motion.ui, value: atBottom)
                .onChange(of: msgs.last?.id) { _, _ in
                    if let last = msgs.last, last.sender == model.me?.id {
                        withAnimation(Motion.quick) { proxy.scrollTo("bottom", anchor: .top) }
                    }
                }
            }

            // The top fades the messages out under the heading.
            VStack(spacing: 0) {
                LinearGradient(stops: [.init(color: Theme.bg, location: 0), .init(color: Theme.bg.opacity(0.94), location: 0.55),
                                       .init(color: Theme.bg.opacity(0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: headerHeight + ctx.insets.top + 18)
                Spacer()
            }
            .allowsHitTesting(false)

            if let room {
                ThreadHeader(room: room)
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

    /// max(safe-bottom, 16) at the foot; 8 above the keyboard.
    private var bottomInset: CGFloat {
        ctx.keyboard > 0 ? ctx.insets.bottom + 8 : max(ctx.insets.bottom, 16)
    }

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
            .frame(minWidth: 36, minHeight: 36)
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

// MARK: - Heading

/// Their photo large in the middle with their name on a white pill over its
/// foot (how they are after a dot), then the details' (i) in blue; the
/// calls at the start of the row (in the rail on the Duo).
struct ThreadHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    @Environment(\.column) private var ctx
    let room: Room

    private var sub: String? {
        if let t = model.typing[room.id], !t.isEmpty { return String(localized: "typing…") }
        if room.isGroup { return room.count > 0 ? String(localized: "\(room.count) members") : nil }
        if model.isOnline(room.peer?.id) { return String(localized: "Active now") }
        return nil
    }

    var body: some View {
        let typing = !(model.typing[room.id]?.isEmpty ?? true)
        ZStack(alignment: .top) {
            if !ctx.usesRail && model.callsEnabled {
                HStack(spacing: 0) {
                    ForEach(Self.callItems(room: room, model: model)) { item in
                        Button {
                            Haptics.tap()
                            item.action()
                        } label: {
                            SymbolView(item.sym, size: 22)
                                .foregroundStyle(Theme.label)
                                .frame(width: 46, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.press(0.9))
                        .accessibilityLabel(Text(item.title))
                    }
                }
                .padding(.horizontal, 3)
                .glassCapsule()
                .padding(.top, 7)
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: -10) {
                Button {
                    if let peer = room.peer, !room.isGroup { nav.profile = peer.id } else { nav.show(.info) }
                } label: {
                    Avatar(path: room.avatar, name: room.title, id: room.peer?.id ?? room.id, size: 58, room: room.isGroup,
                           online: !room.isGroup && model.isOnline(room.peer?.id))
                        .background(Circle().fill(Theme.elevated).padding(-3).opacity(room.isGroup ? 0 : 1))
                        .shadow(color: .black.opacity(0.22), radius: 12, y: 10)
                }
                .buttonStyle(.press(0.96))
                .accessibilityLabel(Text(room.title))

                HStack(spacing: 0) {
                    Button {
                        if let peer = room.peer, !room.isGroup { nav.profile = peer.id } else { nav.show(.info) }
                    } label: {
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
                    }
                    .buttonStyle(.plain)
                    Button { nav.show(.info) } label: {
                        SymbolView(.info, size: 18)
                            .foregroundStyle(Theme.fbBlue)
                            .padding(.leading, 3)
                            .padding(.trailing, 9)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle().inset(by: -6))
                    }
                    .buttonStyle(.press(0.9))
                    .accessibilityLabel("Chat info")
                }
                .fixedSize(horizontal: false, vertical: true)
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

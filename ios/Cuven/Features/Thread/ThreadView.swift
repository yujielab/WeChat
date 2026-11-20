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
    @State private var composerHeight: CGFloat = 64
    @State private var atBottom = true
    @State private var unreadFrom: Int?
    @State private var highlight: String?
    @State private var rootProbe = ProbeBox()
    @State private var headerHeight: CGFloat = 110
    @State private var stickersOpen = false

    private var room: Room? { model.room(roomId) }

    var body: some View {
        let msgs = model.messages(roomId)
        let items = ThreadBuilder.items(msgs, me: model.me?.id, isGroup: room?.isGroup ?? false,
                                        peerRead: room?.peerRead ?? 0, receipts: true, unreadFrom: unreadFrom)
        let typers = (model.typing[roomId] ?? [:]).sorted { $0.key < $1.key }
        let thread = model.threads[roomId]

        ZStack {
            Theme.bg

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        Color.clear
                            .frame(height: composerHeight + bottomInset + 10)
                            .id("bottom")
                            .onAppear { atBottom = true }
                            .onDisappear { atBottom = false }

                        ForEach(typers, id: \.key) { t in
                            LiveTypingBubble(uid: t.key, text: t.value.text)
                                .scaleEffect(x: 1, y: -1)
                                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomLeading)))
                        }

                        ForEach(items.reversed()) { item in
                            row(item, proxy: proxy)
                                .scaleEffect(x: 1, y: -1)
                                .id(item.id)
                                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                        }

                        if thread?.loading == true && thread?.loaded == true {
                            ProgressView().padding().scaleEffect(x: 1, y: -1)
                        }

                        if thread?.loaded == true && thread?.hasMore == false {
                            conversationStart.scaleEffect(x: 1, y: -1)
                        }

                        Color.clear
                            .frame(height: headerHeight + ctx.insets.top + 8)
                            .onAppear {
                                Task { await model.loadOlder(roomId) }
                            }
                    }
                    .animation(.smooth(duration: 0.28), value: msgs.last?.id)
                    .animation(Motion.quick, value: typers.map(\.key))
                }
                .scaleEffect(x: 1, y: -1)
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .overlay {
                    if thread?.loaded != true && msgs.isEmpty {
                        ThreadSkeleton().padding(.top, headerHeight + ctx.insets.top)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !atBottom {
                        Button {
                            withAnimation(Motion.move) { proxy.scrollTo("bottom", anchor: .top) }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(Theme.label)
                                .frame(width: 44, height: 44)
                                .glassCircle()
                                .overlay(alignment: .topTrailing) {
                                    if let r = room, r.unread > 0 { Badge(count: r.unread).offset(x: 6, y: -6) }
                                }
                        }
                        .buttonStyle(.press(0.9))
                        .padding(.trailing, ctx.insets.trailing + 16)
                        .padding(.bottom, composerHeight + bottomInset + 14)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityLabel("Jump to latest")
                    }
                }
                .onChange(of: msgs.last?.id) { _, _ in
                    if let last = msgs.last, last.sender == model.me?.id {
                        withAnimation(Motion.quick) { proxy.scrollTo("bottom", anchor: .top) }
                    }
                }
            }

            // The top fades the messages out under the header.
            VStack(spacing: 0) {
                LinearGradient(colors: [Theme.bg, Theme.bg.opacity(0.92), Theme.bg.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: headerHeight + ctx.insets.top + 10)
                Spacer()
            }
            .allowsHitTesting(false)

            if let room {
                ThreadHeader(room: room)
                    .padding(.top, ctx.insets.top)
                    .padding(.leading, ctx.insets.leading)
                    .padding(.trailing, ctx.insets.trailing)
                    .background(GeometryReader { g in Color.clear.preference(key: HeaderHeightKey.self, value: g.size.height - ctx.insets.top) })
                    .frame(maxHeight: .infinity, alignment: .top)

                Composer(room: room, replyTo: $replyTo, editing: $editing, stickersOpen: $stickersOpen)
                    .background(GeometryReader { g in Color.clear.preference(key: ComposerHeightKey.self, value: g.size.height) })
                    .padding(.bottom, bottomInset)
                    .frame(maxHeight: .infinity, alignment: .bottom)

                // iPhone Duo: back, calls and info stand in the system column, top to bottom.
                if ctx.usesRail {
                    ColumnBar(back: nav.columns == 1 ? BarItem(id: "back", symbol: "chevron.left", title: "Back") { nav.backFromChat() } : nil,
                              actions: ThreadHeader.railActions(room: room, model: model, nav: nav))
                }
            }

            if let focus {
                FocusMenu(target: focus, origin: rootProbe.frame.origin, width: ctx.size.width,
                          onClose: { withAnimation(Motion.morph) { self.focus = nil } },
                          onReply: { m in replyTo = m; editing = nil },
                          onEdit: { m in editing = m; replyTo = nil })
                    .zIndex(10)
                    .transition(.opacity)
            }
        }
        .background(FrameProbe(box: rootProbe))
        .onPreferenceChange(ComposerHeightKey.self) { composerHeight = $0 }
        .onPreferenceChange(HeaderHeightKey.self) { headerHeight = max(60, $0) }
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

    private var bottomInset: CGFloat {
        ctx.insets.bottom > 0 ? ctx.insets.bottom + (ctx.insets.bottom > 40 ? 6 : 2) : 12
    }

    @ViewBuilder
    private func row(_ item: ThreadItem, proxy: ScrollViewProxy) -> some View {
        switch item {
        case .day(_, let text):
            Text(text)
                .font(.caption2C)
                .foregroundStyle(Theme.label2)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Theme.bg.opacity(0.9), in: Capsule())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        case .unread:
            HStack(spacing: 10) {
                Rectangle().fill(Theme.blue.opacity(0.35)).frame(height: 1)
                Text("New messages").font(.caption2C.weight(.semibold)).foregroundStyle(Theme.blue)
                Rectangle().fill(Theme.blue.opacity(0.35)).frame(height: 1)
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
        case .message(let m, let layout):
            MessageRow(message: m, layout: layout, width: ctx.size.width - ctx.insets.leading - ctx.insets.trailing,
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
                               try? await Task.sleep(for: .seconds(1.4))
                               if highlight == id { highlight = nil }
                           }
                       })
                .padding(.leading, ctx.insets.leading)
                .padding(.trailing, ctx.insets.trailing)
        }
    }

    private var conversationStart: some View {
        VStack(spacing: 8) {
            if let room {
                Avatar(path: room.avatar, name: room.title, id: room.peer?.id ?? room.id, size: 72)
                Text(room.title).font(.title3C)
                Text(room.isGroup ? String(localized: "This is the start of the group") : String(localized: "This is the start of your conversation"))
                    .font(.footnoteC).foregroundStyle(Theme.label2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

private struct ComposerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 64
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct HeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 110
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Header

struct ThreadHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    @Environment(\.column) private var ctx
    let room: Room

    private var status: String? {
        if room.isGroup { return room.count > 0 ? String(localized: "\(room.count) members") : nil }
        if model.isOnline(room.peer?.id) { return String(localized: "Online") }
        if let t = model.typing[room.id], !t.isEmpty { return String(localized: "typing…") }
        return nil
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Calls (on phones without the Duo side column)
            if !ctx.usesRail && model.callsEnabled {
                HStack {
                    Spacer()
                    HStack(spacing: 0) {
                        callButton(video: false)
                        callButton(video: true)
                    }
                    .padding(.horizontal, 2)
                    .glassCapsule()
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
            }

            VStack(spacing: -12) {
                Button {
                    if let peer = room.peer, !room.isGroup { nav.profile = peer.id } else { nav.show(.info) }
                } label: {
                    Avatar(path: room.avatar, name: room.title, id: room.peer?.id ?? room.id, size: 58,
                           online: !room.isGroup && model.isOnline(room.peer?.id))
                }
                .buttonStyle(.press(0.94))
                .accessibilityLabel(Text(room.title))

                Button { nav.show(.info) } label: {
                    HStack(spacing: 6) {
                        Text(room.title).font(.headlineC).foregroundStyle(Theme.label).lineLimit(1)
                        if !ctx.usesRail {
                            Image(systemName: "info.circle").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.blue)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .glassCapsule()
                }
                .buttonStyle(.press(0.96))
                .accessibilityLabel("Chat info")
            }
            .padding(.top, 6)
            .frame(maxWidth: ctx.usesRail ? .infinity : 260)

            if let status {
                Text(status)
                    .font(.caption2C)
                    .foregroundStyle(status == String(localized: "Online") ? Theme.green : Theme.label2)
                    .padding(.top, 6 + 58 - 12 + 32 + 4)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, 18)
        .animation(Motion.quick, value: status)
    }

    static func railActions(room: Room, model: AppModel, nav: Nav) -> [BarItem] {
        var a: [BarItem] = []
        if model.callsEnabled {
            a.append(BarItem(id: "call", symbol: "phone.fill", title: "Voice call") { model.calls.start(room: room, video: false) })
            a.append(BarItem(id: "video", symbol: "video.fill", title: "Video call") { model.calls.start(room: room, video: true) })
        }
        a.append(BarItem(id: "info", symbol: "info", title: "Chat info", foreground: Theme.blue) { nav.show(.info) })
        return a
    }

    private func callButton(video: Bool) -> some View {
        Button {
            Haptics.tap()
            model.calls.start(room: room, video: video)
        } label: {
            Image(systemName: video ? "video" : "phone")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.label)
                .frame(width: 46, height: 42)
        }
        .buttonStyle(.press(0.9))
        .accessibilityLabel(video ? "Video call" : "Voice call")
    }
}

struct ThreadSkeleton: View {
    var body: some View {
        VStack(spacing: 14) {
            ForEach(0..<6, id: \.self) { i in
                HStack {
                    if i % 2 == 0 { Spacer() }
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Theme.fillQuiet)
                        .frame(width: CGFloat([180, 120, 220, 90, 160, 200][i]), height: i == 2 ? 60 : 38)
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

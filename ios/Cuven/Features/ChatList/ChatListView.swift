import SwiftUI

/// The Messages list (views/chatList.js, css/list.css).
struct ChatListView: View {
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    @Environment(\.column) private var ctx
    @State private var query = ""
    @State private var found: [User] = []
    @FocusState private var searchFocused: Bool
    /// The search button and the search field are one piece of glass.
    @Namespace private var searchGlass

    /// Unfolded, the list leads a window: it drops its filters for a button in its bar.
    private var leadingTwoUp: Bool { ctx.twoUp && !ctx.isRightmost }
    /// The open Duo (the system's column beside the other pane): the list's
    /// search and filter sit at the top of its own pane, as in Mail, rather
    /// than in a bar at its foot.
    private var listControlsOnTop: Bool { leadingTwoUp && ctx.systemColumn }
    private var besideSidebar: Bool { nav.columns == 2 && nav.leading == .sidebar }
    private var inset: CGFloat { 22 }

    private var filtered: [Room] {
        var list = model.rooms
        switch nav.filter {
        case .all: break
        case .unread: list = list.filter { $0.unread > 0 || $0.marked }
        case .direct: list = list.filter { !$0.isGroup }
        case .groups: list = list.filter { $0.isGroup }
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { $0.title.lowercased().contains(q) || ($0.last?.body.lowercased().contains(q) ?? false) || ($0.peer?.username.lowercased().contains(q) ?? false) }
        }
        return list
    }

    var body: some View {
        ZStack {
            Theme.bg
            List {
                if !nav.searching && !besideSidebar {
                    NotesRow()
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 4, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    if leadingTwoUp {
                        requestsLink.frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.trailing, inset)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 6, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    } else {
                        FilterTabs(requests: requestsLink)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }

                if nav.searching && query.isEmpty {
                    Text("RECENT")
                        .font(AppFont.make(12, .medium)).tracking(0.96)
                        .foregroundStyle(Theme.label2)
                        .padding(.horizontal, inset - 6)
                        .listRowInsets(EdgeInsets(top: 10, leading: 6, bottom: 4, trailing: 6))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }

                ForEach(filtered) { room in
                    rowView(room)
                }

                if filtered.isEmpty && !nav.searching {
                    emptyState.listRowSeparator(.hidden).listRowBackground(Color.clear)
                }

                if nav.searching && !found.isEmpty {
                    Text("PEOPLE")
                        .font(AppFont.make(12, .medium)).tracking(0.96)
                        .foregroundStyle(Theme.label2)
                        .padding(.horizontal, inset - 6)
                        .listRowInsets(EdgeInsets(top: 14, leading: 6, bottom: 4, trailing: 6))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    ForEach(found) { u in
                        PersonRow(user: u)
                            .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }

                if !nav.searching && nav.filter == .all && !besideSidebar {
                    PeopleSections()
                        .listRowInsets(EdgeInsets(top: 18, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // The title (or the search field) floats at the top, the list
            // scrolling on under it through the system's soft edge.
            .safeAreaBar(edge: .top, spacing: 0) {
                // Search opens out of its button: the circle's glass grows into
                // the field, and folds back when it's done (HIG: Liquid Glass morphs).
                GlassGroup(spacing: 0) {
                    Group {
                        if nav.searching { searchHead } else { header }
                    }
                }
                .padding(.bottom, nav.searching ? 6 : 4)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .environment(\.defaultMinListRowHeight, 1)
            .safeAreaPadding(EdgeInsets(top: ctx.insets.top, leading: ctx.insets.leading, bottom: ctx.contentBottom,
                                        trailing: ctx.usesRail ? ctx.insets.trailing + 10 : ctx.insets.trailing))
            .refreshable {
                await model.refreshRooms()
                await model.loadNotes()
                await model.loadPeople()
            }
            .animation(Motion.ui, value: nav.searching)

            bars
        }
        .task(id: query) {
            guard nav.searching, !query.isEmpty else { found = []; return }
            try? await Task.sleep(for: .milliseconds(280))
            let res = await model.searchUsers(query)
            if !Task.isCancelled { withAnimation(Motion.ui) { found = res } }
        }
        .onChange(of: nav.searching) { _, on in
            if on { searchFocused = true } else { query = ""; searchFocused = false }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(besideSidebar ? nav.filter.title : "Messages")
                .font(ctx.twoUp ? .title1C : .largeTitleC)
                .tracking(-0.68)
                .foregroundStyle(Theme.fbBlueTitle)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            if (ctx.usesRail && !leadingTwoUp) || listControlsOnTop {
                // Search beside the title, in blue glass, as tall as it.
                Button {
                    Haptics.tap()
                    withAnimation(Motion.ui) { nav.searching = true }
                } label: {
                    SymbolView(.search, size: 18, weight: 2.4)
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .glass(Circle(), tint: Theme.fbBlue.opacity(0.8), interactive: true, morph: "search", in: searchGlass)
                }
                .buttonStyle(.press(0.94))
                .accessibilityLabel("Search")
            }
            if !ctx.usesRail && !leadingTwoUp {
                // Moments, beside the title where there's no page capsule.
                Button {
                    model.momentsDot = false
                    nav.switchPage(.moments)
                } label: {
                    SymbolView(.photo, size: 20)
                        .foregroundStyle(Theme.label)
                        .frame(width: 44, height: 44)
                        .glassCircle()
                        .overlay(alignment: .topTrailing) {
                            if model.momentsDot { Circle().fill(Theme.red).frame(width: 9, height: 9).offset(x: -4, y: 4) }
                        }
                }
                .buttonStyle(.press)
                .accessibilityLabel("Moments")
            }
            if listControlsOnTop {
                // The list's filter, with the list it filters (HIG: controls
                // near the content they affect, at the top of the pane).
                Button {
                    Haptics.tap()
                    withAnimation(Motion.bouncy) { nav.filterCard = .list }
                } label: {
                    SymbolView(.filter, size: 18)
                        .foregroundStyle(nav.filter == .all ? Theme.label : .white)
                        .frame(width: 40, height: 40)
                        .glassCircle(tint: nav.filter == .all ? nil : Theme.fbBlue.opacity(0.8))
                }
                .buttonStyle(.press(0.94))
                .accessibilityLabel("Filter")
            }
            if leadingTwoUp || (!ctx.usesRail && ctx.rail == nil && ctx.twoUp) {
                Button { withAnimation(Motion.move) { nav.settingsOpen = true } } label: {
                    Avatar(user: model.me, size: 40)
                }
                .buttonStyle(.press(0.94))
                .accessibilityLabel("Settings")
            }
        }
        .padding(.leading, inset)
        .padding(.trailing, inset)
        .padding(.top, 24)
    }

    private var searchHead: some View {
        HStack(spacing: 8) {
            SymbolView(.search, size: 17).foregroundStyle(Theme.label3)
            TextField("Search chats and contacts", text: $query)
                .font(.bodyC)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !ctx.usesRail {
                Button("Cancel") { withAnimation(Motion.ui) { nav.searching = false } }
                    .font(.bodyC)
                    .foregroundStyle(Theme.blueText)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .glass(Capsule(), interactive: false, morph: "search", in: searchGlass)
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .transition(.opacity)
    }

    private var requestsLink: some View {
        Button { nav.switchPage(.friends) } label: {
            HStack(spacing: 6) {
                Text("Requests").font(AppFont.make(16, .semibold)).foregroundStyle(Theme.label)
                if !model.requests.isEmpty {
                    Badge(count: model.requests.count, color: Theme.red, text: .white)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
        }
        .buttonStyle(.press)
    }

    // MARK: rows

    @ViewBuilder
    private func rowView(_ room: Room) -> some View {
        let selected = nav.columns == 2 && nav.room == room.id && nav.isVisible(.chat)
        Button {
            Haptics.selection()
            nav.open(room: room.id)
        } label: {
            ChatRow(room: room, selected: selected, compact: nav.searching, leading: ctx.twoUp && !ctx.isRightmost)
        }
        .buttonStyle(RowPressStyle(radius: 22))
        .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                Task { await model.deleteChat(room.id) }
            } label: { Label("Delete", systemImage: "trash") }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            let unread = room.unread > 0 || room.marked
            Button {
                Task { await model.setFlag(room.id, unread: !unread) }
            } label: { Label(unread ? "Read" : "Unread", systemImage: unread ? "envelope.open" : "envelope.badge") }
                .tint(Theme.fbBlue)
            Button {
                Task { await model.setFlag(room.id, pinned: !room.pinned) }
            } label: { Label(room.pinned ? "Unpin" : "Pin", systemImage: room.pinned ? "pin.slash" : "pin") }
                .tint(Theme.orange)
        }
        .contextMenu {
            let unread = room.unread > 0 || room.marked
            Button { Task { await model.setFlag(room.id, unread: !unread) } } label: {
                Label(unread ? "Mark as read" : "Mark as unread", systemImage: unread ? "envelope.open" : "envelope.badge")
            }
            Button { Task { await model.setFlag(room.id, pinned: !room.pinned) } } label: {
                Label(room.pinned ? "Unpin" : "Pin", systemImage: room.pinned ? "pin.slash" : "pin")
            }
            Button { Task { await model.setFlag(room.id, muted: !room.muted) } } label: {
                Label(room.muted ? "Unmute" : "Mute", systemImage: room.muted ? "bell" : "bell.slash")
            }
            Divider()
            Button(role: .destructive) { Task { await model.deleteChat(room.id) } } label: { Label("Delete chat", systemImage: "trash") }
        } preview: {
            ThreadPreview(roomId: room.id).environment(model)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(nav.filter == .all ? "Chats show up here once you send or receive a message." : "Nothing here")
                .font(.subheadC)
                .foregroundStyle(Theme.label2)
            if nav.filter == .all {
                PillButton(title: "Start", style: .blue) { nav.switchPage(.friends) }
            }
        }
        .padding(.horizontal, inset)
        .padding(.vertical, 18)
    }

    // MARK: bars

    @ViewBuilder
    private var bars: some View {
        if ctx.usesRail {
            // The Duo: Back heads the rail (Cancel while searching); Search is beside the title.
            ColumnBar(back: nav.searching
                ? BarItem(id: "cancel", sym: .xmark, title: "Cancel search") { withAnimation(Motion.ui) { nav.searching = false } }
                : (besideSidebar ? nil : BarItem(id: "back", sym: .chevronLeft, title: "Sidebar") { nav.toSidebar() }))
        } else if !nav.searching && !listControlsOnTop {
            ColumnBar(back: (nav.columns == 1 && !leadingTwoUp) ? BarItem(id: "back", sym: .chevronLeft, title: "Sidebar") { nav.toSidebar() } : nil,
                      actions: leadingTwoUp ? [BarItem(id: "filter", sym: .filter, title: "Filter", tint: nav.filter == .all ? nil : Theme.fbBlue.opacity(0.8),
                                                        foreground: nav.filter == .all ? Theme.label : .white) {
                          withAnimation(Motion.bouncy) { nav.filterCard = .list }
                      }] : []) {
                Button {
                    Haptics.tap()
                    withAnimation(Motion.ui) { nav.searching = true }
                } label: {
                    HStack(spacing: 9) {
                        SymbolView(.search, size: 18).foregroundStyle(Theme.label2)
                        Text("Search chats and contacts").font(.calloutC).foregroundStyle(Theme.label2).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 17)
                    .frame(height: Bar.foot)
                    .background(Theme.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
                    .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
                }
                .buttonStyle(.press)
            }
        }
    }

}

// MARK: - Filter tabs (blue glass thumb that slides)

struct FilterTabs<Trailing: View>: View {
    @Environment(Nav.self) private var nav
    let requests: Trailing
    @Namespace private var ns
    @State private var moreAtEnd = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(ListFilter.allCases) { f in
                    let on = nav.filter == f
                    Button {
                        Haptics.selection()
                        withAnimation(Motion.ui) { nav.filter = f }
                    } label: {
                        Text(f.title)
                            .font(AppFont.make(15, on ? .bold : .semibold))
                            .foregroundStyle(on ? .white : Theme.label2)
                            .padding(.horizontal, 16)
                            .frame(height: 44)
                            .background {
                                if on {
                                    Capsule().fill(.clear).frame(height: 36)
                                        .blueGlass(Capsule())
                                        .matchedGeometryEffect(id: "thumb", in: ns)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
                Rectangle().fill(Theme.line).frame(width: 1, height: 20).padding(.horizontal, 6)
                requests
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 8)
        }
        // Where the row runs past the column, it fades at that edge (list.css data-more).
        .onScrollGeometryChange(for: Bool.self) { g in
            g.contentOffset.x + g.containerSize.width < g.contentSize.width - 2
        } action: { _, v in moreAtEnd = v }
        .mask {
            HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .black.opacity(moreAtEnd ? 0 : 1)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 40)
            }
        }
    }
}

// MARK: - Row (row-inner: 76pt, 46pt avatar, name 17 semibold, time 13, preview 15)

struct ChatRow: View {
    @Environment(AppModel.self) private var model
    let room: Room
    var selected = false
    var compact = false
    /// The leading pane of a split view: 44pt photos, 66pt rows.
    var leading = false

    var body: some View {
        let typing = typingLine
        let unread = room.unread > 0 || room.marked
        HStack(spacing: 12) {
            Avatar(path: room.avatar, name: room.title, size: compact ? 40 : (leading ? 44 : 46),
                   online: !room.isGroup && model.isOnline(room.peer?.id))
            VStack(alignment: .leading, spacing: compact ? 1 : 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(room.title)
                        .font(AppFont.make(17, .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Theme.label)
                        .lineLimit(1)
                    if room.muted {
                        SymbolView(.bell, size: 13, slashed: true).foregroundStyle(Theme.label3)
                    }
                    Spacer(minLength: 4)
                    if !compact {
                        Text(Fmt.listTime(room.date))
                            .font(AppFont.make(13, unread && !room.muted ? .semibold : .regular).monospacedDigit())
                            .foregroundStyle(unread && !room.muted ? Theme.brandText : Theme.label2)
                    }
                }
                HStack(alignment: .center, spacing: 6) {
                    Group {
                        if let typing {
                            Text(typing).foregroundStyle(Theme.blueText)
                        } else if room.mention != nil && room.unread > 0 {
                            Text("Mentioned you · ").foregroundStyle(Theme.blueText) + Text(preview).foregroundStyle(Theme.label2)
                        } else {
                            Text(preview).foregroundStyle(unread ? Theme.label : Theme.label2)
                        }
                    }
                    .font(AppFont.make(compact ? 13 : 15))
                    .lineSpacing(compact ? 0 : 2)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if room.pinned && !compact {
                        SymbolView(.pin, size: 13).foregroundStyle(Theme.label3)
                    }
                    if room.unread > 0 && !compact {
                        if room.marked {
                            Circle().fill(Theme.badge).frame(width: 18, height: 18)
                        } else {
                            Badge(count: room.unread, color: room.muted ? Theme.fill : Theme.badge, text: room.muted ? Theme.label2 : Theme.onBrand, small: true)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, leading ? 11 : 13)
        .padding(.vertical, compact ? 10 : (leading ? 10 : 12))
        .frame(minHeight: compact ? 66 : (leading ? 66 : 76))
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.fill4)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            }
        }
        .contentShape(Rectangle())
        .animation(Motion.quick, value: selected)
        .animation(Motion.quick, value: typing)
        .accessibilityElement(children: .combine)
    }

    private var typingLine: String? {
        guard let map = model.typing[room.id], let first = map.first else { return nil }
        let who = room.isGroup ? "\(model.name(of: first.key)): " : ""
        let t = first.value.text
        return t == "…" || t.isEmpty ? who + String(localized: "typing…") : who + t
    }

    private var preview: String {
        guard let last = room.last else { return "" }
        if last.isSystem { return last.body }
        var p = last.preview
        if last.type == "call" { p = CallSummary(meta: last.meta, mine: last.meta?.caller == model.me?.id).label }
        if last.local == .failed { return String(localized: "Not sent · ") + p }
        if last.sender == model.me?.id { return room.isGroup ? String(localized: "You: ") + p : p }
        if room.isGroup { return "\(model.name(of: last.sender)): \(p)" }
        return p
    }
}

struct PersonRow: View {
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    let user: User
    var subtitle: String?

    var body: some View {
        Button {
            Task { if let id = await model.openDM(user) { nav.open(room: id) } }
        } label: {
            HStack(spacing: 12) {
                Avatar(user: user, size: 38, online: model.isOnline(user.id))
                VStack(alignment: .leading, spacing: 1) {
                    Text(user.name).font(.subheadBoldC).foregroundStyle(Theme.label)
                    Text(subtitle ?? "@\(user.username)").font(.footnoteC).foregroundStyle(Theme.label2)
                }
                Spacer()
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle(radius: 18))
    }
}

// MARK: - Empty conversation column

struct EmptyChatView: View {
    @Environment(\.column) private var ctx

    var body: some View {
        ZStack {
            Theme.bg
            VStack(spacing: 12) {
                SymbolView(.bubble, size: 44, weight: 1.4).foregroundStyle(Theme.label3)
                Text("Pick a chat").font(.headlineC).foregroundStyle(Theme.label2)
            }
            .padding(.trailing, ctx.insets.trailing)
        }
    }
}

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
    /// Scrolled, the large title settles small in the middle (as the other
    /// tabs' titles do, PageScaffold's `.large`).
    @State private var collapsed = false
    /// The title's own width and the room it has beside the buttons, so the
    /// small title can sit in the middle without running under them.
    @State private var titleWidth: CGFloat = 0
    @State private var titleRoom: CGFloat = 0

    /// On the Duo's rail, Search and New chat stand in the system column,
    /// where every other tab keeps its actions.
    private var actionsOnRail: Bool { ctx.usesRail }
    /// Where there's no rail, the tabs lie at the list's foot (and leave with it).
    private var tabsAtFoot: Bool { ctx.rail == nil && !ctx.systemColumn && !nav.searching && ctx.keyboard == 0 }
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
            ScrollViewReader { proxy in
            List {
                if !nav.searching {
                    NotesRow()
                        .id("top")
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 4, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
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

                if nav.searching && !query.trimmingCharacters(in: .whitespaces).isEmpty && filtered.isEmpty && found.isEmpty {
                    Text("No results for “\(query.trimmingCharacters(in: .whitespaces))”")
                        .font(.subheadC)
                        .foregroundStyle(Theme.label2)
                        .padding(.horizontal, inset)
                        .padding(.vertical, 18)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
            // Its tab tapped again: back to the top.
            .onReceive(NotificationCenter.default.publisher(for: .scrollToTop)) { n in
                guard (n.object as? String) == Page.chats.rawValue else { return }
                withAnimation(Motion.move) { proxy.scrollTo("top", anchor: .top) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in
                let c = y > 18
                if c != collapsed { withAnimation(.smooth(duration: 0.3)) { collapsed = c } }
            }
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
            // Room at the foot for the tab bar only while it's there.
            .safeAreaPadding(EdgeInsets(top: ctx.insets.top, leading: ctx.insets.leading, bottom: tabsAtFoot ? ctx.contentBottom : max(ctx.insets.bottom, 16) + 8,
                                        trailing: ctx.usesRail ? ctx.insets.trailing + 10 : ctx.insets.trailing))
            .refreshable {
                await model.refreshRooms()
                await model.loadNotes()
                await model.loadPeople()
            }
            .animation(Motion.ui, value: nav.searching)
            }

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
        // Going into a chat (a row, a person, a link) puts the keyboard away;
        // the search itself stays, so Back comes back to its results.
        .onChange(of: nav.isVisible(.list)) { _, shown in
            if !shown { searchFocused = false }
        }
        .onChange(of: nav.room) { _, _ in searchFocused = false }
    }

    // MARK: header

    /// How far the small title moves to stand in the middle of the bar: half
    /// the room the buttons take (44pt and a 10pt gap each), as far as it
    /// fits without reaching them.
    private var titleShift: CGFloat {
        let buttons: CGFloat = actionsOnRail ? 1 : 3
        return min(buttons * 27, max(0, (titleRoom - titleWidth * 20 / 28) / 2))
    }

    /// The title as the other tabs draw theirs (PageScaffold's large title:
    /// 28pt, the same height, small and centred once scrolled), then the
    /// scopes, Search and New chat.
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Chats")
                .font(AppFont.make(28, .bold))
                .tracking(-0.56)
                .foregroundStyle(Theme.label)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { titleWidth = $0 }
                .scaleEffect(collapsed ? 20.0 / 28.0 : 1, anchor: collapsed ? .center : .leading)
                .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { titleRoom = $0 }
                .offset(x: collapsed ? titleShift : 0)
            // The scopes are a menu with the list they filter (HIG: pull-down menus).
            Menu {
                Picker("Filter", selection: Binding(get: { nav.filter }, set: { f in withAnimation(Motion.ui) { nav.filter = f } })) {
                    ForEach(ListFilter.allCases) { f in filterTitle(f).tag(f) }
                }
            } label: {
                SymbolView(.filter, size: 18)
                    .foregroundStyle(nav.filter == .all ? Theme.label : Theme.blue)
                    .frame(width: 44, height: 44)
                    .glassCircle()
            }
            .accessibilityLabel("Filter")
            .accessibilityValue(Text(nav.filter.title))
            if !actionsOnRail {
                // Search, then a new chat: the two things you start from here.
                Button {
                    withAnimation(Motion.ui) { nav.searching = true }
                } label: {
                    SymbolView(.search, size: 18, weight: 2.2)
                        .foregroundStyle(Theme.label)
                        .frame(width: 44, height: 44)
                        .glass(Circle(), interactive: true, morph: "search", in: searchGlass)
                }
                .buttonStyle(.press(0.94))
                .accessibilityLabel("Search")
                Button {
                    withAnimation(Motion.move) { nav.newGroup = true }
                } label: {
                    SymbolView(.compose, size: 19)
                        .foregroundStyle(Theme.label)
                        .frame(width: 44, height: 44)
                        .glassCircle()
                }
                .buttonStyle(.press(0.94))
                .accessibilityLabel("New chat")
            }
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 60)
        // The title's centre where the other tabs keep theirs.
        .padding(.top, ctx.insets.top > 20 ? 0 : 12)
    }

    /// A scope's name in the menu; Unread also says how many.
    private func filterTitle(_ f: ListFilter) -> Text {
        guard f == .unread else { return Text(f.title) }
        let n = model.rooms.filter { $0.unread > 0 || $0.marked }.count
        return n > 0 ? Text(verbatim: String(localized: "Unread") + " \(n)") : Text(f.title)
    }

    private var searchHead: some View {
        HStack(spacing: 8) {
            SymbolView(.search, size: 17).foregroundStyle(Theme.label3)
            TextField("Search chats and contacts", text: $query)
                .font(.bodyC)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
            ClearButton(text: $query)
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

    // MARK: rows

    @ViewBuilder
    private func rowView(_ room: Room) -> some View {
        let selected = nav.columns == 2 && nav.room == room.id && nav.isVisible(.chat)
        Button {
            // From search, Back comes back to the same results.
            nav.open(room: room.id, keepSearch: nav.searching)
        } label: {
            ChatRow(room: room, selected: selected, compact: nav.searching, leading: ctx.twoUp && !ctx.isRightmost)
        }
        .buttonStyle(RowPressStyle(radius: 22))
        .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            // A full swipe deletes (with Undo); Mute sits beside it, as in Messages.
            Button(role: .destructive) {
                Task { await model.deleteChat(room.id) }
            } label: { Label("Delete", systemImage: "trash") }
            Button {
                Task { await model.setFlag(room.id, muted: !room.muted) }
            } label: { Label(room.muted ? "Unmute" : "Mute", systemImage: room.muted ? "bell" : "bell.slash") }
                .tint(Color.indigo)
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

    /// Nothing to show: say why, and offer the one next step.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch nav.filter {
            case .all:
                Text("No chats yet").font(.headlineC).foregroundStyle(Theme.label)
                Text("Message a friend or start a group.").font(.subheadC).foregroundStyle(Theme.label2)
                PillButton(title: model.contacts.contains { $0.state == "accepted" } ? "New chat" : "Find friends", style: .ink) {
                    if model.contacts.contains(where: { $0.state == "accepted" }) {
                        withAnimation(Motion.move) { nav.newGroup = true }
                    } else {
                        nav.switchPage(.friends)
                    }
                }
                .padding(.top, 10)
            default:
                Text(nav.filter == .unread ? "No unread chats" : (nav.filter == .direct ? "No direct chats" : "No group chats"))
                    .font(.subheadC).foregroundStyle(Theme.label2)
                Button("Show all") { withAnimation(Motion.ui) { nav.filter = .all } }
                    .font(.subheadBoldC)
                    .foregroundStyle(Theme.blueText)
                    .buttonStyle(.plain)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, inset)
        .padding(.vertical, 24)
    }

    // MARK: bars

    @ViewBuilder
    private var bars: some View {
        if ctx.usesRail {
            // The Duo: Search and New chat in the system column, where the
            // other tabs keep their actions; Cancel heads it while searching.
            ColumnBar(back: nav.searching
                ? BarItem(id: "cancel", sym: .xmark, title: "Cancel search") { withAnimation(Motion.ui) { nav.searching = false } }
                : nil,
                actions: nav.searching ? [] : railActions)
        } else if tabsAtFoot {
            // No rail: the tabs at the list's foot, leaving with it when a chat opens.
            PageCapsule(nav: nav, axis: .horizontal)
                .padding(.leading, max(ctx.insets.leading, 16))
                .padding(.trailing, max(ctx.insets.trailing, 16))
                .padding(.bottom, max(ctx.insets.bottom, 16))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .transition(.opacity)
        }
    }

    /// Search and New chat as the rail holds them.
    private var railActions: [BarItem] {
        [BarItem(id: "search", sym: .search, title: "Search") { withAnimation(Motion.ui) { nav.searching = true } },
         BarItem(id: "new", sym: .compose, title: "New chat") { withAnimation(Motion.move) { nav.newGroup = true } }]
    }

}

// MARK: - Row (row-inner: 76pt, 46pt avatar, name 17 semibold, time 13, preview 15)

struct ChatRow: View {
    let room: Room
    var selected = false
    var compact = false
    /// The leading pane of a split view: 44pt photos, 66pt rows.
    var leading = false

    var body: some View {
        let unread = room.unread > 0 || room.marked
        HStack(spacing: 12) {
            ChatRowAvatar(room: room, size: compact ? 40 : (leading ? 44 : 46))
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
                    ChatRowSubtitle(room: room, compact: compact, unread: unread)
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
        .accessibilityElement(children: .combine)
    }
}

/// A row's photo and its online dot, on their own: a friend coming online
/// or going away redraws only the photos, not every row.
private struct ChatRowAvatar: View {
    @Environment(AppModel.self) private var model
    let room: Room
    let size: CGFloat

    var body: some View {
        Avatar(path: room.avatar, name: room.title, size: size,
               online: !room.isGroup && model.isOnline(room.peer?.id))
    }
}

/// The line under a row's name (who's typing, a mention, or the last
/// message), on its own: someone typing in any chat redraws only these
/// lines, not every whole row in the list.
private struct ChatRowSubtitle: View {
    @Environment(AppModel.self) private var model
    let room: Room
    let compact: Bool
    let unread: Bool

    var body: some View {
        let typing = typingLine
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
        .animation(Motion.quick, value: typing)
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
            Task { if let id = await model.openDM(user) { nav.open(room: id, keepSearch: nav.searching) } }
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

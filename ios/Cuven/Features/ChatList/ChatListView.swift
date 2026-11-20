import SwiftUI

struct ChatListView: View {
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    @Environment(\.column) private var ctx
    @State private var query = ""
    @State private var found: [User] = []
    @State private var scrolled = false
    @FocusState private var searchFocused: Bool

    /// Beside the sidebar the list doesn't repeat its filters and title.
    private var besideSidebar: Bool { nav.columns == 2 && nav.leading == .sidebar }

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
                header
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                if !nav.searching && nav.filter == .all && !besideSidebar {
                    NotesRow()
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }

                if !nav.searching && !besideSidebar {
                    FilterChips()
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 6, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }

                ForEach(filtered) { room in
                    ChatRow(room: room, selected: nav.columns == 2 && nav.room == room.id && nav.isVisible(.chat))
                        .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Haptics.selection()
                            nav.open(room: room.id)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await model.deleteChat(room.id) }
                            } label: { Label("Delete", systemImage: "trash") }
                            Button {
                                Task { await model.setFlag(room.id, muted: !room.muted) }
                            } label: { Label(room.muted ? "Unmute" : "Mute", systemImage: room.muted ? "bell" : "bell.slash") }
                                .tint(Theme.indigo)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                Task { await model.setFlag(room.id, unread: !(room.unread > 0 || room.marked)) }
                            } label: {
                                Label(room.unread > 0 || room.marked ? "Read" : "Unread",
                                      systemImage: room.unread > 0 || room.marked ? "envelope.open" : "envelope.badge")
                            }
                            .tint(Theme.blue)
                            Button {
                                Task { await model.setFlag(room.id, pinned: !room.pinned) }
                            } label: { Label(room.pinned ? "Unpin" : "Pin", systemImage: room.pinned ? "pin.slash" : "pin") }
                                .tint(Theme.orange)
                        }
                        .contextMenu {
                            rowMenu(room)
                        } preview: {
                            ThreadPreview(roomId: room.id)
                                .environment(model)
                        }
                }

                if filtered.isEmpty {
                    emptyState
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }

                if nav.searching && !found.isEmpty {
                    Section {
                        ForEach(found) { u in
                            PersonRow(user: u)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text("People").font(.footnoteC.weight(.semibold)).foregroundStyle(Theme.label2)
                    }
                }

                if !nav.searching && nav.filter == .all && !besideSidebar {
                    PeopleSections()
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)
            .safeAreaPadding(EdgeInsets(top: ctx.insets.top, leading: ctx.insets.leading,
                                        bottom: ctx.usesRail ? ctx.insets.bottom + 12 : ctx.barClearance,
                                        trailing: ctx.usesRail ? ctx.insets.trailing : ctx.insets.trailing))
            .refreshable {
                await model.refreshRooms()
                await model.loadNotes()
                await model.loadPeople()
            }
            .onScrollGeometryChangeCompat { scrolled = $0 > 8 }

            // A frosted strip under the status bar once the list moves.
            VStack(spacing: 0) {
                Rectangle().fill(.bar).frame(height: ctx.insets.top)
                    .opacity(scrolled && ctx.insets.top > 20 ? 1 : 0)
                Spacer()
            }
            .allowsHitTesting(false)

            ColumnBar(back: backItem, actions: actions)
        }
        .animation(Motion.ui, value: nav.searching)
        .animation(Motion.ui, value: nav.filter)
        .task(id: query) {
            guard nav.searching, query.count >= 1 else { found = []; return }
            try? await Task.sleep(for: .milliseconds(280))
            let res = await model.searchUsers(query)
            if !Task.isCancelled { withAnimation(Motion.ui) { found = res } }
        }
    }

    private var backItem: BarItem? {
        guard nav.columns == 1 || nav.leading != .sidebar else { return nil }
        if nav.searching {
            return BarItem(id: "cancel", symbol: "xmark", title: "Cancel search") {
                query = ""
                nav.searching = false
                searchFocused = false
            }
        }
        return BarItem(id: "back", symbol: "sidebar.left", title: "Sidebar", badge: model.requests.count) { nav.toSidebar() }
    }

    private var actions: [BarItem] {
        var a: [BarItem] = []
        if nav.columns == 2 && !besideSidebar {
            a.append(BarItem(id: "filter", symbol: nav.filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill",
                             title: "Filter") {
                let all = ListFilter.allCases
                let i = all.firstIndex(of: nav.filter) ?? 0
                withAnimation(Motion.ui) { nav.filter = all[(i + 1) % all.count] }
            })
        }
        a.append(BarItem(id: "new", symbol: "square.and.pencil", title: "New chat", foreground: .white) { nav.newChatOpen = true })
        return a.map { item in
            var i = item
            if i.id == "new" { i.tint = Theme.blue }
            return i
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            if nav.searching {
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.label3)
                        TextField("Search chats and people", text: $query)
                            .font(.bodyC)
                            .focused($searchFocused)
                            .submitLabel(.search)
                            .autocorrectionDisabled()
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.label3) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(Theme.field, in: Capsule())
                    Button("Cancel") {
                        query = ""
                        nav.searching = false
                        searchFocused = false
                    }
                    .font(.bodyC)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.blue)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear { searchFocused = true }
            } else {
                HStack(alignment: .center, spacing: 10) {
                    Text(besideSidebar ? nav.filter.title : "Messages")
                        .font(.largeTitleC)
                        .foregroundStyle(Theme.blue)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Button {
                        Haptics.tap()
                        nav.searching = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .glassCircle(tint: Theme.blue.opacity(0.8))
                    }
                    .buttonStyle(.press(0.9))
                    .accessibilityLabel("Search")
                    Spacer()
                    if ctx.rail == nil || !ctx.isRightmost {
                        Button {
                            nav.switchPage(.moments)
                            model.momentsDot = false
                        } label: {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Theme.label)
                                .frame(width: 40, height: 40)
                                .background(Theme.field, in: Circle())
                                .overlay(alignment: .topTrailing) {
                                    if model.momentsDot { Circle().fill(Theme.red).frame(width: 9, height: 9) }
                                }
                        }
                        .buttonStyle(.press(0.9))
                        .accessibilityLabel("Moments")
                    }
                    Button { nav.settingsOpen = true } label: {
                        Avatar(user: model.me, size: 40)
                    }
                    .buttonStyle(.press(0.9))
                    .accessibilityLabel("Settings")
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func rowMenu(_ room: Room) -> some View {
        let unread = room.unread > 0 || room.marked
        Button {
            Task { await model.setFlag(room.id, unread: !unread) }
        } label: { Label(unread ? "Mark as read" : "Mark as unread", systemImage: unread ? "envelope.open" : "envelope.badge") }
        Button {
            Task { await model.setFlag(room.id, pinned: !room.pinned) }
        } label: { Label(room.pinned ? "Unpin" : "Pin", systemImage: room.pinned ? "pin.slash" : "pin") }
        Button {
            Task { await model.setFlag(room.id, muted: !room.muted) }
        } label: { Label(room.muted ? "Unmute" : "Mute", systemImage: room.muted ? "bell" : "bell.slash") }
        Divider()
        Button(role: .destructive) {
            Task { await model.deleteChat(room.id) }
        } label: { Label("Delete chat", systemImage: "trash") }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: nav.searching ? "magnifyingglass" : "bubble.left.and.text.bubble.right")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.label3)
            Text(nav.searching ? "No chats match" : (nav.filter == .all ? "Chats show up here once you send or receive a message." : "Nothing here"))
                .font(.subheadC)
                .foregroundStyle(Theme.label2)
                .multilineTextAlignment(.center)
            if !nav.searching && nav.filter == .all {
                Button { nav.newChatOpen = true } label: {
                    Text("Start").font(.headlineC).foregroundStyle(.white)
                        .padding(.horizontal, 26).frame(height: 42)
                        .background(Theme.blue, in: Capsule())
                }
                .buttonStyle(.press)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

extension Theme {
    static let indigo = Color.dynamic(0x5856d6, 0x5e5ce6)
}

// MARK: - Row

struct ChatRow: View {
    @Environment(AppModel.self) private var model
    let room: Room
    var selected = false

    var body: some View {
        let typingText = typingLine
        HStack(spacing: 12) {
            Avatar(path: room.avatar, name: room.title, id: room.peer?.id ?? room.id, size: 54,
                   online: !room.isGroup && model.isOnline(room.peer?.id))
                .overlay(alignment: .bottomTrailing) {
                    if room.isGroup {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.label2)
                            .frame(width: 20, height: 20)
                            .background(Theme.bg, in: Circle())
                            .offset(x: 2, y: 2)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(room.title)
                        .font(room.unread > 0 ? .headlineC : AppFont.make(17, .medium))
                        .foregroundStyle(Theme.label)
                        .lineLimit(1)
                    if room.muted {
                        Image(systemName: "bell.slash.fill").font(.system(size: 11)).foregroundStyle(Theme.label3)
                    }
                    Spacer(minLength: 4)
                    Text(Fmt.listTime(room.date))
                        .font(.footnoteC.monospacedDigit())
                        .foregroundStyle(room.unread > 0 && !room.muted ? Theme.blue : Theme.label3)
                }
                HStack(alignment: .center, spacing: 6) {
                    Group {
                        if let typingText {
                            Text(typingText).foregroundStyle(Theme.blue).italic()
                        } else if room.mention != nil && room.unread > 0 {
                            (Text("Mentioned you · ").foregroundStyle(Theme.blue).bold() + Text(preview).foregroundStyle(Theme.label2))
                        } else {
                            Text(preview).foregroundStyle(room.unread > 0 ? Theme.label : Theme.label2)
                        }
                    }
                    .font(.subheadC)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if room.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(Theme.label3).rotationEffect(.degrees(40))
                    }
                    if room.unread > 0 {
                        Badge(count: room.marked ? 0 : room.unread, color: room.muted ? Theme.label3 : Theme.blue)
                            .opacity(room.marked ? 0 : 1)
                            .overlay { if room.marked { Circle().fill(Theme.blue).frame(width: 12, height: 12) } }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(selected ? Theme.fillQuiet : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(selected ? Theme.line : .clear, lineWidth: 1))
        }
        .animation(Motion.quick, value: selected)
        .animation(Motion.quick, value: typingText)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var typingLine: String? {
        guard let map = model.typing[room.id], let first = map.first else { return nil }
        let who = room.isGroup ? "\(model.name(of: first.key)): " : ""
        let t = first.value.text
        return t == "…" || t.isEmpty ? who + String(localized: "typing…") : who + t
    }

    private var preview: String {
        guard let last = room.last else { return room.isGroup ? String(localized: "Group created") : "" }
        if last.isSystem { return last.body }
        let mine = last.sender == model.me?.id
        var p = last.preview
        if last.type == "call" { p = CallSummary(meta: last.meta, mine: last.meta?.caller == model.me?.id).label }
        if last.local == .failed { return String(localized: "Not sent · ") + p }
        if mine { return String(localized: "You: ") + p }
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
        HStack(spacing: 12) {
            Avatar(user: user, size: 46, online: model.isOnline(user.id))
            VStack(alignment: .leading, spacing: 2) {
                Text(user.name).font(.headlineC).foregroundStyle(Theme.label)
                Text(subtitle ?? "@\(user.username)").font(.footnoteC).foregroundStyle(Theme.label2)
            }
            Spacer()
            Button {
                Task {
                    if let id = await model.openDM(user) { nav.open(room: id) }
                }
            } label: {
                Text("Message").font(.subheadMediumC).foregroundStyle(Theme.blue)
                    .padding(.horizontal, 14).frame(height: 32)
                    .background(Theme.blue.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.press)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - Filters

struct FilterChips: View {
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ListFilter.allCases) { f in
                        let on = nav.filter == f
                        Button {
                            Haptics.selection()
                            withAnimation(Motion.ui) { nav.filter = f }
                        } label: {
                            HStack(spacing: 5) {
                                Text(f.title)
                                if f == .unread {
                                    let n = model.rooms.filter { $0.unread > 0 || $0.marked }.count
                                    if n > 0 { Text("\(n)").monospacedDigit().opacity(0.8) }
                                }
                            }
                            .font(.subheadMediumC)
                            .foregroundStyle(on ? Theme.onInk : Theme.label)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background {
                                if on {
                                    Capsule().fill(Theme.ink).matchedGeometryEffect(id: "chip", in: ns)
                                } else {
                                    Capsule().stroke(Theme.line, lineWidth: 1)
                                }
                            }
                        }
                        .buttonStyle(.press)
                    }
                }
            }
            Button { nav.switchPage(.requests) } label: {
                HStack(spacing: 4) {
                    Text("Requests")
                    if !model.requests.isEmpty {
                        Text("\(model.requests.count)").font(.caption2C).foregroundStyle(.white)
                            .padding(.horizontal, 6).frame(height: 18).background(Theme.red, in: Capsule())
                    }
                }
                .font(.subheadMediumC)
                .foregroundStyle(Theme.blue)
            }
            .buttonStyle(.press)
        }
    }
}

// MARK: - Empty conversation column

struct EmptyChatView: View {
    @Environment(\.column) private var ctx

    var body: some View {
        ZStack {
            Theme.bg
            VStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 44, weight: .ultraLight))
                    .foregroundStyle(Theme.label3)
                Text("Pick a chat").font(.headlineC).foregroundStyle(Theme.label2)
            }
            .padding(.trailing, ctx.insets.trailing)
        }
    }
}

// MARK: - Scroll offset (iOS 18 API, quiet fallback)

extension View {
    @ViewBuilder
    func onScrollGeometryChangeCompat(_ action: @escaping (CGFloat) -> Void) -> some View {
        if #available(iOS 18.0, *) {
            self.onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top
            } action: { _, new in
                action(new)
            }
        } else {
            self
        }
    }
}

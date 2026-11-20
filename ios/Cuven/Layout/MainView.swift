import SwiftUI

/// The signed-in shell: four columns on one strip, a window of one column
/// (folded / phone) or two (unfolded / landscape Max), the full pages above
/// it, and the overlays above those.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var nav = Nav()
    @State private var keyboard = KeyboardObserver()
    @State private var safe = EdgeInsets()
    @State private var drag: CGFloat = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let geo = StripGeometry(size: size, insets: safe, keyboard: keyboard.height,
                                    columns: nav.columns, posture: posture(size), leading: nav.leading)
            ZStack(alignment: .topLeading) {
                Theme.bg

                // The strip
                ForEach(Column.allCases, id: \.self) { col in
                    let f = geo.frame(col)
                    columnView(col)
                        .environment(\.column, geo.context(col))
                        .frame(width: f.width, height: size.height)
                        .clipped()
                        .offset(x: f.minX + drag)
                        .allowsHitTesting(geo.isOnScreen(col) && drag == 0)
                        .accessibilityHidden(!geo.isOnScreen(col))
                        .zIndex(Double(col.rawValue))
                }

                // The seam between two columns; a book's fold gets a soft shadow either side.
                if nav.columns == 2 {
                    let seam = geo.frame(nav.leading).maxX + drag
                    Group {
                        if geo.posture == .book {
                            LinearGradient(colors: [.clear, .black.opacity(0.06), .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 28)
                                .offset(x: seam - 14)
                        }
                        Rectangle().fill(Theme.separator).frame(width: 1 / UIScreen.main.scale)
                            .offset(x: seam)
                    }
                    .allowsHitTesting(false)
                    .zIndex(10)
                }

                // Swipe from the leading edge: the strip follows the finger 1:1.
                if nav.canGoBack && nav.page == .chats {
                    Color.clear
                        .frame(width: 18, height: size.height)
                        .contentShape(Rectangle())
                        .gesture(edgeSwipe(width: size.width))
                        .zIndex(11)
                }

                // Full pages: Moments, Memories, Requests, You — one at a time, fading in place.
                pageLayer(geo: geo)
                    .zIndex(20)

                // Someone's page, over everything in the shell.
                if let pid = nav.profile {
                    ProfileView(userId: pid)
                        .environment(\.column, geo.pageContext)
                        .id(pid)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .zIndex(25)
                }

                // The page capsule in the system column (iPhone Duo only).
                if let rail = geo.rail, showsPageSwitcher {
                    PageSwitcher(nav: nav)
                        .padding(.trailing, rail.centerFromEdge - PageSwitcher.width / 2)
                        .padding(.bottom, max(safe.bottom, 16))
                        .frame(width: size.width, height: size.height, alignment: .bottomTrailing)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomTrailing)))
                        .zIndex(30)
                }

                if let item = nav.viewer {
                    PhotoViewer(item: item, nav: nav, insets: safe)
                        .zIndex(40)
                }

                if let toast = model.toast {
                    ToastView(toast: toast)
                        .frame(maxWidth: .infinity)
                        .padding(.top, max(safe.top, 12) + 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(50)
                }
            }
            .frame(width: size.width, height: size.height)
            .animation(Motion.move, value: nav.profile)
            .onAppear { nav.setColumns(geo.columnsFor(size)) }
            .onChange(of: size) { _, s in
                withAnimation(Motion.move) { nav.setColumns(StripGeometry.columns(for: s)) }
            }
        }
        .ignoresSafeArea()
        .background(SafeAreaReader { safe = $0 }.ignoresSafeArea())
        .environment(nav)
        .sheet(isPresented: $nav.settingsOpen) { SettingsView() }
        .sheet(isPresented: $nav.newChatOpen) { NewChatView() }
        .fullScreenCover(isPresented: $nav.composeMoment) { MomentEditor() }
        .sheet(isPresented: $nav.noteEditor) { NoteEditor().presentationDetents([.height(300)]) }
        .sheet(item: $nav.openNote) { note in NoteSheet(note: note).presentationDetents([.medium]) }
        .overlay { CallOverlay() }
        .onChange(of: visibleRoom) { _, room in
            model.visibleRoom = room
            if let room { model.markRead(room) }
        }
        .onChange(of: scenePhase) { _, phase in
            model.appActive = phase == .active
            if phase == .active, let r = visibleRoom { model.markRead(r) }
        }
        .onChange(of: model.pendingRoom) { _, room in
            guard let room else { return }
            model.pendingRoom = nil
            nav.open(room: room)
        }
        .onOpenURL { url in
            if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let chat = comps.queryItems?.first(where: { $0.name == "chat" })?.value {
                nav.open(room: chat)
            }
        }
    }

    private var visibleRoom: String? {
        nav.page == .chats && nav.isVisible(.chat) ? nav.room : nil
    }

    private var showsPageSwitcher: Bool {
        if nav.viewer != nil || nav.profile != nil { return false }
        if nav.columns == 2 { return !(nav.detail == .draw && nav.isVisible(.detail)) }
        return nav.page != .chats || nav.active == .list || nav.active == .sidebar
    }

    private func posture(_ size: CGSize) -> Posture {
        if StripGeometry.columns(for: size) == 1 { return .closed }
        return model.bookLayout ? .book : .flat
    }

    @ViewBuilder
    private func columnView(_ col: Column) -> some View {
        switch col {
        case .sidebar: SidebarView()
        case .list: ChatListView()
        case .chat:
            if let room = nav.room, model.room(room) != nil {
                ThreadView(roomId: room).id(room)
            } else {
                EmptyChatView()
            }
        case .detail:
            if let room = nav.room {
                switch nav.detail {
                case .draw: DrawView(roomId: room)
                case .info, .none: ChatInfoView(roomId: room)
                }
            } else {
                Theme.bg
            }
        }
    }

    @ViewBuilder
    private func pageLayer(geo: StripGeometry) -> some View {
        let ctx = geo.pageContext
        ZStack {
            switch nav.page {
            case .chats: EmptyView()
            case .moments: MomentsPage().transition(.opacity)
            case .memories: MemoriesPage().transition(.opacity)
            case .requests: RequestsPage().transition(.opacity)
            case .me: ProfileView(userId: model.me?.id ?? "", asPage: true).transition(.opacity)
            }
        }
        .environment(\.column, ctx)
    }

    private func edgeSwipe(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { v in
                drag = max(0, v.translation.width)
            }
            .onEnded { v in
                let projected = v.predictedEndTranslation.width
                if v.translation.width > width * 0.33 || projected > width * 0.6 {
                    withAnimation(Motion.move) {
                        drag = 0
                        nav.back()
                    }
                } else {
                    withAnimation(Motion.move) { drag = 0 }
                }
            }
    }
}


// MARK: - Geometry

/// Where each column sits for a window size, posture and position on the strip.
struct StripGeometry {
    let size: CGSize
    let insets: EdgeInsets
    let keyboard: CGFloat
    let columns: Int
    let posture: Posture
    let leading: Column

    /// Two columns once there's room for a list beside a readable conversation
    /// (Duo inner display 951pt, Max landscape 956pt), as Messages does.
    static func columns(for size: CGSize) -> Int { size.width >= 700 ? 2 : 1 }
    func columnsFor(_ s: CGSize) -> Int { Self.columns(for: s) }

    /// The system column on the trailing edge (iPhone Duo): only when the
    /// trailing inset is clearly wider than the leading one — a phone in
    /// landscape has the same inset on both sides.
    var rail: RailMetrics? {
        let t = insets.trailing, l = insets.leading
        guard t >= 40, t > l + 20 else { return nil }
        let portrait = size.height > size.width
        let top = max(portrait ? 170 : 118, insets.top + 12)
        return RailMetrics(width: t, top: top, centerFromEdge: t >= 80 ? 49 : t / 2)
    }

    private var narrowContent: CGFloat {
        let usable = size.width - insets.leading - insets.trailing
        return min(380, max(300, usable / 3))
    }

    /// Widths of a visible pair starting at `left`.
    func pair(_ left: Column) -> (CGFloat, CGFloat) {
        let W = size.width
        if posture == .book {
            let half = (W - insets.leading - insets.trailing) / 2
            let l = insets.leading + half
            return (l, W - l)
        }
        if left == .chat {
            let r = narrowContent + insets.trailing
            return (W - r, r)
        }
        let l = insets.leading + narrowContent
        return (l, W - l)
    }

    func width(_ c: Column) -> CGFloat {
        if columns == 1 { return size.width }
        if c == leading { return pair(leading).0 }
        if c.rawValue == leading.rawValue + 1 { return pair(leading).1 }
        if c < leading { return pair(c).0 }
        return pair(Column(rawValue: c.rawValue - 1)!).1
    }

    func frame(_ c: Column) -> CGRect {
        let w = width(c)
        var x: CGFloat
        if columns == 1 {
            x = CGFloat(c.rawValue - leading.rawValue) * size.width
        } else if c == leading {
            x = 0
        } else if c > leading {
            x = width(leading)
            var i = leading.rawValue + 1
            while i < c.rawValue { x += width(Column(rawValue: i)!); i += 1 }
        } else {
            x = 0
            var i = c.rawValue
            while i < leading.rawValue { x -= width(Column(rawValue: i)!); i += 1 }
        }
        return CGRect(x: x, y: 0, width: w, height: size.height)
    }

    func isOnScreen(_ c: Column) -> Bool {
        let f = frame(c)
        return f.maxX > 1 && f.minX < size.width - 1
    }

    func context(_ c: Column) -> ColumnContext {
        let left: Bool
        let right: Bool
        if columns == 1 {
            left = true; right = true
        } else if c <= leading {
            left = true; right = false
        } else {
            left = false; right = true
        }
        let bottom = keyboard > 0 ? keyboard : insets.bottom
        let ins = EdgeInsets(top: insets.top, leading: left ? insets.leading : 0,
                             bottom: bottom, trailing: right ? insets.trailing : 0)
        return ColumnContext(column: c, insets: ins, isLeftmost: left, isRightmost: right,
                             rail: right ? rail : nil, size: CGSize(width: width(c), height: size.height),
                             twoUp: columns == 2)
    }

    var pageContext: ColumnContext {
        let bottom = keyboard > 0 ? keyboard : insets.bottom
        return ColumnContext(column: .list, insets: EdgeInsets(top: insets.top, leading: insets.leading, bottom: bottom, trailing: insets.trailing),
                             isLeftmost: true, isRightmost: true, rail: rail, size: size, twoUp: columns == 2)
    }
}

// MARK: - Page switcher (Duo system column)

struct PageSwitcher: View {
    @Environment(AppModel.self) private var model
    let nav: Nav
    static let width: CGFloat = 52
    @Namespace private var ns

    private var items: [(Page?, String, LocalizedStringKey, Int, Bool)] {
        [
            (.chats, "bubble.left.and.bubble.right.fill", "Chats", model.unreadTotal, false),
            (.moments, "photo.on.rectangle.angled", "Moments", 0, model.momentsDot),
            (.memories, "sparkles.rectangle.stack", "Memories", 0, false),
            (.requests, "person.badge.plus", "Requests", model.requests.count, false),
            (.me, "person.crop.circle", "You", 0, false),
            (nil, "sidebar.left", "Menu", 0, false)
        ]
    }

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let selected = item.0 == nav.page && !(item.0 == .chats && nav.active == .sidebar && nav.columns == 1)
                    || (item.0 == nil && nav.page == .chats && nav.active == .sidebar)
                Button {
                    if let p = item.0 {
                        nav.switchPage(p)
                        if p == .moments { model.momentsDot = false }
                    } else {
                        nav.switchPage(.chats)
                        nav.toSidebar()
                    }
                } label: {
                    Image(systemName: item.1)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(selected ? Theme.blue : Theme.label2)
                        .frame(width: 44, height: 44)
                        .background {
                            if selected {
                                Circle().fill(Theme.blue.opacity(0.14))
                                    .matchedGeometryEffect(id: "sel", in: ns)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if item.3 > 0 { Badge(count: item.3).scaleEffect(0.8).offset(x: 6, y: -4) }
                            else if item.4 { Circle().fill(Theme.red).frame(width: 9, height: 9).offset(x: -4, y: 6) }
                        }
                }
                .buttonStyle(.press(0.9))
                .accessibilityLabel(Text(item.2))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .glass(Capsule(), interactive: false)
        .animation(Motion.ui, value: nav.page)
        .animation(Motion.ui, value: nav.active)
    }
}

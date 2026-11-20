import SwiftUI

/// The signed-in shell, as the web lays it out: four columns on one strip
/// with a window of one column (folded, phone) or two (unfolded, landscape
/// Max), the pages as sheets over it while the strip recedes, the page
/// capsule in the Duo's system column, and the overlays above all of that.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var nav = Nav()
    @State private var keyboard = KeyboardObserver()
    @State private var safe = EdgeInsets()
    @State private var drag: CGFloat = 0
    @State private var posture: Posture = .flat
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { proxy in
            let real = proxy.size
            let emu = Emulation.current
            let size = emu?.size ?? real
            let insets = emu?.insets ?? safe
            let foldRect = emu == nil ? divisionRect(proxy) : nil
            let cols = StripGeometry.columns(for: size)
            let pose: Posture = cols == 1 ? .closed : (posture == .half || foldRect != nil ? .half : .flat)
            let geo = StripGeometry(size: size, insets: insets, keyboard: keyboard.height, columns: nav.columns,
                                    posture: pose, fold: foldRect, leading: nav.leading,
                                    capsule: showsPageCapsule ? PageCapsule.height + Bar.gap + 2 : 0)
            ZStack(alignment: .topLeading) {
                shell(geo: geo, size: size, insets: insets)
                    .frame(width: size.width, height: size.height)
                    .clipped()
            }
            .frame(width: real.width, height: real.height, alignment: .topLeading)
            .background(Color.black)
            .onAppear { nav.setColumns(cols) }
            .onChange(of: cols) { _, c in withAnimation(Motion.move) { nav.setColumns(c) } }
        }
        .ignoresSafeArea()
        .background(SafeAreaReader { safe = $0 }.ignoresSafeArea())
        .modifier(HingeWatcher(posture: $posture))
        .environment(nav)
        .fullScreenCover(isPresented: $nav.composeMoment) { MomentEditor() }
        .sheet(isPresented: $nav.noteEditor) { NoteEditor() }
        .sheet(item: $nav.openNote) { note in NoteSheet(note: note) }
        .sheet(isPresented: $nav.newGroup) { NewGroupView() }
        .overlay { CallOverlay() }
        .task { await Automation.drive(model, nav) }
        .onChange(of: model.pendingRoom) { _, room in
            guard let room else { return }
            model.pendingRoom = nil
            nav.open(room: room)
        }
        .onChange(of: visibleRoom) { _, room in
            model.visibleRoom = room
            if let room { model.markRead(room) }
        }
        .onChange(of: scenePhase) { _, phase in
            model.appActive = phase == .active
            if phase == .active, let r = visibleRoom { model.markRead(r) }
        }
        .onOpenURL { url in
            if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let chat = comps.queryItems?.first(where: { $0.name == "chat" })?.value {
                nav.open(room: chat)
            }
        }
    }

    private var visibleRoom: String? {
        !nav.sheeted && nav.isVisible(.chat) ? nav.room : nil
    }

    /// The fold of a partly open Duo: where the screen divides in two (iOS 27.1).
    private func divisionRect(_ proxy: GeometryProxy) -> CGRect? {
        if #available(iOS 27.1, *) {
            return proxy.reservedRegions(kind: .division).first(where: { $0.isActive })?.frame
        }
        return nil
    }

    @ViewBuilder
    private func shell(geo: StripGeometry, size: CGSize, insets: EdgeInsets) -> some View {
        ZStack(alignment: .topLeading) {
            Theme.bg

            // The strip, receding while a sheet is up.
            ZStack(alignment: .topLeading) {
                Theme.bg
                ForEach(Column.allCases, id: \.self) { col in
                    let f = geo.frame(col)
                    columnView(col)
                        .environment(\.column, geo.context(col))
                        .frame(width: f.width, height: size.height)
                        .clipped()
                        .offset(x: f.minX + drag)
                        .allowsHitTesting(geo.isOnScreen(col) && drag == 0 && !nav.sheeted)
                        .accessibilityHidden(!geo.isOnScreen(col) || nav.sheeted)
                        .zIndex(Double(col.rawValue))
                }
                if nav.columns == 2 {
                    seam(geo: geo, height: size.height)
                }
                if nav.canGoBack && !nav.sheeted {
                    Color.clear
                        .frame(width: 18, height: size.height)
                        .contentShape(Rectangle())
                        .gesture(edgeSwipe(width: size.width))
                        .zIndex(11)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: nav.sheeted ? 30 : 0, style: .continuous))
            .scaleEffect(nav.sheeted ? 0.94 : 1, anchor: .top)
            .offset(y: nav.sheeted ? max(insets.top, 10) : 0)
            .overlay {
                Theme.scrim.opacity(nav.sheeted ? 1 : 0)
                    .allowsHitTesting(nav.sheeted)
                    .onTapGesture { closeSheet() }
            }

            // The pages
            PageSheetLayer(geo: geo)
                .zIndex(20)

            // The page capsule in the system column (iPhone Duo only).
            if let rail = geo.rail, showsPageCapsule {
                PageCapsule(nav: nav)
                    .padding(.trailing, rail.centerFromEdge - Bar.railWidth / 2)
                    .padding(.bottom, max(insets.bottom, 14))
                    .frame(width: size.width, height: size.height, alignment: .bottomTrailing)
                    .transition(.opacity)
                    .zIndex(30)
            }

            if let item = nav.viewer {
                PhotoViewer(item: item, nav: nav, insets: insets)
                    .zIndex(40)
            }

            if let toast = model.toast {
                ToastView(toast: toast)
                    .frame(width: size.width - insets.trailing)
                    .padding(.top, max(insets.top, 12) + 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(50)
            }
        }
        .animation(Motion.move, value: nav.sheeted)
    }

    private var showsPageCapsule: Bool {
        if nav.viewer != nil || keyboard.height > 0 { return false }
        if nav.columns == 2 { return !(nav.detail == .draw && nav.isVisible(.detail)) }
        return nav.sheeted || nav.active == .list || nav.active == .sidebar
    }

    private func closeSheet() {
        withAnimation(Motion.move) {
            if nav.settingsOpen { nav.settingsOpen = false }
            else if nav.profile != nil { nav.profile = nil }
            else { nav.page = .chats }
        }
    }

    @ViewBuilder
    private func seam(geo: StripGeometry, height: CGFloat) -> some View {
        let lead = geo.frame(nav.leading)
        if geo.posture == .half, let gap = geo.gapRect {
            // A book's fold: a soft shadow either side of it.
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black.opacity(0.07)], startPoint: .leading, endPoint: .trailing).frame(width: 18)
                Color.black.opacity(0.08).frame(width: max(1, gap.width))
                LinearGradient(colors: [.black.opacity(0.07), .clear], startPoint: .leading, endPoint: .trailing).frame(width: 18)
            }
            .frame(height: height)
            .offset(x: lead.maxX - 18 + drag)
            .allowsHitTesting(false)
            .zIndex(10)
        } else {
            Rectangle().fill(Theme.line).frame(width: 1, height: height)
                .offset(x: lead.maxX + drag)
                .allowsHitTesting(false)
                .zIndex(10)
        }
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

    private func edgeSwipe(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { v in drag = max(0, v.translation.width) }
            .onEnded { v in
                if v.translation.width > width * 0.33 || v.predictedEndTranslation.width > width * 0.6 {
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

/// The hinge (iOS 27.1): closed, partly open (a book: two panes at the fold)
/// or open flat.
private struct HingeWatcher: ViewModifier {
    @Binding var posture: Posture

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, new in
                guard let hinge = new.hinge else { return }
                let next: Posture
                switch hinge.status {
                case .closed: next = .closed
                case .partiallyOpen: next = .half
                default: next = .flat
                }
                withAnimation(Motion.gentle) { posture = next }
            }
        } else {
            content
        }
    }
}

// MARK: - Geometry (ui/columns.js)

struct StripGeometry {
    let size: CGSize
    let insets: EdgeInsets
    let keyboard: CGFloat
    let columns: Int
    let posture: Posture
    let fold: CGRect?
    let leading: Column
    var capsule: CGFloat = 0

    /// Two columns once a list fits beside a readable conversation (the Duo's
    /// inner display, a Max in landscape, iPad).
    static func columns(for size: CGSize) -> Int { size.width >= 700 ? 2 : 1 }

    /// The system's column on the trailing edge (iPhone Duo): only when it is
    /// clearly wider than the leading inset — a phone in landscape has the
    /// same inset both sides.
    var rail: RailMetrics? {
        let t = insets.trailing, l = insets.leading
        guard t >= 40, t > l + 20 else { return nil }
        let portrait = size.height > size.width
        // Below the camera and the status bar (outer 170pt, inner 118pt), under the clock's centre line.
        return RailMetrics(width: t, top: max(portrait ? 170 : 118, insets.top + 12), centerFromEdge: t >= 80 ? 49 : t / 2)
    }

    /// The narrow column: about a third, 300–380pt (NARROW in columns.js).
    private var narrow: CGFloat {
        let w = (min(380, max(300, size.width * 0.36))).rounded()
        return min(w, (size.width / 2).rounded(.down))
    }

    /// The window starting at `start`: how wide its leading column is, and the gap before the trailing one.
    private func open(_ start: Column) -> (lead: CGFloat, gap: CGFloat) {
        if posture == .half {
            if let fold, fold.minX > 0, fold.maxX < size.width, fold.width < size.width / 3 {
                return (fold.minX, fold.width)
            }
            return (size.width / 2, 0)
        }
        let edge = max(0, min(insets.trailing, size.width - 2 * narrow))
        return (start < .chat ? narrow : size.width - narrow - edge, 0)
    }

    var gapRect: CGRect? {
        let g = open(leading)
        return g.gap > 0 ? CGRect(x: g.lead, y: 0, width: g.gap, height: size.height) : nil
    }

    func frame(_ c: Column) -> CGRect {
        let W = size.width
        if columns == 1 {
            return CGRect(x: CGFloat(c.rawValue - leading.rawValue) * W, y: 0, width: W, height: size.height)
        }
        var boxes = [CGRect](repeating: .zero, count: 4)
        let s = leading.rawValue
        let here = open(leading)
        boxes[s] = CGRect(x: 0, y: 0, width: here.lead, height: size.height)
        if s + 1 < 4 { boxes[s + 1] = CGRect(x: here.lead + here.gap, y: 0, width: W - here.lead - here.gap, height: size.height) }
        var i = s - 1
        while i >= 0 {
            let g = open(Column(rawValue: i)!)
            boxes[i] = CGRect(x: boxes[i + 1].minX - g.gap - g.lead, y: 0, width: g.lead, height: size.height)
            i -= 1
        }
        i = s + 2
        while i < 4 {
            let g = open(Column(rawValue: i - 1)!)
            let prev = boxes[i - 1]
            boxes[i] = CGRect(x: prev.maxX + g.gap, y: 0, width: W - g.lead - g.gap, height: size.height)
            i += 1
        }
        return boxes[c.rawValue]
    }

    func isOnScreen(_ c: Column) -> Bool {
        let f = frame(c)
        return f.maxX > 1 && f.minX < size.width - 1
    }

    func context(_ c: Column) -> ColumnContext {
        let left: Bool, right: Bool
        if columns == 1 { left = true; right = true }
        else if c <= leading { left = true; right = false }
        else { left = false; right = true }
        let bottom = keyboard > 0 ? keyboard : insets.bottom
        let ins = EdgeInsets(top: insets.top, leading: left ? insets.leading : 0, bottom: bottom, trailing: right ? insets.trailing : 0)
        let f = frame(c)
        return ColumnContext(column: c, insets: ins, isLeftmost: left, isRightmost: right,
                             rail: right ? rail : nil, size: CGSize(width: f.width, height: size.height),
                             twoUp: columns == 2, keyboard: keyboard, capsule: right ? capsule : 0)
    }

    /// Where a page's sheet stands (css/overlays.css .sheet): folded, the
    /// app's side of the screen 8pt in from each edge (clear of the page
    /// capsule), at most 560pt, from 26pt under the top to 8pt over the foot;
    /// unfolded, a form sheet in the middle of the screen itself, at most
    /// 560 × 680pt, never reaching over the system's column.
    var sheetFrame: CGRect {
        let W = size.width, H = size.height
        if columns == 1 {
            let left = insets.leading + 8
            let right = max(insets.trailing + 8, rail != nil ? Bar.railWidth + 20 : 0)
            let room = W - left - right
            let w = min(560, room)
            let x = left + (room - w) / 2
            let top = insets.top + 26
            let bottom = keyboard > 0 ? 8 : max(8, insets.bottom - 18)
            return CGRect(x: x, y: top, width: w, height: max(200, H - top - bottom))
        }
        let w = min(560, W - insets.leading - insets.trailing - 64)
        let cx = min(max(W / 2, insets.leading + 32 + w / 2), W - insets.trailing - 32 - w / 2)
        let h = min(680, H - insets.top - 48)
        return CGRect(x: cx - w / 2, y: insets.top + (H - insets.top - h) / 2, width: w, height: h)
    }

    var sheetContext: ColumnContext {
        let f = sheetFrame
        let bottom = keyboard > 0 ? keyboard - (size.height - f.maxY) : insets.bottom
        return ColumnContext(column: .list, insets: EdgeInsets(top: 0, leading: 0, bottom: max(0, min(bottom, 24)), trailing: 0),
                             isLeftmost: true, isRightmost: true, rail: nil, size: f.size, twoUp: columns == 2, keyboard: keyboard)
    }
}

// MARK: - Screenshot emulation (CI only)

/// `CUVEN_EMULATE=outer|inner` lays the app out as the Duo's outer display
/// (466×678, a 90pt system column) or inner one (951×669, 84pt) inside any
/// simulator, for automated screenshots. Never set on a device.
enum Emulation {
    struct Spec { var size: CGSize; var insets: EdgeInsets }
    static let current: Spec? = {
        switch ProcessInfo.processInfo.environment["CUVEN_EMULATE"] {
        case "outer": return Spec(size: CGSize(width: 466, height: 678), insets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 90))
        case "inner": return Spec(size: CGSize(width: 951, height: 669), insets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 84))
        default: return nil
        }
    }()
}

// MARK: - The page capsule (ui/pages.js)

struct PageCapsule: View {
    /// Six 44pt items, 2pt apart, 4pt in from the glass.
    static let height: CGFloat = 6 * 44 + 5 * 2 + 8
    @Environment(AppModel.self) private var model
    let nav: Nav
    @Namespace private var ns

    private struct Item: Identifiable {
        let id: String
        let page: Page?
        let sym: Sym
        let title: LocalizedStringKey
        let count: Int
        let dot: Bool
    }

    private var items: [Item] {
        [
            Item(id: "chats", page: .chats, sym: .house, title: "Chats", count: 0, dot: false),
            Item(id: "moments", page: .moments, sym: .people, title: "Moments", count: 0, dot: model.momentsDot),
            Item(id: "memories", page: .memories, sym: .photoStack, title: "Memories", count: 0, dot: false),
            Item(id: "friends", page: .friends, sym: .bell, title: "Friends", count: model.requests.count, dot: false),
            Item(id: "me", page: .me, sym: .personCircle, title: "You", count: 0, dot: false),
            Item(id: "menu", page: nil, sym: .menu, title: "Menu", count: 0, dot: false)
        ]
    }

    private func current(_ item: Item) -> Bool {
        if nav.settingsOpen { return false }
        if let p = item.page {
            if p == .chats { return nav.page == .chats && !(nav.active == .sidebar && nav.isVisible(.sidebar)) }
            return nav.page == p
        }
        return nav.page == .chats && nav.active == .sidebar && nav.isVisible(.sidebar)
    }

    var body: some View {
        VStack(spacing: 2) {
            ForEach(items) { item in
                let on = current(item)
                Button {
                    if let p = item.page {
                        if p == .moments { model.momentsDot = false }
                        nav.settingsOpen = false
                        nav.profile = nil
                        nav.switchPage(p)
                    } else {
                        nav.settingsOpen = false
                        nav.menu()
                    }
                } label: {
                    SymbolView(item.sym, size: 24, weight: on ? 2.1 : nil)
                        .foregroundStyle(Theme.label)
                        .frame(width: 44, height: 44)
                        .background {
                            if on {
                                Circle().fill(Theme.fill3).matchedGeometryEffect(id: "thumb", in: ns)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if item.count > 0 {
                                Badge(count: item.count, color: Theme.red, text: .white, small: true).offset(x: 2, y: 0)
                            } else if item.dot {
                                Circle().fill(Theme.red).frame(width: 9, height: 9).offset(x: -6, y: 7)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.press(0.88))
                .accessibilityLabel(Text(item.title))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .frame(width: Bar.railWidth)
        .glass(RoundedRectangle(cornerRadius: 26, style: .continuous), interactive: false)
        .animation(Motion.ui, value: nav.page)
        .animation(Motion.ui, value: nav.active)
    }
}

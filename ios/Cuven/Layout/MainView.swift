import SwiftUI
import CoreSpotlight

/// The signed-in shell, as the web lays it out: three columns on one strip
/// with a window of one column (folded, phone) or two (unfolded, landscape
/// Max, iPad), full-screen pages over it (only a note's card makes it
/// recede), the tabs in the Duo's system column or at the foot, and the
/// overlays above all of that.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var nav = Nav()
    @State private var keyboard = KeyboardObserver()
    @State private var safe = EdgeInsets()
    @State private var drag: CGFloat = 0
    @State private var posture: Posture = .flat
    /// On one column, back on the list with the slide over: the conversation
    /// you left is let go, so it stops redrawing (and its stickers playing)
    /// off screen. Opening one, or a second column, brings it back.
    @State private var chatParked = false
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
        .background { KeyCommands(nav: nav) }
        .task { await Automation.drive(model, nav) }
        .onChange(of: model.pendingRoom) { _, room in
            guard let room else { return }
            model.pendingRoom = nil
            nav.open(room: room)
        }
        .onChange(of: model.pendingAction) { _, a in run(a) }
        .onAppear {
            if let room = model.pendingRoom { model.pendingRoom = nil; nav.open(room: room) }
            run(model.pendingAction)
        }
        // A conversation picked in Spotlight, or handed on from another device.
        .onContinueUserActivity(CSSearchableItemActionType) { a in
            if let id = a.userInfo?[CSSearchableItemActivityIdentifier] as? String { nav.open(room: id) }
        }
        .onContinueUserActivity(ChatActivity.type) { a in
            if let id = a.userInfo?["room"] as? String { nav.open(room: id) }
        }
        // Spotlight and Siri know the conversations by name: indexed again
        // when one is added, renamed or gone, not each time the order changes.
        .task(id: Set<String>(model.rooms.prefix(200).map { "\($0.id)|\($0.title)" })) {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled && !model.rooms.isEmpty { ChatDirectory.update(model.rooms) }
        }
        .task(id: [nav.active.rawValue, nav.columns]) {
            guard nav.active == .list, nav.columns == 1 else { chatParked = false; return }
            try? await Task.sleep(for: .milliseconds(420))
            if !Task.isCancelled && nav.active == .list && nav.columns == 1 { chatParked = true }
        }
        .onChange(of: visibleRoom) { _, room in
            model.visibleRoom = room
            if let room { model.markRead(room) }
        }
        .onChange(of: scenePhase) { _, phase in
            model.appActive = phase == .active
            if phase == .active, let r = visibleRoom { model.markRead(r) }
            // A swipe the system cut short (a call, the app sent away) never
            // ends: what it moved settles back, or nothing would take a touch.
            if phase != .active && (drag != 0 || nav.pushDrag != 0) {
                withAnimation(Motion.move) { drag = 0; nav.pushDrag = 0 }
            }
        }
        .onOpenURL { url in
            if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let chat = comps.queryItems?.first(where: { $0.name == "chat" })?.value {
                nav.open(room: chat)
            }
        }
        // Last, so the sheets and the call overlay see it too.
        .environment(nav)
    }

    private func run(_ a: PendingAction?) {
        guard let a else { return }
        model.pendingAction = nil
        switch a {
        case .search:
            nav.clearOverlays()
            nav.switchPage(.chats)
            nav.toList()
            withAnimation(Motion.ui) { nav.searching = true }
        // An editor opens over the pages, but under the photo and the cards: they close.
        case .newMoment: withAnimation(Motion.move) { nav.clearCards(); nav.composeMoment = true }
        case .newGroup: withAnimation(Motion.move) { nav.clearCards(); nav.newGroup = true }
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
            // What shows round the receded app while a note's card is up.
            (receded ? Theme.recede : Theme.bg)

            // The strip, receding while a note's card is up.
            ZStack(alignment: .topLeading) {
                Theme.bg
                ForEach(Column.allCases, id: \.self) { col in
                    let f = geo.frame(col)
                    // On one column, the column behind moves at a third of the finger's pace and dims.
                    let behind = nav.columns == 1 && col < nav.leading
                    columnView(col)
                        .environment(\.column, geo.context(col))
                        // Under a page, or off screen (behind the column in front): stickers and video hold still.
                        .environment(\.contentCovered, nav.covered || !geo.isOnScreen(col))
                        .frame(width: f.width, height: size.height)
                        .background(Theme.bg)
                        .overlay {
                            if behind {
                                Color.black.opacity(0.1 * max(0, 1 - drag / max(1, size.width)))
                                    .allowsHitTesting(false)
                            }
                        }
                        .clipped()
                        .shadow(color: .black.opacity(col == nav.leading && drag > 0 && nav.columns == 1 ? 0.16 : 0), radius: 16, x: -4)
                        .offset(x: f.minX + (behind ? drag * 0.3 : drag))
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
                        // Taken away mid-swipe, its gesture never ends: the columns settle back.
                        .onDisappear { if drag != 0 { withAnimation(Motion.move) { drag = 0 } } }
                        .zIndex(11)
                }
            }
            .frame(width: size.width, height: size.height)
            // Under the first pushed page (Settings, someone's page…) the strip
            // steps back; under a task rising from the foot it stays put.
            .modifier(ParallaxUnder(active: nav.pushCount == 1 && nav.page == .chats && !nav.modalOnTop, width: size.width))
            // A note's card: the app recedes behind it.
            .clipShape(RoundedRectangle(cornerRadius: receded ? 30 : 0, style: .continuous))
            .scaleEffect(receded ? 0.94 : 1, anchor: .top)
            .offset(y: receded ? max(insets.top, 10) : 0)
            .opacity(nav.page != .chats ? 0 : 1)
            .overlay {
                Theme.scrim.opacity(receded ? 1 : 0)
                    .allowsHitTesting(receded)
                    .onTapGesture { closeSheet() }
            }

            // Full-screen pages, then the cards over them (clear of the tabs).
            PageLayer(geo: geo, capsule: geo.rail != nil
                      ? (showsPageCapsule ? PageCapsule.height + Bar.gap + 2 : 0)
                      : (footTabsWidth(geo: geo, size: size) != nil ? Bar.foot + Bar.gap : 0))
                .zIndex(20)
            DialogLayer(geo: geo)
                .zIndex(25)

            // The tabs: upright in the system column (iPhone Duo), or lying at
            // the foot of a tab page (on Chats they are the list's own).
            if let rail = geo.rail {
                if showsPageCapsule {
                    PageCapsule(nav: nav)
                        .padding(.trailing, rail.centerFromEdge - Bar.railWidth / 2)
                        .padding(.bottom, max(insets.bottom, 14))
                        .frame(width: size.width, height: size.height, alignment: .bottomTrailing)
                        .transition(.opacity)
                        .zIndex(30)
                }
            } else if let width = footTabsWidth(geo: geo, size: size) {
                // Padded as the list pads its own (no trailing inset beside a second column).
                PageCapsule(nav: nav, axis: .horizontal)
                    .padding(.leading, max(insets.leading, 16))
                    .padding(.trailing, nav.columns == 2 ? 16 : max(insets.trailing, 16))
                    .frame(width: width)
                    .padding(.bottom, max(insets.bottom, 16))
                    .frame(width: size.width, height: size.height, alignment: .bottomLeading)
                    .allowsHitTesting(drag == 0)
                    .transition(.opacity)
                    .zIndex(30)
            }

            if let item = nav.viewer {
                PhotoViewer(item: item, nav: nav, insets: insets)
                    .zIndex(40)
            }

            // A call over everything but the toasts, in the app's own frame.
            CallOverlay(size: size, insets: insets,
                        fold: geo.posture == .half ? geo.fold : nil)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .allowsHitTesting(model.calls.active)
                .zIndex(45)

            if let toast = model.toast {
                ToastView(toast: toast) { model.undoToast() }
                    .frame(width: size.width - insets.trailing)
                    .padding(.top, max(insets.top, 12) + 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(50)
            }
        }
        .animation(Motion.move, value: nav.dialogUp)
    }

    /// The capsule shows on the strip's first columns and on its own pages;
    /// a page pushed over them (Settings, someone's page, an editor) has the
    /// column to itself.
    private var showsPageCapsule: Bool {
        if nav.viewer != nil || keyboard.height > 0 || nav.pushed || nav.dialogUp { return false }
        if nav.page != .chats { return true }
        if nav.columns == 2 { return !(nav.detail == .draw && nav.isVisible(.detail)) }
        return nav.active == .list
    }

    /// How wide the tabs lie at the foot of a tab page without a rail: as
    /// wide as the list on two columns, where on Chats they are the list's
    /// own, so they stay put from tab to tab; nil where they don't show
    /// (Chats, a pushed page, a card, the keyboard).
    private func footTabsWidth(geo: StripGeometry, size: CGSize) -> CGFloat? {
        if nav.viewer != nil || keyboard.height > 0 || nav.pushed || nav.dialogUp || nav.page == .chats { return nil }
        return nav.columns == 2 ? geo.frame(.list).width : size.width
    }

    /// Only a note's card makes the app recede; pages cover it.
    private var receded: Bool { nav.dialogUp && !nav.covered }

    private func closeSheet() { nav.closeTop() }

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
        case .list: ChatListView()
        case .chat:
            ZStack {
                if let room = nav.room, model.room(room) != nil, chatMounted {
                    ThreadView(roomId: room).id(room)
                } else {
                    EmptyChatView()
                        // Opened for a chat that isn't here (yet, or any more): on
                        // one column the list is off screen, so a way back, as the
                        // chat would have. Always there, so it slides with the column.
                        .overlay {
                            if nav.columns == 1 {
                                ColumnBar(back: BarItem(id: "back", sym: .chevronLeft, title: "Back") { nav.backFromChat() })
                            }
                        }
                        .accessibilityAction(.escape) { if nav.columns == 1 { nav.backFromChat() } }
                }
            }
            // Brought back in place, so it slides in whole (no fade from "Pick a chat").
            .animation(nil, value: chatMounted)
        case .detail:
            // Only while details are open (cleared once they've slid away).
            if let room = nav.room {
                switch nav.detail {
                case .draw: DrawView(roomId: room)
                case .info:
                    // In place before the push starts, so it slides in whole.
                    ChatInfoView(roomId: room)
                        .transition(.asymmetric(insertion: .identity, removal: .opacity))
                // Clear over the column's own background: its fade out can't veil the details.
                case .none: Color.clear
                }
            } else {
                Theme.bg
            }
        }
    }

    /// The conversation stays mounted while it shows or might (beside the
    /// list, behind the details, sliding); only parked is it let go.
    private var chatMounted: Bool {
        !chatParked || nav.active != .list || nav.isVisible(.chat)
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
            // iOS's push: what's behind waits a third of the way off, under the one in front.
            let x = c < leading ? -W * 0.3 : CGFloat(c.rawValue - leading.rawValue) * W
            return CGRect(x: x, y: 0, width: W, height: size.height)
        }
        let n = Column.allCases.count
        var boxes = [CGRect](repeating: .zero, count: n)
        let s = leading.rawValue
        let here = open(leading)
        boxes[s] = CGRect(x: 0, y: 0, width: here.lead, height: size.height)
        if s + 1 < n { boxes[s + 1] = CGRect(x: here.lead + here.gap, y: 0, width: W - here.lead - here.gap, height: size.height) }
        var i = s - 1
        while i >= 0 {
            let g = open(Column(rawValue: i)!)
            boxes[i] = CGRect(x: boxes[i + 1].minX - g.gap - g.lead, y: 0, width: g.lead, height: size.height)
            i -= 1
        }
        i = s + 2
        while i < n {
            let g = open(Column(rawValue: i - 1)!)
            let prev = boxes[i - 1]
            boxes[i] = CGRect(x: prev.maxX + g.gap, y: 0, width: W - g.lead - g.gap, height: size.height)
            i += 1
        }
        return boxes[c.rawValue]
    }

    func isOnScreen(_ c: Column) -> Bool {
        if columns == 1 { return c == leading }
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
                             twoUp: columns == 2, keyboard: keyboard, capsule: right ? capsule : 0,
                             systemColumn: rail != nil)
    }

    /// Where a note's card stands (DialogLayer; css/overlays.css .sheet):
    /// folded, the app's side of the screen 8pt in from each edge (clear of
    /// the system's column), at most 560pt, from 26pt under the top to 8pt
    /// over the foot; unfolded, in the middle of the screen itself, at most
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

    /// A full-screen page: the whole screen, its own rail in the system's column.
    func pageContext(capsule: CGFloat) -> ColumnContext {
        let bottom = keyboard > 0 ? keyboard : insets.bottom
        return ColumnContext(column: .list, insets: EdgeInsets(top: insets.top, leading: insets.leading, bottom: bottom, trailing: insets.trailing),
                             isLeftmost: true, isRightmost: true, rail: rail, size: size, twoUp: columns == 2,
                             keyboard: keyboard, capsule: capsule, onPage: true)
    }

    var sheetContext: ColumnContext {
        let f = sheetFrame
        let bottom = keyboard > 0 ? keyboard - (size.height - f.maxY) : insets.bottom
        return ColumnContext(column: .list, insets: EdgeInsets(top: 0, leading: 0, bottom: max(0, min(bottom, 24)), trailing: 0),
                             isLeftmost: true, isRightmost: true, rail: nil, size: f.size, twoUp: columns == 2, keyboard: keyboard)
    }
}

extension Theme {
    static let recede = Color.token(0xd1d1d6, 0x000000)
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

// MARK: - The tabs

/// The four tabs (HIG, Tab bars): Chats, Moments, Friends, You. On iPhone
/// Duo, a glass capsule upright in the system column, icons only; elsewhere
/// it lies at the foot of the screen with each tab's name under its symbol.
/// Tapping the tab you're on goes back to its root, then to its top.
struct PageCapsule: View {
    /// Four 44pt items, 2pt apart, 4pt in from the glass.
    static let height: CGFloat = 4 * 44 + 3 * 2 + 8
    @Environment(AppModel.self) private var model
    let nav: Nav
    var axis: Axis = .vertical
    @Namespace private var ns

    /// The fourth tab's name: its own key, so Chinese reads 我 (the tab) and
    /// not 你 (the pronoun "You" elsewhere).
    static var meTitle: String { String(localized: "tab.me", defaultValue: "You") }

    private struct Item: Identifiable {
        let page: Page
        let system: String
        /// Already in the reader's language.
        let title: String
        let count: Int
        let dot: Bool
        var id: Page { page }
    }

    private var items: [Item] {
        [
            Item(page: .chats, system: "bubble.left.and.bubble.right", title: String(localized: "Chats"),
                 count: model.rooms.filter { ($0.unread > 0 || $0.marked) && !$0.muted }.count, dot: false),
            Item(page: .moments, system: "camera.aperture", title: String(localized: "Moments"), count: 0, dot: model.momentsDot),
            Item(page: .friends, system: "person.2", title: String(localized: "Friends"), count: model.requests.count, dot: false),
            Item(page: .me, system: "person.crop.circle", title: PageCapsule.meTitle, count: 0, dot: false)
        ]
    }

    private func current(_ item: Item) -> Bool { !nav.settingsOpen && nav.page == item.page }

    var body: some View {
        let layout = axis == .vertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 0))
        layout {
            ForEach(items) { item in
                let on = current(item)
                Button { select(item, on: on) } label: { label(item, on: on) }
                    .buttonStyle(.press(0.9))
                    .accessibilityLabel(Text(item.title))
                    .accessibilityValue(item.count > 0 ? Text("\(item.count)") : Text(verbatim: ""))
                    .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .frame(width: axis == .vertical ? Bar.railWidth : nil, height: axis == .horizontal ? Bar.foot : nil)
        .frame(maxWidth: axis == .horizontal ? 420 : nil)
        .modifier(TabGlass(vertical: axis == .vertical))
        .accessibilityElement(children: .contain)
        .animation(Motion.ui, value: nav.page)
    }

    private func label(_ item: Item, on: Bool) -> some View {
        let glyph = Image(systemName: item.system)
            .symbolVariant(on ? .fill : .none)
            .font(.system(size: axis == .vertical ? 20 : 19, weight: .medium))
            .frame(width: 30, height: 24)
            .overlay(alignment: .topTrailing) {
                if item.count > 0 {
                    Badge(count: item.count, color: Theme.red, text: .white, small: true).offset(x: 8, y: -6)
                } else if item.dot {
                    Circle().fill(Theme.red).frame(width: 8, height: 8).offset(x: 1, y: -1)
                }
            }
        return Group {
            if axis == .vertical {
                glyph.frame(width: 44, height: 44)
            } else {
                VStack(spacing: 1) {
                    glyph
                    Text(item.title).font(AppFont.make(11, .medium)).lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
                .frame(height: Bar.foot - 8)
            }
        }
        .foregroundStyle(on ? Theme.blue : Theme.label)
        .background {
            if on {
                Group {
                    if axis == .vertical { Circle().fill(Theme.fill3) } else { Capsule().fill(Theme.fill3) }
                }
                .matchedGeometryEffect(id: "thumb", in: ns)
            }
        }
        .contentShape(Rectangle())
    }

    private func select(_ item: Item, on: Bool) {
        if item.page == .moments { model.momentsDot = false }
        guard on else {
            nav.settingsOpen = false
            nav.profile = nil
            nav.switchPage(item.page)
            return
        }
        // The tab you're on: back to its root first, then to its top.
        if nav.profile != nil {
            withAnimation(Motion.move) { nav.profile = nil }
        } else if item.page == .chats && ((nav.columns == 1 ? nav.active != .list : nav.leading != .list) || nav.searching) {
            withAnimation(Motion.ui) { nav.searching = false }
            nav.toList()
        } else {
            NotificationCenter.default.post(name: .scrollToTop, object: item.page.rawValue)
        }
    }
}

/// The tabs' glass: a rounded column in the rail, a capsule at the foot.
private struct TabGlass: ViewModifier {
    let vertical: Bool
    func body(content: Content) -> some View {
        if vertical {
            content.glass(RoundedRectangle(cornerRadius: 26, style: .continuous), interactive: false)
        } else {
            content.glass(Capsule(), interactive: false)
        }
    }
}

/// A hardware keyboard on the Duo (HIG, Design principles: support a variety
/// of input methods): Esc steps back out of whatever is open, ⌘F searches,
/// ⌘N starts a new chat, ⌘1–⌘4 go to Chats, Moments, Friends and You.
private struct KeyCommands: View {
    let nav: Nav

    var body: some View {
        ZStack {
            Button("Back") { back() }.keyboardShortcut(.cancelAction)
            Button("Search") {
                nav.clearOverlays()
                nav.switchPage(.chats)
                nav.toList()
                withAnimation(Motion.ui) { nav.searching = true }
            }
            .keyboardShortcut("f", modifiers: .command)
            Button("New chat") { withAnimation(Motion.move) { nav.clearCards(); nav.newGroup = true } }
                .keyboardShortcut("n", modifiers: .command)
            Button("Chats") { goTo(.chats) }.keyboardShortcut("1", modifiers: .command)
            Button("Moments") { goTo(.moments) }.keyboardShortcut("2", modifiers: .command)
            Button("Friends") { goTo(.friends) }.keyboardShortcut("3", modifiers: .command)
            Button(PageCapsule.meTitle) { goTo(.me) }.keyboardShortcut("4", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A tab from the keyboard: what stands over the pages closes, so it shows.
    private func goTo(_ p: Page) {
        nav.clearOverlays()
        nav.switchPage(p)
    }

    /// From the top down: the photo (over everything), then a page or card,
    /// then the column you went into (details, the chat), then the search.
    /// A tab page with nothing over it is a root: Esc leaves it be. The
    /// drawing board closes only by its own Close, which asks first.
    private func back() {
        if nav.viewer != nil {
            withAnimation(Motion.fade) { nav.viewer = nil }
        } else if nav.pushed || nav.dialogUp {
            nav.closeTop()
        } else if nav.page != .chats || (nav.active == .detail && nav.detail == .draw) {
            return
        } else if nav.canGoBack {
            nav.back()
        } else if nav.searching {
            withAnimation(Motion.ui) { nav.searching = false }
        }
    }
}

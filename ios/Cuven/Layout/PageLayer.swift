import SwiftUI

// Full-screen pages. Each page covers the whole screen, its title floats in a
// bar at the top that the content scrolls under (the system's soft scroll
// edge), and its controls float over it: in the iPhone Duo's system column,
// one glass circle for the way out at the head, the actions in a capsule
// under it and what starts something just over the page capsule; elsewhere
// in the floating bar itself, either side of the title.

enum PageTitle {
    case none
    /// Centred, bold (Settings, Memories, the editors).
    case inline(LocalizedStringKey)
    /// At the leading edge, large (Friends, someone's page).
    case large(LocalizedStringKey, Color)
    /// The Moments wordmark: heavy, tracked in, in its own colour.
    case wordmark(LocalizedStringKey, Color)
}

struct PageScaffold<Header: View, Content: View>: View {
    @Environment(\.column) private var ctx
    var title: PageTitle = .none
    /// The title can wait until something scrolls away (a cover).
    var titleShown = true
    var back: BarItem? = nil
    var actions: [BarItem] = []
    var footActions: [BarItem] = []
    var background: Color = Theme.bg
    /// Readable width on the open display; backgrounds still run edge to edge.
    var maxWidth: CGFloat = 680
    /// Content starts at the very top (a cover runs under the floating bar).
    var underBar = false
    var onScroll: ((CGFloat) -> Void)? = nil
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    private var railed: Bool { ctx.usesRail }

    /// Content runs up to the rail and its gap, or the system's column.
    private var trailing: CGFloat {
        guard railed, let rail = ctx.rail else { return ctx.insets.trailing }
        return max(ctx.insets.trailing, rail.centerFromEdge + Bar.railWidth / 2 + 12)
    }

    private var bottomRoom: CGFloat {
        railed ? max(ctx.insets.bottom, 16) + 24 : max(ctx.insets.bottom, 16) + 24
    }

    var body: some View {
        ZStack(alignment: .top) {
            background
            ScrollView {
                content
                    .frame(maxWidth: maxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, bottomRoom)
            }
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in
                onScroll?(y)
            }
            .safeAreaBar(edge: .top, spacing: 0) { barSlot }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .safeAreaPadding(EdgeInsets(top: ctx.insets.top, leading: ctx.insets.leading, bottom: 0, trailing: trailing))

            if underBar {
                bar
                    .padding(.top, ctx.insets.top)
                    .padding(.leading, ctx.insets.leading)
                    .padding(.trailing, trailing)
                    .background {
                        if titleShown {
                            Rectangle().fill(.ultraThinMaterial)
                                .overlay(background.opacity(0.86))
                                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.7),
                                                             .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                                .ignoresSafeArea()
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.22), value: titleShown)
            }

            if railed {
                ColumnBar(back: back, actions: actions, footActions: footActions)
            }
        }
    }

    @ViewBuilder
    private var barSlot: some View {
        if !underBar { bar }
    }

    /// The floating bar: the title, any header (a search field, tabs), and,
    /// without the Duo's column, the controls either side.
    private var bar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if !railed, let back {
                    GlassIconButton(sym: back.sym, title: back.title, tint: back.tint, foreground: back.foreground) { back.action() }
                }
                titleView
                    .opacity(titleShown ? 1 : 0)
                    .offset(y: titleShown ? 0 : 6)
                    .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.26), value: titleShown)
                if !railed && !(actions + footActions).isEmpty {
                    GlassGroup(spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(actions + footActions) { item in
                                GlassIconButton(sym: item.sym, title: item.title, tint: item.tint, foreground: item.foreground,
                                                badge: item.badge, badgeInk: item.badgeInk) { item.action() }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 60)
            header
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var titleView: some View {
        switch title {
        case .none:
            Spacer(minLength: 0)
        case .inline(let t):
            Text(t)
                .font(AppFont.make(20, .bold))
                .tracking(-0.4)
                .foregroundStyle(Theme.label)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.trailing, !railed && back != nil && (actions + footActions).isEmpty ? 54 : 0)
                .padding(.leading, !railed && back == nil && !(actions + footActions).isEmpty ? 54 : 0)
        case .large(let t, let color):
            Text(t)
                .font(AppFont.make(28, .bold))
                .tracking(-0.56)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .wordmark(let t, let color):
            Text(t)
                .font(AppFont.make(30, .heavy))
                .tracking(-1.05)
                .foregroundStyle(color)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension PageScaffold where Header == EmptyView {
    init(title: PageTitle = .none, titleShown: Bool = true, back: BarItem? = nil, actions: [BarItem] = [],
         footActions: [BarItem] = [], background: Color = Theme.bg, maxWidth: CGFloat = 680, underBar: Bool = false,
         onScroll: ((CGFloat) -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, titleShown: titleShown, back: back, actions: actions, footActions: footActions,
                  background: background, maxWidth: maxWidth, underBar: underBar, onScroll: onScroll,
                  header: { EmptyView() }, content: content)
    }
}

// MARK: - The layer

/// Pages over the strip, each full screen: the capsule's page (Moments,
/// Memories, Friends, You) and, above it, pages opened from somewhere
/// (Settings, someone's page, the editors), which slide in from the
/// trailing edge and back out with a swipe from the leading one.
struct PageLayer: View {
    let geo: StripGeometry
    let capsule: CGFloat
    @Environment(Nav.self) private var nav
    @Environment(AppModel.self) private var model
    @State private var drag: CGFloat = 0

    private enum Route: Hashable {
        case profile(String), settings, editProfile, password, newGroup, compose
    }

    private var routes: [Route] {
        var r: [Route] = []
        if let p = nav.profile { r.append(.profile(p)) }
        if nav.settingsOpen { r.append(.settings) }
        if nav.editingProfile { r.append(.editProfile) }
        if nav.changingPassword { r.append(.password) }
        if nav.newGroup { r.append(.newGroup) }
        if nav.composeMoment { r.append(.compose) }
        return r
    }

    var body: some View {
        let routes = routes
        ZStack(alignment: .topLeading) {
            if nav.page != .chats {
                tabPage(nav.page)
                    .environment(\.column, geo.pageContext(capsule: routes.isEmpty ? capsule : 0))
                    .frame(width: geo.size.width, height: geo.size.height)
                    .id("tab-\(nav.page.rawValue)")
                    .transition(.opacity)
            }
            ForEach(Array(routes.enumerated()), id: \.element) { i, route in
                let top = i == routes.count - 1
                routeView(route)
                    .environment(\.column, geo.pageContext(capsule: 0))
                    .frame(width: geo.size.width, height: geo.size.height)
                    .background(Theme.bg)
                    .compositingGroup()
                    .shadow(color: .black.opacity(top && drag > 0 ? 0.18 : 0), radius: 18, x: -4)
                    .offset(x: top ? drag : 0)
                    .overlay(alignment: .leading) {
                        if top && route != .compose {
                            Color.clear
                                .frame(width: 20)
                                .contentShape(Rectangle())
                                .gesture(edgeSwipe)
                        }
                    }
                    .transition(.move(edge: .trailing))
                    .zIndex(Double(i + 1))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: nav.page)
        .animation(Motion.move, value: routes)
    }

    @ViewBuilder
    private func tabPage(_ p: Page) -> some View {
        switch p {
        case .moments: MomentsPage()
        case .memories: MemoriesPage()
        case .friends: FriendsPage()
        case .me: ProfileView(userId: model.me?.id ?? "", asPage: true)
        case .chats: EmptyView()
        }
    }

    @ViewBuilder
    private func routeView(_ r: Route) -> some View {
        switch r {
        case .profile(let id): ProfileView(userId: id)
        case .settings: SettingsView()
        case .editProfile: EditProfileSheet()
        case .password: PasswordSheet()
        case .newGroup: NewGroupView()
        case .compose: MomentEditor()
        }
    }

    /// From the leading edge, 1:1 under the finger; let go past a third (or flicked) to go back.
    private var edgeSwipe: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { v in drag = max(0, v.translation.width) }
            .onEnded { v in
                if v.translation.width > geo.size.width * 0.33 || v.predictedEndTranslation.width > geo.size.width * 0.6 {
                    withAnimation(Motion.move) {
                        drag = 0
                        nav.closeTop()
                    }
                    Haptics.tap()
                } else {
                    withAnimation(Motion.move) { drag = 0 }
                }
            }
    }
}

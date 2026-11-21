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
    /// A line under the title (someone's page: how much they've shared).
    var subtitle: String? = nil
    /// What the bar shows behind it once the title is up (a cover, blurred).
    var barBackdrop: AnyView? = nil
    /// A cover at the top of the page, drawn behind the scroll view across
    /// the whole screen (under the Duo's system column and the status bar)
    /// and moved with the scrolling; the content leaves `coverHeight` of
    /// room for it. Pulled down, it stretches.
    var cover: AnyView? = nil
    var coverHeight: CGFloat = 0
    var onScroll: ((CGFloat) -> Void)? = nil
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    /// Read only by the cover, so scrolling redraws nothing else.
    @State private var scroll = PageScroll()
    /// The floating bar's height, for the room under a cover.
    @State private var barHeight: CGFloat = 64
    /// A large title, scrolled past, settles small in the middle (iOS's
    /// large-title behaviour).
    @State private var collapsed = false
    private var isLarge: Bool { if case .large = title { return true } else { return false } }
    /// Moved only by the screenshot automation.
    @State private var position = ScrollPosition(edge: .top)

    private var railed: Bool { ctx.usesRail }
    /// The bar sits on a cover (or a cover blurred behind it).
    private var overCover: Bool { underBar && barBackdrop != nil }

    /// Content runs up to the rail and its gap, or the system's column.
    private var trailing: CGFloat { ctx.pageTrailing }

    private var bottomRoom: CGFloat {
        railed ? max(ctx.insets.bottom, 16) + 24 : max(ctx.insets.bottom, 16) + 24
    }

    var body: some View {
        ZStack(alignment: .top) {
            background
            if let cover {
                CoverLayer(cover: cover, height: ctx.insets.top + coverHeight, frame: coverFrame, scroll: scroll)
            }
            ScrollView {
                VStack(spacing: 0) {
                    // Room for the cover drawn behind, less the floating bar
                    // (which already holds the content down by its height).
                    if cover != nil {
                        Color.clear.frame(height: max(0, coverHeight - barHeight))
                    }
                    content
                }
                    .frame(maxWidth: maxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.trailing, trailing)
                    .padding(.bottom, bottomRoom)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollPosition($position)
            .onReceive(NotificationCenter.default.publisher(for: .automationScroll)) { _ in
                withAnimation(Motion.move) { position.scrollTo(y: coverHeight + 120) }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in
                if cover != nil { scroll.y = y }
                if isLarge {
                    let c = y > 18
                    if c != collapsed { withAnimation(.smooth(duration: 0.3)) { collapsed = c } }
                }
                onScroll?(y)
            }
            .safeAreaBar(edge: .top, spacing: 0) { barSlot }
            // Always the soft, progressive edge: `.automatic` can resolve to
            // the hard style (a frosted band with a line under it). Over a
            // cover the page draws its own (the cover, blurred, dissolving
            // over what scrolls under it), so the system's is off there.
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectHidden(cover != nil, for: .top)
            // No trailing safe area on the scroll view itself: it clips there,
            // and a cover has to reach under the rail (which sits in the
            // system's column). The content and the bar keep clear instead.
            .safeAreaPadding(EdgeInsets(top: ctx.insets.top, leading: ctx.insets.leading, bottom: 0, trailing: 0))

            if railed {
                ColumnBar(back: back, actions: actions, footActions: footActions)
            }
        }
    }

    /// Across the whole screen, unless the page is held to a readable width
    /// in the middle of a wide display; then over that width.
    private var coverFrame: (x: CGFloat, width: CGFloat) {
        let W = ctx.size.width
        let room = W - ctx.insets.leading - trailing
        guard room > maxWidth else { return (0, W) }
        return (ctx.insets.leading + (room - maxWidth) / 2, maxWidth)
    }

    /// The floating bar, always in the system's bar slot so what scrolls
    /// under it blurs progressively (the soft scroll edge). Over a cover, once
    /// the title is up, the cover shows behind it, blurred, and dissolves
    /// downward rather than stopping at an edge.
    private var barSlot: some View {
        bar
            .padding(.trailing, trailing)
            .background(alignment: .top) { if underBar { coverBackdrop } }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
            .animation(.easeOut(duration: 0.22), value: titleShown)
    }

    /// How far below the bar its backdrop fades out.
    private let backdropFade: CGFloat = 56

    @ViewBuilder
    private var coverBackdrop: some View {
        if titleShown {
            let h = ctx.insets.top + barHeight + backdropFade
            let solidTo = max(0, (ctx.insets.top + barHeight - 18) / h)
            Group {
                if let barBackdrop {
                    ZStack {
                        // What scrolls under the fading part is blurred too
                        // (a material blurs what's behind it), so it goes from
                        // blurred to sharp rather than showing through.
                        Rectangle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                        barBackdrop
                            .frame(height: h)
                            .clipped()
                            .blur(radius: 22, opaque: true)
                            .overlay(Color.black.opacity(0.32))
                            .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom))
                    }
                } else {
                    Rectangle().fill(.ultraThinMaterial).overlay(background.opacity(0.86))
                }
            }
            .frame(height: h)
            .clipped()
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: solidTo),
                                         .init(color: .black.opacity(0.55), location: solidTo + (1 - solidTo) * 0.45),
                                         .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .padding(.top, -ctx.insets.top)
            .padding(.leading, -ctx.insets.leading)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    /// The floating bar: the title, any header (a search field, tabs), and,
    /// without the Duo's column, the controls either side.
    private var bar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if !railed, let back {
                    GlassIconButton(sym: back.sym, system: back.system, title: back.title, tint: overCover ? .black.opacity(0.45) : back.tint,
                                    foreground: overCover ? .white : back.foreground) { back.action() }
                }
                titleView
                    .opacity(titleShown ? 1 : 0)
                    .offset(y: titleShown ? 0 : 6)
                    .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.26), value: titleShown)
                if !railed && !(actions + footActions).isEmpty {
                    GlassGroup(spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(actions + footActions) { item in
                                GlassIconButton(sym: item.sym, system: item.system, title: item.title, tint: overCover ? .black.opacity(0.45) : item.tint,
                                                foreground: overCover ? .white : item.foreground,
                                                badge: item.badge, badgeInk: item.badgeInk) { item.action() }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 60)
            // The title's centre near 48pt from the top, as the Duo's own apps keep it.
            .padding(.top, ctx.insets.top > 20 ? 4 : 16)
            header
        }
        // In line with the content: the same readable width, centred.
        .frame(maxWidth: maxWidth)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var titleView: some View {
        switch title {
        case .none:
            Spacer(minLength: 0)
        case .inline(let t):
            VStack(alignment: subtitle == nil ? .center : .leading, spacing: 0) {
                Text(t)
                    .font(AppFont.make(20, .bold))
                    .tracking(-0.4)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.subheadC).opacity(0.8).lineLimit(1)
                }
            }
            .foregroundStyle(barBackdrop != nil && titleShown ? Color.white : Theme.label)
            .frame(maxWidth: .infinity, alignment: subtitle == nil ? .center : .leading)
                .padding(.trailing, !railed && back != nil && (actions + footActions).isEmpty ? 54 : 0)
                .padding(.leading, !railed && back == nil && !(actions + footActions).isEmpty ? 54 : 0)
        case .large(let t, let color):
            // Scrolled, it shrinks to the inline size and moves to the middle.
            Text(t)
                .font(AppFont.make(28, .bold))
                .tracking(-0.56)
                .foregroundStyle(collapsed ? Theme.label : color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .scaleEffect(collapsed ? 20.0 / 28.0 : 1, anchor: collapsed ? .center : .leading)
                .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
                .padding(.trailing, collapsed && !railed && back != nil && (actions + footActions).isEmpty ? 54 : 0)
                .padding(.leading, collapsed && !railed && back == nil && !(actions + footActions).isEmpty ? 54 : 0)
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
         subtitle: String? = nil, barBackdrop: AnyView? = nil, cover: AnyView? = nil, coverHeight: CGFloat = 0,
         onScroll: ((CGFloat) -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, titleShown: titleShown, back: back, actions: actions, footActions: footActions,
                  background: background, maxWidth: maxWidth, underBar: underBar, subtitle: subtitle, barBackdrop: barBackdrop,
                  cover: cover, coverHeight: coverHeight, onScroll: onScroll, header: { EmptyView() }, content: content)
    }
}

extension ColumnContext {
    /// Where a full-screen page's content stops at the trailing edge: before
    /// the Duo's rail and the gap after it, or at the system's column.
    var pageTrailing: CGFloat {
        guard usesRail, let rail else { return insets.trailing }
        return max(insets.trailing, rail.centerFromEdge + Bar.railWidth / 2 + 12)
    }
}

/// How far a page has scrolled, kept apart so that only what follows it
/// (a cover) is redrawn as it changes.
@Observable final class PageScroll {
    var y: CGFloat = 0
}

/// A page's cover behind its scroll view: it moves up with the content and,
/// pulled past the top, grows downward from the top edge.
private struct CoverLayer: View {
    let cover: AnyView
    let height: CGFloat
    let frame: (x: CGFloat, width: CGFloat)
    let scroll: PageScroll

    var body: some View {
        let y = scroll.y
        cover
            .frame(width: frame.width, height: max(height, height - y))
            .clipped()
            .offset(x: frame.x, y: min(0, -y))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var drag: CGFloat { nav.pushDrag }

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
                    .modifier(ParallaxUnder(active: routes.count == 1, width: geo.size.width))
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
                    // The page under the top one steps back a third and dims (iOS's push).
                    .modifier(ParallaxUnder(active: i == routes.count - 2, width: geo.size.width))
                    .overlay(alignment: .leading) {
                        if top && route != .compose {
                            Color.clear
                                .frame(width: 20)
                                .contentShape(Rectangle())
                                .gesture(edgeSwipe)
                        }
                    }
                    // Reduce Motion: a dissolve instead of a slide (HIG, Motion).
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing))
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
            .onChanged { v in nav.pushDrag = max(0, v.translation.width) }
            .onEnded { v in
                if v.translation.width > geo.size.width * 0.33 || v.predictedEndTranslation.width > geo.size.width * 0.6 {
                    withAnimation(Motion.move) {
                        nav.pushDrag = 0
                        nav.closeTop()
                    }
                    Haptics.tap()
                } else {
                    // Not far enough: it springs back, and what's under steps back again.
                    withAnimation(Motion.move) { nav.pushDrag = 0 }
                }
            }
    }
}

/// What lies under the top pushed page: a third of the way off toward the
/// leading edge and a little dimmed while it's covered, coming back as the
/// page above is swiped away, 1:1 with the finger (HIG: transitions follow
/// the gesture and can be reversed). Still with Reduce Motion.
struct ParallaxUnder: ViewModifier {
    var active: Bool
    var width: CGFloat
    @Environment(Nav.self) private var nav
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let covered = active ? max(0, 1 - nav.pushDrag / max(1, width)) : 0
        content
            .offset(x: reduceMotion ? 0 : -width * 0.3 * covered)
            .overlay {
                Color.black.opacity(0.1 * covered)
                    .allowsHitTesting(false)
            }
            .animation(Motion.move, value: active)
    }
}

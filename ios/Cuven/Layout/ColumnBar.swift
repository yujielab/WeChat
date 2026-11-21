import SwiftUI

/// One control in a column's bar (bars.js: every item has a symbol and a title).
struct BarItem: Identifiable {
    let id: String
    let sym: Sym
    /// A system symbol in place of `sym`, where the web's set has none (a
    /// gear for Settings: the ellipsis is kept for overflow, as the HIG asks).
    var system: String? = nil
    let title: LocalizedStringKey
    var badge: Int = 0
    var badgeInk = false
    var tint: Color? = nil
    var foreground: Color = Theme.label
    let action: () -> Void
}

/// A column's controls where the device wants them (ui/bars.js, rail.css):
/// - a floating bar at the column's foot: the way out at the leading end, a
///   field in the middle, actions at the trailing end, all 44pt glass;
/// - on iPhone Duo, in the system column: the way out at the head of the
///   rail, then the actions (one glass circle each, a capsule for a group),
///   centred under the status bar's clock; a field stays at the foot.
struct ColumnBar<Center: View>: View {
    @Environment(\.column) private var ctx
    @Environment(Nav.self) private var nav
    var back: BarItem?
    var actions: [BarItem] = []
    /// Actions that start something (Search, New): at the foot of the rail,
    /// over the page capsule; at the trailing end of the bar elsewhere.
    var footActions: [BarItem] = []
    var groupActions = true
    var center: Center

    init(back: BarItem? = nil, actions: [BarItem] = [], footActions: [BarItem] = [], groupActions: Bool = true,
         @ViewBuilder center: () -> Center) {
        self.back = back
        self.actions = actions
        self.footActions = footActions
        self.groupActions = groupActions
        self.center = center()
    }

    private var hasCenter: Bool { Center.self != EmptyView.self }

    var body: some View {
        if let rail = ctx.rail, ctx.usesRail {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 12) {
                    if let back { icon(back).transition(.scale(scale: 0.6).combined(with: .opacity)) }
                    if !actions.isEmpty { group(actions, axis: .vertical) }
                    Spacer(minLength: 0)
                    if !footActions.isEmpty { group(footActions, axis: .vertical) }
                }
                .frame(width: Bar.railWidth)
                .padding(.top, rail.top)
                .padding(.bottom, railFoot)
                .padding(.trailing, rail.centerFromEdge - Bar.railWidth / 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                if hasCenter {
                    center
                        .padding(.leading, max(ctx.insets.leading, 16))
                        .padding(.trailing, ctx.insets.trailing + 10)
                        .padding(.bottom, bottomPad)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
            .animation(Motion.ui, value: back?.id)
            // Over a page, the app's rails step aside: the edge column is the pages'.
            .opacity(nav.sheeted && !ctx.onPage ? 0 : 1)
            .animation(.easeOut(duration: 0.16), value: nav.sheeted)
        } else {
            GlassGroup(spacing: Bar.gap) {
                HStack(alignment: .bottom, spacing: Bar.gap) {
                    if let back { icon(back, size: Bar.foot).transition(.scale(scale: 0.6).combined(with: .opacity)) }
                    if hasCenter { center.frame(maxWidth: .infinity) } else { Spacer(minLength: 0) }
                    if !(actions + footActions).isEmpty { group(actions + footActions, axis: .horizontal, size: Bar.foot) }
                }
            }
            .padding(.leading, max(ctx.insets.leading, 16))
            .padding(.trailing, max(ctx.insets.trailing, 16))
            .padding(.bottom, bottomPad)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .animation(Motion.ui, value: back?.id)
        }
    }

    /// max(safe-bottom, 16) at the foot; 8 above the keyboard.
    private var bottomPad: CGFloat {
        ctx.keyboard > 0 ? ctx.insets.bottom + 8 : max(ctx.insets.bottom, 16)
    }

    /// The rail ends 14pt above the screen's foot, over the page capsule when
    /// it shows, or 4pt above the keyboard.
    private var railFoot: CGFloat {
        ctx.keyboard > 0 ? ctx.insets.bottom + 4 : max(ctx.insets.bottom, 14) + ctx.capsule
    }

    private func icon(_ item: BarItem, size: CGFloat = Bar.height) -> some View {
        GlassIconButton(sym: item.sym, system: item.system, title: item.title, tint: item.tint, foreground: item.foreground,
                        badge: item.badge, badgeInk: item.badgeInk, size: size, action: item.action)
    }

    @ViewBuilder
    private func group(_ items: [BarItem], axis: Axis, size: CGFloat = Bar.height) -> some View {
        if items.count == 1 || !groupActions {
            let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: Bar.gap)) : AnyLayout(VStackLayout(spacing: 12))
            layout { ForEach(items) { icon($0, size: size) } }
        } else {
            let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                ForEach(items) { item in
                    Button {
                        Haptics.tap()
                        item.action()
                    } label: {
                        BarGlyph(sym: item.sym, system: item.system, size: 22)
                            .foregroundStyle(item.foreground)
                            .frame(width: axis == .horizontal ? size - 4 : 44, height: axis == .horizontal ? size : 44)
                            .overlay(alignment: .topTrailing) {
                                if item.badge > 0 {
                                    Badge(count: item.badge, color: Theme.red, text: .white, small: true).offset(x: 2, y: -2)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.press(0.9))
                    .accessibilityLabel(Text(item.title))
                }
            }
            .padding(axis == .horizontal ? .horizontal : .vertical, 3)
            .padding(axis == .horizontal ? .vertical : .horizontal, 0)
            .glass(Capsule(), tint: items.first?.tint)
        }
    }
}

extension ColumnBar where Center == EmptyView {
    init(back: BarItem? = nil, actions: [BarItem] = [], footActions: [BarItem] = [], groupActions: Bool = true) {
        self.init(back: back, actions: actions, footActions: footActions, groupActions: groupActions) { EmptyView() }
    }
}

extension ColumnContext {
    /// How much room the foot bar takes, for content to stop above it.
    var barClearance: CGFloat {
        let base = keyboard > 0 ? insets.bottom + 8 : max(insets.bottom, 16)
        return base + Bar.foot + 14
    }

    /// Bottom padding for scrolling content: above the bar, or just the safe area where the rail holds the controls.
    var contentBottom: CGFloat {
        usesRail ? max(insets.bottom, 16) + 8 : barClearance
    }
}

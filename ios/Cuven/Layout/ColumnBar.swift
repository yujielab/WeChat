import SwiftUI

/// One control in a column's bar (bars.js: every item has a symbol and a title).
struct BarItem: Identifiable {
    let id: String
    let sym: Sym
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
    var back: BarItem?
    var actions: [BarItem] = []
    var groupActions = true
    var center: Center

    init(back: BarItem? = nil, actions: [BarItem] = [], groupActions: Bool = true, @ViewBuilder center: () -> Center) {
        self.back = back
        self.actions = actions
        self.groupActions = groupActions
        self.center = center()
    }

    private var hasCenter: Bool { Center.self != EmptyView.self }

    var body: some View {
        if let rail = ctx.rail, ctx.usesRail {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 12) {
                    if let back { icon(back) }
                    if !actions.isEmpty { group(actions, axis: .vertical) }
                }
                .padding(.top, rail.top)
                .padding(.trailing, rail.centerFromEdge - Bar.railWidth / 2 + (Bar.railWidth - Bar.height) / 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                if hasCenter {
                    center
                        .padding(.leading, max(ctx.insets.leading, 16))
                        .padding(.trailing, ctx.insets.trailing + 10)
                        .padding(.bottom, bottomPad)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
        } else {
            GlassGroup(spacing: Bar.gap) {
                HStack(alignment: .bottom, spacing: Bar.gap) {
                    if let back { icon(back) }
                    if hasCenter { center.frame(maxWidth: .infinity) } else { Spacer(minLength: 0) }
                    if !actions.isEmpty { group(actions, axis: .horizontal) }
                }
            }
            .padding(.leading, max(ctx.insets.leading, 16))
            .padding(.trailing, max(ctx.insets.trailing, 16))
            .padding(.bottom, bottomPad)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    /// max(safe-bottom, 16) at the foot; 8 above the keyboard.
    private var bottomPad: CGFloat {
        ctx.keyboard > 0 ? ctx.insets.bottom + 8 : max(ctx.insets.bottom, 16)
    }

    private func icon(_ item: BarItem) -> some View {
        GlassIconButton(sym: item.sym, title: item.title, tint: item.tint, foreground: item.foreground,
                        badge: item.badge, badgeInk: item.badgeInk, action: item.action)
    }

    @ViewBuilder
    private func group(_ items: [BarItem], axis: Axis) -> some View {
        if items.count == 1 || !groupActions {
            let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: Bar.gap)) : AnyLayout(VStackLayout(spacing: 12))
            layout { ForEach(items) { icon($0) } }
        } else {
            let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                ForEach(items) { item in
                    Button {
                        Haptics.tap()
                        item.action()
                    } label: {
                        SymbolView(item.sym, size: 22)
                            .foregroundStyle(item.foreground)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.press(0.9))
                    .accessibilityLabel(Text(item.title))
                }
            }
            .padding(axis == .horizontal ? .horizontal : .vertical, 3)
            .glass(Capsule(), tint: items.first?.tint)
        }
    }
}

extension ColumnBar where Center == EmptyView {
    init(back: BarItem? = nil, actions: [BarItem] = [], groupActions: Bool = true) {
        self.init(back: back, actions: actions, groupActions: groupActions) { EmptyView() }
    }
}

extension ColumnContext {
    /// How much room the foot bar takes, for content to stop above it.
    var barClearance: CGFloat {
        let base = keyboard > 0 ? insets.bottom + 8 : max(insets.bottom, 16)
        return base + Bar.height + 14
    }

    /// Bottom padding for scrolling content: above the bar, or just the safe area where the rail holds the controls.
    var contentBottom: CGFloat {
        usesRail ? max(insets.bottom, 16) + 8 : barClearance
    }
}

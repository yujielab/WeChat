import SwiftUI

/// One control in a column's bar.
struct BarItem: Identifiable {
    let id: String
    let symbol: String
    let title: LocalizedStringKey
    var badge: Int = 0
    var tint: Color? = nil
    var foreground: Color = Theme.label
    let action: () -> Void
}

/// A column's controls, placed where the device wants them:
/// - a floating glass bar at the bottom (56pt, one-handed): the exit at the
///   leading end, a field in the middle, actions at the trailing end;
/// - on iPhone Duo, in the system column on the trailing edge, top to
///   bottom: the exit first, then actions (Apple: Back or Close at the top
///   of the vertical axis). A field stays at the bottom, before the column.
struct ColumnBar<Center: View>: View {
    @Environment(\.column) private var ctx
    var back: BarItem?
    var actions: [BarItem] = []
    var center: Center

    init(back: BarItem? = nil, actions: [BarItem] = [], @ViewBuilder center: () -> Center) {
        self.back = back
        self.actions = actions
        self.center = center()
    }

    var body: some View {
        if let rail = ctx.rail, ctx.usesRail {
            ZStack(alignment: .topTrailing) {
                // The rail
                VStack(spacing: Bar.gap) {
                    if let back { icon(back) }
                    if !actions.isEmpty { group(actions, axis: .vertical) }
                }
                .padding(.top, rail.top)
                .padding(.trailing, rail.centerFromEdge - Bar.height / 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                // The field, before the system column
                if Center.self != EmptyView.self {
                    center
                        .padding(.leading, max(ctx.insets.leading, 16))
                        .padding(.trailing, ctx.insets.trailing + 8)
                        .padding(.bottom, bottomPad)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
        } else {
            GlassGroup(spacing: Bar.gap) {
                HStack(alignment: .bottom, spacing: Bar.gap) {
                    if let back { icon(back) }
                    if Center.self != EmptyView.self {
                        center.frame(maxWidth: .infinity)
                    } else {
                        Spacer(minLength: 0)
                    }
                    if !actions.isEmpty { group(actions, axis: .horizontal) }
                }
            }
            .padding(.leading, max(ctx.insets.leading, 16))
            .padding(.trailing, max(ctx.insets.trailing, 16))
            .padding(.bottom, bottomPad)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private var bottomPad: CGFloat {
        ctx.insets.bottom > 0 ? ctx.insets.bottom + (ctx.insets.bottom > 40 ? 8 : 4) : 14
    }

    private func icon(_ item: BarItem) -> some View {
        GlassIconButton(symbol: item.symbol, title: item.title, tint: item.tint, foreground: item.foreground,
                        badge: item.badge, action: item.action)
    }

    @ViewBuilder
    private func group(_ items: [BarItem], axis: Axis) -> some View {
        if items.count == 1, let only = items.first {
            icon(only)
        } else {
            let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                ForEach(items) { item in
                    Button {
                        Haptics.tap()
                        item.action()
                    } label: {
                        Image(systemName: item.symbol)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(item.foreground)
                            .frame(width: axis == .horizontal ? 46 : Bar.height, height: axis == .horizontal ? Bar.height : 46)
                            .contentShape(Rectangle())
                            .overlay(alignment: .topTrailing) {
                                if item.badge > 0 { Badge(count: item.badge).scaleEffect(0.8).offset(x: 2, y: 2) }
                            }
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
    init(back: BarItem? = nil, actions: [BarItem] = []) {
        self.init(back: back, actions: actions) { EmptyView() }
    }
}

/// How tall a column's bar is, for content to stop above it.
extension ColumnContext {
    var barClearance: CGFloat {
        let base = insets.bottom > 0 ? insets.bottom + (insets.bottom > 40 ? 8 : 4) : 14
        return base + Bar.height + 12
    }
}

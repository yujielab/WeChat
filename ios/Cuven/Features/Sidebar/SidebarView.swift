import SwiftUI

/// The strip's first column (views/sidebar.js, css/columns.css): Home, who
/// you are (opens Settings), the scopes of the conversation list — only
/// Unread carries a number — then Moments and Memories. Search stays in
/// reach at the foot, or over the page capsule in the Duo's rail.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    @Environment(\.column) private var ctx

    private let inset: CGFloat = 22

    private var unreadCount: Int { model.rooms.filter { $0.unread > 0 || $0.marked }.count }

    var body: some View {
        ZStack {
            Theme.paper
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Button { withAnimation(Motion.move) { nav.settingsOpen = true } } label: {
                        HStack(spacing: 12) {
                            Avatar(user: model.me, size: 52)
                            Text(model.me?.name ?? String(localized: "Me"))
                                .font(.headlineC)
                                .tracking(-0.34)
                                .foregroundStyle(Theme.label)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            SymbolView(.chevronRight, size: 14).foregroundStyle(Theme.label3)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(minHeight: 72)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    .buttonStyle(FillPressStyle(radius: 22, fill: Theme.field))
                    .accessibilityLabel("\(model.me?.name ?? ""), settings")

                    VStack(spacing: 2) {
                        ForEach(ListFilter.allCases) { f in
                            let current = nav.filter == f
                            row(sym: f.sym, title: f.title, count: f == .unread ? unreadCount : 0, current: current) {
                                nav.toList(filter: f)
                            }
                        }
                    }
                    .padding(.top, 20)

                    VStack(spacing: 2) {
                        row(sym: .photo, title: "Moments", dot: model.momentsDot, current: false) {
                            model.momentsDot = false
                            nav.switchPage(.moments)
                        }
                        row(sym: .photoStack, title: "Memories", current: false) {
                            nav.switchPage(.memories)
                        }
                    }
                    .padding(.top, 20)
                }
                .padding(.top, 4)
                .padding(.leading, inset)
                .padding(.trailing, ctx.usesRail ? 12 : inset)
                .padding(.bottom, 20)
            }
            // Home floats at the top like every page's title.
            .safeAreaBar(edge: .top, spacing: 0) {
                Text("Home")
                    .font(.largeTitleC)
                    .tracking(-0.68)
                    .foregroundStyle(Theme.fbBlueTitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 30)
                    .padding(.bottom, 14)
                    .padding(.leading, inset)
                    .padding(.trailing, ctx.usesRail ? 12 : inset)
            }
            .safeAreaPadding(EdgeInsets(top: ctx.insets.top, leading: ctx.insets.leading,
                                        bottom: ctx.usesRail ? max(ctx.insets.bottom, 16) + 24 : ctx.barClearance + 20,
                                        trailing: ctx.usesRail ? railContent : ctx.insets.trailing))
            .scrollBounceBehavior(.basedOnSize)
            .scrollEdgeEffectStyle(.soft, for: .top)

            if !(nav.columns == 2 && nav.leading == .sidebar) || ctx.usesRail {
                ColumnBar(footActions: [
                    BarItem(id: "search", sym: .search, title: "Search") {
                        nav.toList()
                        withAnimation(Motion.ui) { nav.searching = true }
                    }
                ])
            }
        }
    }

    /// Content runs up to the rail and the gap before it.
    private var railContent: CGFloat {
        guard let rail = ctx.rail else { return ctx.insets.trailing }
        return max(ctx.insets.trailing + 16, rail.centerFromEdge + Bar.railWidth / 2 + 12)
    }

    private func row(sym: Sym, title: LocalizedStringKey, count: Int = 0, dot: Bool = false, current: Bool,
                     action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: 12) {
                SymbolView(sym, size: 19, weight: current ? 2.2 : nil)
                    .foregroundStyle(Theme.fbBlueTitle)
                    .frame(width: 24)
                Text(title)
                    .font(AppFont.make(17, current ? .semibold : .regular))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if count > 0 {
                    Text("\(count)")
                        .font(AppFont.make(12, .semibold).monospacedDigit())
                        .foregroundStyle(Theme.onBrand)
                        .padding(.horizontal, 7)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(Theme.badge, in: Capsule())
                        .contentTransition(.numericText())
                }
                if dot {
                    Circle().fill(Theme.red).frame(width: 9, height: 9).padding(.trailing, 6)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
            .background {
                if current {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.fill3)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(FillPressStyle(radius: 14, fill: Theme.fill4))
        .animation(Motion.quick, value: current)
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

/// The web's :active background on rows and cards (no scale).
struct FillPressStyle: ButtonStyle {
    var radius: CGFloat
    var fill: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
                    .opacity(configuration.isPressed ? 1 : 0)
            }
            .animation(configuration.isPressed ? nil : Motion.quick, value: configuration.isPressed)
    }
}

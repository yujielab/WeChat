import SwiftUI

/// The first column: who you are (opens Settings), the chat filters (only
/// Unread carries a number) and the other places — Moments, Memories,
/// Requests — for devices without the Duo page capsule.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    @Environment(\.column) private var ctx

    var body: some View {
        ZStack {
            Theme.paper
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Home")
                        .font(.largeTitleC)
                        .foregroundStyle(Theme.blue)
                        .padding(.horizontal, 20)
                        .padding(.top, 10)

                    Button { nav.settingsOpen = true } label: {
                        HStack(spacing: 14) {
                            Avatar(user: model.me, size: 56, online: model.connected)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.me?.name ?? "").font(.title3C).foregroundStyle(Theme.label)
                                Text(model.connected ? "@\(model.me?.username ?? "")" : String(localized: "Connecting…"))
                                    .font(.footnoteC).foregroundStyle(Theme.label2)
                                    .contentTransition(.opacity)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.label3)
                        }
                        .padding(14)
                        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    }
                    .buttonStyle(.press)
                    .padding(.horizontal, 16)

                    group {
                        ForEach(ListFilter.allCases) { f in
                            row(symbol: f.symbol, title: f.title,
                                count: f == .unread ? model.rooms.filter { $0.unread > 0 || $0.marked }.count : 0,
                                selected: nav.filter == f && nav.page == .chats && nav.isVisible(.list)) {
                                nav.toList(filter: f)
                            }
                        }
                    }

                    group {
                        row(symbol: "photo.on.rectangle.angled", title: "Moments", dot: model.momentsDot, selected: nav.page == .moments) {
                            model.momentsDot = false
                            nav.switchPage(.moments)
                        }
                        row(symbol: "sparkles.rectangle.stack", title: "Memories", selected: nav.page == .memories) {
                            nav.switchPage(.memories)
                        }
                        row(symbol: "person.badge.plus", title: "Requests", count: model.requests.count, selected: nav.page == .requests) {
                            nav.switchPage(.requests)
                        }
                        row(symbol: "person.2", title: "Friends", selected: false) {
                            nav.newChatOpen = true
                        }
                        row(symbol: "person.crop.circle", title: "Your profile", selected: nav.page == .me) {
                            nav.switchPage(.me)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
            .safeAreaPadding(EdgeInsets(top: ctx.insets.top, leading: ctx.insets.leading,
                                        bottom: ctx.usesRail ? ctx.insets.bottom + 12 : ctx.barClearance, trailing: ctx.insets.trailing))

            ColumnBar(actions: [
                BarItem(id: "search", symbol: "magnifyingglass", title: "Search") {
                    nav.toList()
                    nav.searching = true
                },
                BarItem(id: "new", symbol: "square.and.pencil", title: "New chat") { nav.newChatOpen = true }
            ])
        }
    }

    private func group<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 2) { content() }
            .padding(6)
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 16)
    }

    private func row(symbol: String, title: LocalizedStringKey, count: Int = 0, dot: Bool = false, selected: Bool,
                     action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.blue)
                    .frame(width: 26)
                Text(title).font(.bodyC).foregroundStyle(Theme.label)
                Spacer()
                if count > 0 {
                    Text("\(count)").font(.subheadMediumC.monospacedDigit()).foregroundStyle(Theme.label2)
                }
                if dot { Circle().fill(Theme.red).frame(width: 8, height: 8) }
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(selected ? Theme.fillQuiet : .clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.press(0.98))
    }
}

import SwiftUI

/// The pages open as sheets over the strip (the web's openSheet): a card
/// with a grabber, in the content column on one screen, centred on two;
/// swipe it down or tap the receded strip to close. One sheet at a time;
/// Settings and someone's page open over a page.
struct PageSheetLayer: View {
    let geo: StripGeometry
    @Environment(Nav.self) private var nav
    @Environment(AppModel.self) private var model
    @State private var drag: CGFloat = 0

    private enum Kind: Equatable {
        case page(Page)
        case settings
        case profile(String)
    }

    private var kind: Kind? {
        if nav.settingsOpen { return .settings }
        if let p = nav.profile { return .profile(p) }
        if nav.page != .chats { return .page(nav.page) }
        return nil
    }

    var body: some View {
        let f = geo.sheetFrame
        ZStack(alignment: .topLeading) {
            if let kind {
                card(kind)
                    .frame(width: f.width, height: f.height)
                    .background(Theme.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 30, y: 10)
                    .overlay(alignment: .top) { grabber }
                    .offset(x: f.minX, y: f.minY + max(0, drag))
                    .environment(\.column, geo.sheetContext)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(kindKey(kind))
            }
        }
        .animation(Motion.move, value: kind)
    }

    private func kindKey(_ k: Kind) -> String {
        switch k {
        case .page(let p): return "page-\(p.rawValue)"
        case .settings: return "settings"
        case .profile(let id): return "profile-\(id)"
        }
    }

    @ViewBuilder
    private func card(_ k: Kind) -> some View {
        switch k {
        case .page(.moments): MomentsPage()
        case .page(.memories): MemoriesPage()
        case .page(.friends): FriendsPage()
        case .page(.me): ProfileView(userId: model.me?.id ?? "", asPage: true)
        case .page(.chats): EmptyView()
        case .settings: SettingsView()
        case .profile(let id): ProfileView(userId: id)
        }
    }

    private var grabber: some View {
        ZStack(alignment: .top) {
            Color.clear.frame(height: 28).contentShape(Rectangle())
            Capsule().fill(Theme.label4).frame(width: 36, height: 5).padding(.top, 7)
        }
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { drag = $0.translation.height }
                .onEnded { v in
                    if v.translation.height > 120 || v.predictedEndTranslation.height > 300 {
                        withAnimation(Motion.move) {
                            drag = 0
                            close()
                        }
                    } else {
                        withAnimation(Motion.ui) { drag = 0 }
                    }
                }
        )
        .accessibilityLabel("Close")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { close() }
    }

    private func close() {
        if nav.settingsOpen { nav.settingsOpen = false }
        else if nav.profile != nil { nav.profile = nil }
        else { nav.page = .chats }
    }
}

/// A sheet's header as the web draws it: a bold title (or a coloured large
/// one), and round glass buttons either side.
struct SheetHeader<Leading: View, Trailing: View>: View {
    var title: LocalizedStringKey
    var large = false
    var color: Color = Theme.label
    var centered = false
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ZStack {
            if centered {
                Text(title).font(.headlineC).foregroundStyle(color)
            }
            HStack(spacing: 10) {
                leading()
                if !centered {
                    Text(title)
                        .font(large ? AppFont.make(26, .bold) : AppFont.make(20, .bold))
                        .tracking(large ? -0.4 : 0)
                        .foregroundStyle(color)
                }
                Spacer(minLength: 0)
                trailing()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }
}

extension SheetHeader where Leading == EmptyView {
    init(title: LocalizedStringKey, large: Bool = false, color: Color = Theme.label, centered: Bool = false, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(title: title, large: large, color: color, centered: centered, leading: { EmptyView() }, trailing: trailing)
    }
}

/// The round close button the sheets carry (a glass circle with an ×).
struct SheetClose: View {
    @Environment(Nav.self) private var nav
    var sym: Sym = .xmark
    var action: (() -> Void)? = nil

    var body: some View {
        GlassIconButton(sym: sym, title: "Close") {
            if let action { action() } else {
                withAnimation(Motion.move) {
                    if nav.settingsOpen { nav.settingsOpen = false }
                    else if nav.profile != nil { nav.profile = nil }
                    else { nav.page = .chats }
                }
            }
        }
    }
}

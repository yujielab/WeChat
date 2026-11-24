import SwiftUI

/// A note opens as a card over the app (the web's note sheet): as tall as it
/// needs, on the foot of the app's side (above the keyboard), centred when
/// unfolded; the app recedes behind it. Drag the grabber down, or tap the
/// app, to close.
struct DialogLayer: View {
    let geo: StripGeometry
    @Environment(Nav.self) private var nav
    @Environment(AppModel.self) private var model
    @State private var drag: CGFloat = 0

    private enum Kind: Equatable {
        case noteEditor
        case note(FriendNote)
        case filters(FilterCard)

        var grabbed: Bool {
            if case .filters = self { return false }
            return true
        }
    }

    private var kind: Kind? {
        if let f = nav.filterCard { return .filters(f) }
        if nav.noteEditor { return .noteEditor }
        if let n = nav.openNote { return .note(n) }
        return nil
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let kind {
                let f = frame(kind)
                card(kind)
                    .padding(.top, geo.columns == 1 && kind.grabbed ? 20 : 0)
                    .frame(width: f.width, height: f.height, alignment: .top)
                    .background(kind.grabbed ? Theme.paper : Theme.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                    .shadow(color: .black.opacity(0.22), radius: 32, y: 24)
                    .overlay(alignment: .top) { if geo.columns == 1 && kind.grabbed { grabber } }
                    // Down it follows the finger; up it gives a little and resists.
                    .offset(x: f.minX, y: f.minY + (drag >= 0 ? drag : -min(24, sqrt(-drag) * 2.4)))
                    .environment(\.column, geo.sheetContext)
                    .transition(geo.columns == 1
                        ? AnyTransition.offset(y: f.height + 40)
                        : AnyTransition.opacity.combined(with: .scale(scale: 0.96)).combined(with: .blur(4)))
                    .id(key(kind))
            }
        }
        .animation(Motion.bouncy, value: kind)
    }

    private func key(_ k: Kind) -> String {
        switch k {
        case .noteEditor: return "note-editor"
        case .note(let n): return "note-\(n.id)"
        case .filters(let f): return "filters-\(f)"
        }
    }

    @ViewBuilder
    private func card(_ k: Kind) -> some View {
        switch k {
        case .noteEditor: NoteEditor()
        case .note(let n): NoteSheet(note: n)
        case .filters(let f): FilterCardView(kind: f)
        }
    }

    private func frame(_ k: Kind) -> CGRect {
        let full = geo.sheetFrame
        let h: CGFloat
        switch k {
        case .noteEditor: h = model.myNote != nil ? 450 : 390
        case .note: h = 400
        case .filters(.list): h = 64 + 1 + 16 + CGFloat(ListFilter.allCases.count) * 52 + 16 + 98
        }
        let bottomGap = geo.keyboard > 0 ? geo.keyboard + 8 : max(8, geo.insets.bottom - 18)
        if geo.columns == 1 {
            let height = min(h, geo.size.height - bottomGap - geo.insets.top - 26)
            return CGRect(x: full.minX, y: geo.size.height - bottomGap - height, width: full.width, height: height)
        }
        let room = geo.size.height - (geo.keyboard > 0 ? geo.keyboard : 0)
        let height = min(h, room - 32)
        return CGRect(x: full.minX, y: max(16, (room - height) / 2), width: full.width, height: height)
    }

    private var grabber: some View {
        ZStack(alignment: .top) {
            Color.clear.frame(height: 28).contentShape(Rectangle())
            Capsule().fill(Theme.separatorOpaque).frame(width: 32, height: 4).padding(.top, 8)
        }
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { drag = $0.translation.height }
                .onEnded { v in
                    if v.translation.height > 120 || v.predictedEndTranslation.height > 300 {
                        withAnimation(Motion.move) { drag = 0 }
                        nav.closeTop()
                    } else {
                        withAnimation(Motion.ui) { drag = 0 }
                    }
                }
        )
        .accessibilityLabel("Close")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { nav.closeTop() }
    }
}

/// Filters as a card (after X's): the name and × across the top over a
/// hairline, each choice a row with its check, then Reset and Done.
struct FilterCardView: View {
    let kind: FilterCard
    @Environment(Nav.self) private var nav

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Filters").font(AppFont.make(22, .bold)).tracking(-0.44).foregroundStyle(Theme.label)
                Spacer()
                Button { nav.closeTop() } label: {
                    SymbolView(.xmark, size: 24, weight: 2.2).foregroundStyle(Theme.label)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.press(0.9))
                .accessibilityLabel("Close")
            }
            .padding(.leading, 24)
            .padding(.trailing, 14)
            .frame(minHeight: 64)
            Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 24)

            VStack(spacing: 0) {
                switch kind {
                case .list:
                    ForEach(ListFilter.allCases) { f in
                        choice(f.title, on: nav.filter == f) { withAnimation(Motion.ui) { nav.filter = f } }
                    }
                }
            }
            .padding(.vertical, 16)

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Button {
                    Haptics.tap()
                    withAnimation(Motion.ui) {
                        switch kind {
                        case .list: nav.filter = .all
                        }
                    }
                } label: {
                    Text("Reset").font(AppFont.make(17, .bold)).foregroundStyle(Theme.label)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Theme.fill4, in: Capsule())
                }
                .buttonStyle(.press)
                Button { nav.closeTop() } label: {
                    Text("Done").font(AppFont.make(17, .bold)).foregroundStyle(Theme.onInk)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Theme.ink, in: Capsule())
                }
                .buttonStyle(.press)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private func section(_ t: LocalizedStringKey) -> some View {
        Text(t)
            .textCase(.uppercase)
            .font(AppFont.make(12, .medium)).tracking(0.6)
            .foregroundStyle(Theme.label2)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .bottomLeading)
            .padding(.horizontal, 24)
            .padding(.bottom, 4)
    }

    private func choice(_ t: LocalizedStringKey, on: Bool, pick: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            pick()
        } label: {
            HStack {
                Text(t).font(AppFont.make(17, on ? .bold : .regular)).foregroundStyle(Theme.label)
                Spacer()
                SymbolView(.check, size: 15, weight: 2.4)
                    .foregroundStyle(Theme.onInk)
                    .opacity(on ? 1 : 0)
                    .frame(width: 26, height: 26)
                    .background(on ? Theme.ink : .clear, in: Circle())
                    .overlay(Circle().strokeBorder(on ? .clear : Theme.label3, lineWidth: 1.5))
                    .animation(.easeOut(duration: 0.14), value: on)
            }
            .padding(.horizontal, 24)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(FillPressStyle(radius: 0, fill: Theme.fill4))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

extension AnyTransition {
    /// Comes in from a blur (the unfolded form sheet's materialising).
    static func blur(_ radius: CGFloat) -> AnyTransition {
        .modifier(active: BlurTransition(radius: radius), identity: BlurTransition(radius: 0))
    }
}

private struct BlurTransition: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

extension Theme {
    static let separatorOpaque = Color.token(0xc6c6c8, 0x38383a)
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
                        .font(large ? AppFont.make(24, .bold) : AppFont.make(20, .bold))
                        .tracking(-0.4)
                        .foregroundStyle(color)
                }
                Spacer(minLength: 0)
                trailing()
            }
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 56)
        .padding(.bottom, 12)
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
            if let action { action() } else { nav.closeTop() }
        }
    }
}

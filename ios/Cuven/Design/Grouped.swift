import SwiftUI

// Grouped lists as iOS draws them: cards with a flat face on the grouped
// background, no outline, tint or shadow; 58pt cells; monochrome 30pt icon
// tiles; eyebrows in small tracked caps; the iOS switch in ink.

/// A card of cells.
struct GroupCard<Content: View>: View {
    var radius: CGFloat = 23
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Theme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// An eyebrow over a card.
struct GroupTitle: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .textCase(.uppercase)
            .font(AppFont.make(12, .medium))
            .tracking(0.6)
            .foregroundStyle(Theme.label2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 26)
            .padding(.bottom, 9)
    }
}

/// A note under a card.
struct GroupFoot: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .font(.footnoteC)
            .lineSpacing(3)
            .foregroundStyle(Theme.label2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 10)
    }
}

/// The hairline between cells, from the text's edge.
struct CellSeparator: View {
    var leading: CGFloat = 16
    var body: some View {
        Rectangle().fill(Theme.separator).opacity(0.45).frame(height: 0.5).padding(.leading, leading)
    }
}

/// A monochrome tile: the label says what a row is, not a colour.
struct CellIcon: View {
    let sym: Sym
    var tint: Color = Theme.label
    var slashed = false
    var body: some View {
        SymbolView(sym, size: 18, slashed: slashed)
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A cell: an optional tile, the words, and what's at its end.
struct Cell<Trailing: View>: View {
    var icon: Sym?
    var iconTint: Color = Theme.label
    let title: LocalizedStringKey
    var subtitle: String?
    var color: Color = Theme.label
    var chevron = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let icon { CellIcon(sym: icon, tint: iconTint) }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.bodyC).foregroundStyle(color)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.footnoteC).lineSpacing(3).foregroundStyle(Theme.label2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
            if chevron { SymbolView(.chevronRight, size: 14).foregroundStyle(Theme.label3) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(minHeight: 58)
        .contentShape(Rectangle())
    }
}

extension Cell where Trailing == EmptyView {
    init(icon: Sym? = nil, iconTint: Color = Theme.label, title: LocalizedStringKey, subtitle: String? = nil,
         color: Color = Theme.label, chevron: Bool = false) {
        self.init(icon: icon, iconTint: iconTint, title: title, subtitle: subtitle, color: color, chevron: chevron) { EmptyView() }
    }
}

/// A tappable cell: the web's :active fill-3.
struct CellButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.fill3 : .clear)
            .animation(configuration.isPressed ? nil : Motion.quick, value: configuration.isPressed)
    }
}

/// The iOS switch at 51×31, its track turning to ink with the knob (200ms).
struct InkToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            Haptics.selection()
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 0)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Theme.ink : Theme.fill)
                        .frame(width: 51, height: 31)
                    Circle()
                        .fill(configuration.isOn ? Theme.onInk : Color.white)
                        .frame(width: 27, height: 27)
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 3)
                        .shadow(color: .black.opacity(0.06), radius: 0.5, y: 3)
                        .padding(2)
                }
                .animation(.timingCurve(0.25, 1.15, 0.5, 1, duration: 0.2), value: configuration.isOn)
                .contentShape(Rectangle().inset(by: -7))
            }
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

extension ToggleStyle where Self == InkToggleStyle {
    static var ink: InkToggleStyle { InkToggleStyle() }
}

/// One ink capsule that keeps its identity as the selection changes (.seg).
struct InkSegmented<Value: Hashable>: View {
    let options: [(Value, LocalizedStringKey)]
    @Binding var selection: Value
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                let on = o.0 == selection
                Button {
                    withAnimation(Motion.ui) { selection = o.0 }
                } label: {
                    Text(o.1)
                        .font(AppFont.make(15, on ? .bold : .regular))
                        .foregroundStyle(on ? Theme.onInk : Theme.label2)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, options.count > 3 ? 7 : 14)
                        .frame(minHeight: 34)
                        .background {
                            if on { Capsule().fill(Theme.ink).matchedGeometryEffect(id: "seg", in: ns) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .glassCapsule(interactive: false)
    }
}

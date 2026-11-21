import SwiftUI

// MARK: - Glass (the web's .glass: a frosted base with a rim; native Liquid Glass here)

struct GlassSurface<S: InsettableShape>: ViewModifier {
    var shape: S
    var tint: Color?
    var interactive: Bool
    /// Glass that morphs: pieces with ids in one GlassGroup flow into one
    /// another as they appear, go and change (HIG, Materials: Liquid Glass).
    var morphID: String? = nil
    var morphSpace: Namespace.ID? = nil
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("ui:glass") private var glassMode = "auto"

    func body(content: Content) -> some View {
        if reduceTransparency || glassMode == "solid" {
            content
                .background(tint ?? Theme.glassSolid, in: shape)
                .overlay(shape.strokeBorder(Theme.line, lineWidth: 0.5))
        } else if let morphID, let morphSpace {
            content
                .glassEffect(makeGlass(), in: shape)
                .glassEffectID(morphID, in: morphSpace)
                .glassEffectTransition(.matchedGeometry)
        } else {
            content.glassEffect(makeGlass(), in: shape)
        }
    }

    private func makeGlass() -> Glass {
        var g = Glass.regular
        // Clear Liquid Glass throughout; a tint only where a control asks for one.
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

extension View {
    func glass<S: InsettableShape>(_ shape: S, tint: Color? = nil, interactive: Bool = true) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint, interactive: interactive))
    }
    /// Glass that morphs with the other pieces of its GlassGroup.
    func glass<S: InsettableShape>(_ shape: S, tint: Color? = nil, interactive: Bool = true, morph id: String, in space: Namespace.ID) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint, interactive: interactive, morphID: id, morphSpace: space))
    }
    func glassCapsule(tint: Color? = nil, interactive: Bool = true) -> some View {
        glass(Capsule(), tint: tint, interactive: interactive)
    }
    func glassCircle(tint: Color? = nil, interactive: Bool = true) -> some View {
        glass(Circle(), tint: tint, interactive: interactive)
    }
    /// The web's blue glass (the list's Search, the filter thumb): Facebook blue at 80%.
    func blueGlass<S: InsettableShape>(_ shape: S) -> some View {
        glass(shape, tint: Theme.fbBlue.opacity(0.8), interactive: true)
    }
}

/// Glass shapes that blend and morph into each other.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: () -> Content
    var body: some View { GlassEffectContainer(spacing: spacing) { content() } }
}

// MARK: - Press (tokens.css: in at once to 0.98, out gently from wherever it got)

struct PressStyle: ButtonStyle {
    var scale: CGFloat = Motion.pressScale
    var dim: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .brightness(configuration.isPressed && dim ? -0.03 : 0)
            .animation(configuration.isPressed ? Motion.pressIn : Motion.pressOut, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressStyle {
    static var press: PressStyle { PressStyle() }
    static func press(_ scale: CGFloat) -> PressStyle { PressStyle(scale: scale) }
}

/// A row's press: the web darkens it to --paper at once, no scale.
struct RowPressStyle: ButtonStyle {
    var radius: CGFloat = 18
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.paper : .clear, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .animation(configuration.isPressed ? nil : Motion.quick, value: configuration.isPressed)
    }
}

// MARK: - Bar items (glass-btn: 44pt, a 22pt glyph)

enum Bar {
    static let height: CGFloat = 44
    /// The bars at a column's foot (the search pill, the composer): 56pt.
    static let foot: CGFloat = 56
    static let gap: CGFloat = 10
    static let railWidth: CGFloat = 52
}

struct GlassIconButton: View {
    let sym: Sym
    var system: String? = nil
    let title: LocalizedStringKey
    var tint: Color? = nil
    var foreground: Color = Theme.label
    var badge: Int = 0
    var badgeInk = false
    var size: CGFloat = Bar.height
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            BarGlyph(sym: sym, system: system, size: 22)
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .contentShape(Circle())
                .glassCircle(tint: tint)
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Badge(count: badge, color: badgeInk ? Theme.ink : Theme.red, text: badgeInk ? Theme.onInk : .white, small: true)
                            .offset(x: 4, y: -4)
                    }
                }
        }
        .buttonStyle(.press)
        .accessibilityLabel(Text(title))
    }
}

/// The web's count badge: a pill at 20pt (18 small), bold digits.
struct Badge: View {
    let count: Int
    var color: Color = Theme.badge
    var text: Color = Theme.onBrand
    var small = false

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(AppFont.make(small ? 11 : 12, .semibold).monospacedDigit())
            .foregroundStyle(text)
            .padding(.horizontal, count > 9 ? 5 : 0)
            .frame(minWidth: small ? 18 : 20, minHeight: small ? 18 : 20)
            .background(color, in: Capsule())
            .contentTransition(.numericText())
    }
}

extension Theme {
    static let badge = brandStrong
}

// MARK: - Avatar (views/avatar.js: a monogram that cross-fades to the photo)

struct Avatar: View {
    var path: String = ""
    var name: String = ""
    var size: CGFloat = 52
    var room = false
    var online = false
    var ring = false

    init(user: User?, size: CGFloat = 52, online: Bool = false, ring: Bool = false) {
        path = user?.avatar ?? ""
        name = user?.name ?? ""
        self.size = size
        self.online = online
        self.ring = ring
    }

    init(path: String, name: String, id: String = "", size: CGFloat = 52, room: Bool = false, online: Bool = false) {
        self.path = path
        self.name = name
        self.size = size
        self.room = room
        self.online = online
    }

    var body: some View {
        let colors = Theme.avatarColors(name)
        let shape = RoundedRectangle(cornerRadius: room ? size * 0.3 : size / 2, style: .continuous)
        ZStack {
            colors.bg
            Text(Theme.initials(name))
                .font(AppFont.make(size * 0.4, .semibold))
                .tracking(-0.01 * size * 0.4)
                .foregroundStyle(colors.fg)
                .minimumScaleFactor(0.5)
            if !path.isEmpty {
                RemoteImage(path, maxPixel: size * 3, placeholder: .clear)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.imageOutline, lineWidth: 0.5))
        .padding(ring ? 3 : 0)
        .overlay {
            if ring {
                Circle().strokeBorder(
                    AngularGradient(colors: [Color(hex: 0xfeda75), Color(hex: 0xfa7e1e), Color(hex: 0xd62976), Color(hex: 0x962fbf), Color(hex: 0x4f5bd5), Color(hex: 0xfeda75)], center: .center),
                    lineWidth: 2.5)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if online {
                Circle()
                    .fill(Theme.green)
                    .frame(width: max(10, size * 0.27), height: max(10, size * 0.27))
                    .overlay(Circle().stroke(Theme.bg, lineWidth: max(2, size * 0.055)))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Misc

struct Hairline: View {
    var color: Color = Theme.separator
    var body: some View {
        Rectangle().fill(color).frame(height: 0.5)
    }
}

/// The web's primary button: an ink pill (red for a destructive one).
struct PrimaryButton: View {
    let title: LocalizedStringKey
    var destructive = false
    var loading = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(loading ? 0 : 1)
                if loading { ProgressView().tint(Theme.onInk) }
            }
            .font(.headlineC)
            .foregroundStyle(destructive ? Color.white : Theme.onInk)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(destructive ? Theme.red : Theme.ink, in: Capsule())
            .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.press)
        .disabled(!enabled || loading)
    }
}

/// A small ink pill (Accept, Share a moment) or a quiet grey one (Cancel).
struct PillButton: View {
    let title: LocalizedStringKey
    var style: Style = .ink
    let action: () -> Void
    enum Style { case ink, quiet, blue, outline }

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Text(title)
                .font(.subheadBoldC)
                .foregroundStyle(fg)
                .padding(.horizontal, 16)
                .frame(height: 34)
                .background(bg, in: Capsule())
                .overlay { if style == .outline { Capsule().strokeBorder(Theme.ink, lineWidth: 1.5) } }
        }
        .buttonStyle(.press)
    }

    private var fg: Color {
        switch style {
        case .ink: return Theme.onInk
        case .quiet: return Theme.label
        case .blue: return .white
        case .outline: return Theme.blueText
        }
    }

    private var bg: Color {
        switch style {
        case .ink: return Theme.ink
        case .quiet: return Theme.fill4
        case .blue: return Theme.fbBlue
        case .outline: return .clear
        }
    }
}

/// The web's toast: a glass capsule at the top, centred.
struct ToastView: View {
    let toast: Toast
    var onUndo: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            if toast.isError { SymbolView(.exclaim, size: 18).foregroundStyle(Theme.red) }
            Text(toast.text).font(.subheadMediumC).foregroundStyle(Theme.label).lineLimit(2)
            if toast.undo != nil {
                Button(action: onUndo) {
                    Text("Undo").font(.subheadBoldC).foregroundStyle(Theme.blueText)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.press(0.94))
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, toast.undo == nil ? 18 : 8)
        .padding(.vertical, toast.undo == nil ? 12 : 6)
        .frame(minHeight: 44)
        .glassCapsule(interactive: false)
        .padding(.horizontal, 24)
    }
}

/// Skeletons are the real shapes with bars where the words go (ui/skeleton.js).
struct SkeletonBar: View {
    var width: CGFloat
    var height: CGFloat = 12

    init(width: CGFloat, height: CGFloat = 12) {
        self.width = width
        self.height = height
    }

    var body: some View {
        Capsule().fill(Theme.fill4).frame(width: width, height: height)
            .phaseAnimator([1.0, 0.55]) { v, phase in v.opacity(phase) } animation: { _ in .easeInOut(duration: 0.9) }
    }
}

extension View {
    @ViewBuilder func `if`<V: View>(_ condition: Bool, transform: (Self) -> V) -> some View {
        if condition { transform(self) } else { self }
    }
}

/// A bar item's glyph: the web's own, or a system symbol where it has none.
struct BarGlyph: View {
    let sym: Sym
    var system: String? = nil
    var size: CGFloat = 22

    var body: some View {
        if let system {
            Image(systemName: system)
                .font(.system(size: size * 0.86, weight: .medium))
                .frame(width: size, height: size)
        } else {
            SymbolView(sym, size: size)
        }
    }
}

/// The Clear button at a text field's trailing end, there while it has
/// text (HIG, Text fields: help people erase their input).
struct ClearButton: View {
    @Binding var text: String

    var body: some View {
        if !text.isEmpty {
            Button {
                Haptics.tap()
                text = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.label3)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .scale(scale: 0.6)))
            .accessibilityLabel("Clear")
        }
    }
}

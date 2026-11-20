import SwiftUI

// MARK: - Glass

/// Liquid Glass on iOS 26 (interactive, refracting); a frosted material with
/// a hairline rim and a faint contact shadow before that, and solid when
/// Reduce Transparency is on.
struct GlassSurface<S: InsettableShape>: ViewModifier {
    var shape: S
    var tint: Color?
    var interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(tint ?? Theme.elevated, in: shape)
                .overlay(shape.strokeBorder(Theme.line, lineWidth: 1))
        } else {
            glassy(content)
        }
    }

    @ViewBuilder
    private func glassy(_ content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(makeGlass(), in: shape)
        } else {
            content
                .background {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(tint?.opacity(0.85) ?? Theme.glassFrost)
                    }
                }
                .overlay {
                    shape.strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.22 : 0.95),
                                                Color.white.opacity(scheme == .dark ? 0.06 : 0.4)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.75)
                }
                .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.08), radius: 10, y: 4)
        }
    }

    @available(iOS 26.0, *)
    private func makeGlass() -> Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

extension View {
    func glass<S: InsettableShape>(_ shape: S, tint: Color? = nil, interactive: Bool = true) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint, interactive: interactive))
    }

    func glassCapsule(tint: Color? = nil, interactive: Bool = true) -> some View {
        glass(Capsule(), tint: tint, interactive: interactive)
    }

    func glassCircle(tint: Color? = nil, interactive: Bool = true) -> some View {
        glass(Circle(), tint: tint, interactive: interactive)
    }
}

/// Groups glass shapes so they blend and morph into each other on iOS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

// MARK: - Press

/// Pressing lands at once (0.97 and a touch darker) and springs back from
/// wherever it got to.
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? -0.035 : 0)
            .animation(configuration.isPressed ? Motion.pressIn : Motion.pressOut, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressStyle {
    static var press: PressStyle { PressStyle() }
    static func press(_ scale: CGFloat) -> PressStyle { PressStyle(scale: scale) }
}

// MARK: - Bar items

enum Bar {
    static let height: CGFloat = 52
    static let gap: CGFloat = 10
}

/// One control in a floating bar: a glass circle with a symbol, a title for
/// accessibility and the overflow menu, and an optional badge.
struct GlassIconButton: View {
    let symbol: String
    let title: LocalizedStringKey
    var tint: Color? = nil
    var foreground: Color = Theme.label
    var badge: Int = 0
    var size: CGFloat = Bar.height
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .contentShape(Circle())
                .glassCircle(tint: tint)
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Badge(count: badge).offset(x: 4, y: -4)
                    }
                }
        }
        .buttonStyle(.press(0.92))
        .accessibilityLabel(Text(title))
        .help(Text(title))
    }
}

struct Badge: View {
    let count: Int
    var color: Color = Theme.blue

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 12, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, count > 9 ? 5 : 0)
            .frame(minWidth: 20, minHeight: 20)
            .background(color, in: Capsule())
            .overlay(Capsule().stroke(Theme.bg, lineWidth: 2))
            .contentTransition(.numericText())
    }
}

// MARK: - Avatar

struct Avatar: View {
    var user: User?
    var path: String = ""
    var name: String = ""
    var id: String = ""
    var size: CGFloat = 44
    var online = false
    var ring = false

    init(user: User?, size: CGFloat = 44, online: Bool = false, ring: Bool = false) {
        self.user = user
        self.path = user?.avatar ?? ""
        self.name = user?.name ?? ""
        self.id = user?.id ?? ""
        self.size = size
        self.online = online
        self.ring = ring
    }

    init(path: String, name: String, id: String, size: CGFloat = 44, online: Bool = false) {
        self.path = path
        self.name = name
        self.id = id
        self.size = size
        self.online = online
    }

    var body: some View {
        let tint = Theme.tint(for: id.isEmpty ? name : id)
        ZStack {
            if !path.isEmpty {
                RemoteImage(path, maxPixel: size * 3, placeholder: tint.0)
            } else {
                tint.0
                Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                    .font(AppFont.make(size * 0.42, .medium))
                    .foregroundStyle(tint.1)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.black.opacity(0.06), lineWidth: 0.5))
        .padding(ring ? 3 : 0)
        .overlay {
            if ring {
                Circle().strokeBorder(
                    AngularGradient(colors: [Theme.sky, Color(hex: 0x8a5cf6), Color(hex: 0xff5f8f), Color(hex: 0xffb340), Theme.sky], center: .center),
                    lineWidth: 2.5)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if online {
                Circle()
                    .fill(Theme.green)
                    .frame(width: max(10, size * 0.26), height: max(10, size * 0.26))
                    .overlay(Circle().stroke(Theme.bg, lineWidth: max(2, size * 0.05)))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Misc

struct Hairline: View {
    var body: some View {
        Rectangle().fill(Theme.separator).frame(height: 1 / UIScreen.main.scale)
    }
}

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
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(destructive ? Theme.red : Theme.ink, in: Capsule())
            .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.press)
        .disabled(!enabled || loading)
    }
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 8) {
            if toast.isError {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.red)
            }
            Text(toast.text).font(.subheadMediumC).foregroundStyle(Theme.label).lineLimit(2)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassCapsule(interactive: false)
        .padding(.horizontal, 24)
    }
}

/// A skeleton bar the length of the text it stands for.
struct SkeletonBar: View {
    var width: CGFloat
    var height: CGFloat = 12
    @State private var phase = false

    var body: some View {
        Capsule()
            .fill(Theme.fillQuiet)
            .frame(width: width, height: height)
            .opacity(phase ? 0.55 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: phase)
            .onAppear { phase = true }
    }
}

extension View {
    @ViewBuilder func `if`<V: View>(_ condition: Bool, transform: (Self) -> V) -> some View {
        if condition { transform(self) } else { self }
    }
}

import SwiftUI
import Lottie

/// A Telegram sticker: still (WebP), animated (Lottie, played only while on
/// screen, uncovered and the app is in front, as on the web) or video (its
/// still picture; iOS can't play WebM).
struct StickerView: View {
    let id: String
    let kind: String
    let emoji: String
    let set: String?
    var noThumb = false
    var size: CGFloat = 120
    var animate = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var failed = false

    init(meta: MessageMeta?, size: CGFloat = 120) {
        id = meta?.id ?? ""
        kind = meta?.kind ?? "static"
        emoji = meta?.emoji ?? ""
        set = meta?.set
        self.size = size
    }

    init(sticker: Sticker, set: String?, size: CGFloat = 72, animate: Bool = true) {
        id = sticker.id
        kind = sticker.kind
        emoji = sticker.emoji
        self.set = set
        noThumb = sticker.nt
        self.size = size
        self.animate = animate
    }

    var body: some View {
        ZStack {
            if kind == "animated" && animate && !reduceMotion {
                LottieSticker(path: AppModel.stickerPath(id, set: set, anim: true)) {
                    still
                }
            } else {
                still
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text(emoji.isEmpty ? String(localized: "Sticker") : emoji))
    }

    @ViewBuilder
    private var still: some View {
        if kind == "static" || !noThumb {
            RemoteImage(AppModel.stickerPath(id, set: set, thumb: kind != "static"), maxPixel: size * 3,
                        contentMode: .fit, placeholder: .clear)
        } else {
            Text(emoji.isEmpty ? "🙂" : emoji).font(.system(size: size * 0.6))
        }
    }
}

struct LottieSticker<Fallback: View>: View {
    let path: String
    @ViewBuilder var fallback: () -> Fallback
    @State private var animation: LottieAnimation?
    @State private var tried = false
    /// Plays only while on screen (a grid keeps cells it scrolled past).
    @State private var onScreen = false
    @Environment(\.scenePhase) private var scenePhase
    /// Nor under a page, or in a column off screen (still mounted there).
    @Environment(\.contentCovered) private var covered

    var body: some View {
        ZStack {
            if let animation {
                LottiePlayer(animation: animation, playing: onScreen && !covered && scenePhase == .active)
                    .transition(.opacity)
            } else {
                fallback()
            }
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .task(id: path) {
            guard animation == nil, !tried else { return }
            tried = true
            if let cached = LottieCache.shared.get(path) {
                animation = cached
                return
            }
            guard let data = await ImageStore.shared.data(path) else { return }
            let anim = await Task.detached(priority: .utility) { try? LottieAnimation.from(data: data) }.value
            if let anim {
                LottieCache.shared.set(path, anim)
                withAnimation(.easeOut(duration: 0.15)) { animation = anim }
            }
        }
    }
}

final class LottieCache: @unchecked Sendable {
    static let shared = LottieCache()
    private let cache = NSCache<NSString, LottieBox>()
    final class LottieBox { let a: LottieAnimation; init(_ a: LottieAnimation) { self.a = a } }
    func get(_ k: String) -> LottieAnimation? { cache.object(forKey: k as NSString)?.a }
    func set(_ k: String, _ a: LottieAnimation) { cache.setObject(LottieBox(a), forKey: k as NSString) }
}

struct LottiePlayer: UIViewRepresentable {
    let animation: LottieAnimation
    var playing = true

    final class Coordinator { var view: LottieAnimationView? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        // A plain container, so the animation's own size (often 512pt)
        // never pushes on the layout; the sticker's frame decides.
        let container = UIView()
        container.backgroundColor = .clear
        container.isUserInteractionEnabled = false
        let v = LottieAnimationView(animation: animation, configuration: LottieConfiguration(renderingEngine: .automatic))
        v.contentMode = .scaleAspectFit
        v.loopMode = .loop
        v.backgroundBehavior = .pauseAndRestore
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            v.topAnchor.constraint(equalTo: container.topAnchor),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        context.coordinator.view = v
        if playing { v.play() }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let v = context.coordinator.view else { return }
        if playing {
            if !v.isAnimationPlaying { v.play() }
        } else if v.isAnimationPlaying {
            v.pause()
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.view?.stop()
    }
}

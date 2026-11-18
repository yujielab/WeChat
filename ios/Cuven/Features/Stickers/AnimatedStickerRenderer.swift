import SwiftUI
import UIKit
import AVFoundation
import CuvenCore

// MARK: - Native Telegram Sticker Renderer (`WebP` + `Lottie JSON` + `AVPlayer Video`) (M10)
//
// Apple HIG & Developer Documentation Grounding:
// - Apple HIG › Motion & Accessibility (`accessibilityReduceMotion`): Viewport-gated playback —
//   stickers animate only while visible on screen and freeze cleanly to still frames when
//   Reduce Motion is enabled (`public/js/views/stickers.js:178-200`).
// - Apple Developer Documentation › `ImageIO` (`CGImageSource`), `AVFoundation` (`AVQueuePlayer` +
//   `AVPlayerLooper`), SwiftUI `TimelineView` + `Canvas` (iOS 27.1 SDK).
// - Cuven Web Parity: `120ms` anti-flash hold before emoji stand-in (`stickers.js:75-80`),
//   40-entry LRU Lottie cache (`stickers.js:152-164`), borderless rendering.

@MainActor
public final class LottieDocumentCache {
    public static let shared = LottieDocumentCache()

    private var entries: [String: LottieAnimationDocument] = [:]
    private var order: [String] = []
    private let capacity = 40

    private init() {}

    public func document(forKey key: String) -> LottieAnimationDocument? {
        entries[key]
    }

    public func insert(_ doc: LottieAnimationDocument, forKey key: String) {
        if entries[key] == nil {
            order.append(key)
            if order.count > capacity, let oldest = order.first {
                order.removeFirst()
                entries.removeValue(forKey: oldest)
            }
        }
        entries[key] = doc
    }
}

public struct AnimatedStickerRenderer: View {
    public let sticker: StickerItem
    public let size: CGFloat
    public let serverBaseURL: URL
    public let isAnimatedPlaybackAllowed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var staticImage: UIImage?
    @State private var lottieDocument: LottieAnimationDocument?
    @State private var videoPlayableURL: URL?
    @State private var showFallbackAfterHold: Bool = false
    @State private var isVisibleOnScreen: Bool = false

    public init(
        sticker: StickerItem,
        size: CGFloat = 80,
        serverBaseURL: URL = URL(string: "https://wechat.cuven.us")!,
        isAnimatedPlaybackAllowed: Bool = true
    ) {
        self.sticker = sticker
        self.size = size
        self.serverBaseURL = serverBaseURL
        self.isAnimatedPlaybackAllowed = isAnimatedPlaybackAllowed
    }

    /// Convenience initializer for rendering sticker bubbles directly from `Message` metadata.
    public init(
        stickerID: String,
        setName: String,
        emoji: String = "✨",
        format: StickerFormat = .staticWebP,
        size: CGFloat = 128,
        serverBaseURL: URL = URL(string: "https://wechat.cuven.us")!
    ) {
        let base = serverBaseURL.absoluteString.hasSuffix("/")
            ? String(serverBaseURL.absoluteString.dropLast())
            : serverBaseURL.absoluteString
        let encodedSet = setName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? setName
        let thumb = "\(base)/api/stickers/img/\(stickerID)?set=\(encodedSet)&thumb=1"
        let asset = format == .animatedLottie
            ? "\(base)/api/stickers/anim/\(stickerID)?set=\(encodedSet)"
            : "\(base)/api/stickers/img/\(stickerID)?set=\(encodedSet)"

        self.init(
            sticker: StickerItem(
                id: stickerID,
                setName: setName,
                emoji: emoji,
                format: format,
                thumbURL: thumb,
                assetURL: asset
            ),
            size: size,
            serverBaseURL: serverBaseURL
        )
    }

    private var shouldAnimateNow: Bool {
        isVisibleOnScreen && isAnimatedPlaybackAllowed && !reduceMotion
    }

    public var body: some View {
        ZStack {
            switch sticker.format {
            case .animatedLottie:
                if let lottieDocument, lottieDocument.hasRenderableShapes {
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !shouldAnimateNow)) { timeline in
                        Canvas { context, canvasSize in
                            let elapsed = shouldAnimateNow ? timeline.date.timeIntervalSinceReferenceDate : 0.4
                            LottieCanvasEvaluator.render(
                                document: lottieDocument,
                                elapsedSeconds: elapsed,
                                in: &context,
                                canvasSize: canvasSize
                            )
                        }
                    }
                } else if let staticImage {
                    Image(uiImage: staticImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else if showFallbackAfterHold {
                    ProceduralExpressiveStickerView(
                        stickerID: sticker.id,
                        emoji: sticker.emoji,
                        format: sticker.format,
                        isAnimating: shouldAnimateNow
                    )
                }

            case .videoWebM:
                if let videoPlayableURL, shouldAnimateNow {
                    SilentLoopingStickerVideoRepresentable(
                        url: videoPlayableURL,
                        isPlaying: shouldAnimateNow
                    )
                } else if let staticImage {
                    Image(uiImage: staticImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else if showFallbackAfterHold {
                    ProceduralExpressiveStickerView(
                        stickerID: sticker.id,
                        emoji: sticker.emoji,
                        format: sticker.format,
                        isAnimating: shouldAnimateNow
                    )
                }

            case .staticWebP:
                if let staticImage {
                    Image(uiImage: staticImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else if showFallbackAfterHold {
                    ProceduralExpressiveStickerView(
                        stickerID: sticker.id,
                        emoji: sticker.emoji,
                        format: .staticWebP,
                        isAnimating: false
                    )
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear { isVisibleOnScreen = true }
        .onDisappear { isVisibleOnScreen = false }
        .task(id: sticker.id) {
            await loadStickerAssets()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sticker \(sticker.emoji)")
    }

    // MARK: - Asset Loading (`120ms` zero-flash hold + ImageIO WebP + Lottie JSON + AVURLAsset check)

    @MainActor
    private func loadStickerAssets() async {
        // Check synchronous caches first so ready stickers appear instantaneously without any emoji flash (`stickers.js:75-80`).
        let imageSourceURL = sticker.format == .staticWebP ? sticker.assetURL : sticker.thumbURL
        if let cachedImg = CuvenDecodedImageCache.shared.image(forKey: imageSourceURL) {
            staticImage = cachedImg
        }
        if sticker.format == .animatedLottie,
           let cachedDoc = LottieDocumentCache.shared.document(forKey: sticker.assetURL) {
            lottieDocument = cachedDoc
            return
        }

        // Start 120ms anti-flash hold timer (`stickers.js:80`)
        let holdTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            if !Task.isCancelled {
                showFallbackAfterHold = true
            }
        }
        defer { holdTask.cancel() }

        // Decode static WebP or still thumbnail via ImageIO
        if staticImage == nil, !imageSourceURL.isEmpty {
            if let decoded = await CuvenImageIODecoder.loadOrFetchImage(
                rawURL: imageSourceURL,
                serverBaseURL: serverBaseURL,
                maxPixelDimension: 512
            ) {
                staticImage = decoded
            }
        }

        // Format-specific animated payload
        switch sticker.format {
        case .animatedLottie:
            if let doc = await fetchLottieDocument(rawURL: sticker.assetURL) {
                LottieDocumentCache.shared.insert(doc, forKey: sticker.assetURL)
                lottieDocument = doc
            } else {
                showFallbackAfterHold = true
            }

        case .videoWebM:
            if let resolved = CuvenStickerCatalogRegistry.resolvedURL(sticker.assetURL, serverBaseURL: serverBaseURL) {
                let asset = AVURLAsset(url: resolved)
                let playable = (try? await asset.load(.isPlayable)) ?? false
                if playable {
                    videoPlayableURL = resolved
                } else if staticImage == nil {
                    showFallbackAfterHold = true
                }
            } else if staticImage == nil {
                showFallbackAfterHold = true
            }

        case .staticWebP:
            if staticImage == nil {
                showFallbackAfterHold = true
            }
        }
    }

    private func fetchLottieDocument(rawURL: String) async -> LottieAnimationDocument? {
        guard let targetURL = CuvenStickerCatalogRegistry.resolvedURL(rawURL, serverBaseURL: serverBaseURL),
              let scheme = targetURL.scheme,
              (scheme == "http" || scheme == "https") else {
            return nil
        }

        var request = URLRequest(url: targetURL)
        request.timeoutInterval = 6.0
        request.httpShouldHandleCookies = true
        if let host = targetURL.host {
            let portPart = targetURL.port.map { ":\($0)" } ?? ""
            request.setValue("\(scheme)://\(host)\(portPart)", forHTTPHeaderField: "Origin")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            return try JSONDecoder().decode(LottieAnimationDocument.self, from: data)
        } catch {
            return nil
        }
    }
}

// MARK: - Silent Looping Video Sticker (`AVQueuePlayer` + `AVPlayerLooper`)

private struct SilentLoopingStickerVideoRepresentable: UIViewRepresentable {
    let url: URL
    let isPlaying: Bool

    func makeUIView(context: Context) -> StickerPlayerHostView {
        let view = StickerPlayerHostView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.configure(url: url, shouldPlay: isPlaying)
        return view
    }

    func updateUIView(_ uiView: StickerPlayerHostView, context: Context) {
        uiView.configure(url: url, shouldPlay: isPlaying)
    }

    static func dismantleUIView(_ uiView: StickerPlayerHostView, coordinator: ()) {
        uiView.tearDown()
    }
}

@MainActor
private final class StickerPlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private var queuePlayer: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private var activeURL: URL?

    func configure(url: URL, shouldPlay: Bool) {
        if activeURL != url {
            tearDown()
            activeURL = url
            let item = AVPlayerItem(url: url)
            let player = AVQueuePlayer()
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            player.actionAtItemEnd = .none
            let looper = AVPlayerLooper(player: player, templateItem: item)
            self.queuePlayer = player
            self.playerLooper = looper
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = UIColor.clear.cgColor
        }

        if shouldPlay {
            queuePlayer?.play()
        } else {
            queuePlayer?.pause()
        }
    }

    func tearDown() {
        queuePlayer?.pause()
        playerLooper?.disableLooping()
        playerLooper = nil
        queuePlayer?.removeAllItems()
        queuePlayer = nil
        playerLayer.player = nil
        activeURL = nil
    }
}

// MARK: - Procedural Expressive Vector Sticker Fallback (Offline / Demo Mode)

private struct ProceduralExpressiveStickerView: View {
    let stickerID: String
    let emoji: String
    let format: StickerFormat
    let isAnimating: Bool

    private var seedHash: UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in stickerID.utf8 {
            h ^= UInt64(b)
            h &*= 0x100_0000_01B3
        }
        return h
    }

    private var accentColor: Color {
        let palette: [Color] = [
            Color(red: 1.00, green: 0.76, blue: 0.22),
            Color(red: 0.24, green: 0.62, blue: 1.00),
            Color(red: 1.00, green: 0.44, blue: 0.58),
            Color(red: 0.30, green: 0.82, blue: 0.56),
            Color(red: 0.68, green: 0.46, blue: 1.00),
            Color(red: 1.00, green: 0.56, blue: 0.28)
        ]
        return palette[Int(seedHash % UInt64(palette.count))]
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isAnimating)) { timeline in
            let phaseOffset = Double(seedHash & 0xFF) / 255.0 * .pi * 2.0
            let t = isAnimating ? (timeline.date.timeIntervalSinceReferenceDate * 2.8 + phaseOffset) : phaseOffset
            let bounceY = isAnimating ? CGFloat(sin(t) * 3.5) : 0
            let squashX = isAnimating ? CGFloat(1.0 + cos(t * 2.0) * 0.045) : 1.0
            let squashY = isAnimating ? CGFloat(1.0 - cos(t * 2.0) * 0.045) : 1.0
            let tiltDegrees = isAnimating ? sin(t * 0.85) * 6.0 : 0.0

            GeometryReader { geo in
                let dim = min(geo.size.width, geo.size.height)
                ZStack {
                    // Expressive sticker backing blob & orbiting sparkles
                    Canvas { ctx, size in
                        let cx = size.width * 0.5
                        let cy = size.height * 0.5
                        let blobR = dim * 0.40

                        var blob = Path()
                        let lobes = 8
                        for step in 0..<(lobes * 6) {
                            let angle = Double(step) / Double(lobes * 6) * .pi * 2.0
                            let ripple = 1.0 + 0.06 * sin(angle * Double(lobes) + (isAnimating ? t * 1.4 : 0))
                            let r = Double(blobR) * ripple
                            let pt = CGPoint(x: cx + CGFloat(cos(angle) * r), y: cy + CGFloat(sin(angle) * r))
                            if step == 0 { blob.move(to: pt) } else { blob.addLine(to: pt) }
                        }
                        blob.closeSubpath()

                        ctx.fill(
                            blob,
                            with: .radialGradient(
                                Gradient(colors: [accentColor.opacity(0.30), accentColor.opacity(0.08)]),
                                center: CGPoint(x: cx, y: cy),
                                startRadius: 2,
                                endRadius: blobR * 1.15
                            )
                        )
                        ctx.stroke(blob, with: .color(.white.opacity(0.65)), lineWidth: 1.6)

                        if format != .staticWebP {
                            for sp in 0..<3 {
                                let orbitAngle = t * 0.9 + Double(sp) * (.pi * 2.0 / 3.0)
                                let sx = cx + CGFloat(cos(orbitAngle)) * dim * 0.39
                                let sy = cy + CGFloat(sin(orbitAngle)) * dim * 0.39
                                let sr = max(2.2, dim * 0.045 * CGFloat(0.75 + 0.25 * sin(t * 2 + Double(sp))))
                                var star = Path()
                                star.move(to: CGPoint(x: sx, y: sy - sr))
                                star.addQuadCurve(to: CGPoint(x: sx + sr, y: sy), control: CGPoint(x: sx, y: sy))
                                star.addQuadCurve(to: CGPoint(x: sx, y: sy + sr), control: CGPoint(x: sx, y: sy))
                                star.addQuadCurve(to: CGPoint(x: sx - sr, y: sy), control: CGPoint(x: sx, y: sy))
                                star.addQuadCurve(to: CGPoint(x: sx, y: sy - sr), control: CGPoint(x: sx, y: sy))
                                ctx.fill(star, with: .color(accentColor.opacity(0.88)))
                            }
                        }
                    }

                    Text(emoji.isEmpty ? "✨" : emoji)
                        .font(.system(size: dim * 0.54))
                        .scaleEffect(x: squashX, y: squashY)
                        .rotationEffect(.degrees(tiltDegrees))
                        .offset(y: bounceY)
                        .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
                }
            }
        }
    }
}

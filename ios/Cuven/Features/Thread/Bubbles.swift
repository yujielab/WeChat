import SwiftUI
import AVFoundation
import UIKit

// MARK: - Shape

/// The web's bubble (css/thread.css): 23pt corners, so a line of text is a
/// pill; corners facing the sender pinch to 8pt where a run's bubbles meet;
/// the run's last one squares that corner off into a small pointed nub.
struct BubbleShape: Shape {
    var mine: Bool
    var joinTop: Bool
    var joinBottom: Bool
    var tail: Bool
    var radius: CGFloat = 23

    func path(in rect: CGRect) -> Path {
        let big = min(radius, rect.height / 2, rect.width / 2)
        let join = min(8, big)
        var tl = big, tr = big, bl = big, br = big
        if mine {
            if joinTop { tr = join }
            if joinBottom { br = join }
            if tail { br = 0 }
        } else {
            if joinTop { tl = join }
            if joinBottom { bl = join }
            if tail { bl = 0 }
        }
        let nubW: CGFloat = 8, nubH: CGFloat = min(12, rect.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        corner(&p, CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY + tr), tr)
        if tail && mine {
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - nubH))
            p.addQuadCurve(to: CGPoint(x: rect.maxX + nubW, y: rect.maxY),
                           control: CGPoint(x: rect.maxX + 1, y: rect.maxY - 3))
            p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        } else {
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
            corner(&p, CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.maxX - br, y: rect.maxY), br)
            p.addLine(to: CGPoint(x: rect.minX + (tail ? 0 : bl), y: rect.maxY))
        }
        if tail && !mine {
            p.addLine(to: CGPoint(x: rect.minX - nubW, y: rect.maxY))
            p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - nubH),
                           control: CGPoint(x: rect.minX - 1, y: rect.maxY - 3))
        } else {
            corner(&p, CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY - bl), bl)
        }
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        corner(&p, CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX + tl, y: rect.minY), tl)
        p.closeSubpath()
        return p
    }

    private func corner(_ p: inout Path, _ c: CGPoint, _ next: CGPoint, _ r: CGFloat) {
        if r < 0.5 { p.addLine(to: c); p.addLine(to: next) }
        else { p.addArc(tangent1End: c, tangent2End: next, radius: r) }
    }
}

struct BubbleStyle {
    var mine: Bool
    var joinTop = false
    var joinBottom = false
    var tail = false
    var shape: BubbleShape { BubbleShape(mine: mine, joinTop: joinTop, joinBottom: joinBottom, tail: tail) }
}

/// The body text's line box (17pt at 1.45, as the web sets it), and the
/// leading SwiftUI needs to match it with the custom face.
enum BodyMetrics {
    static let size: CGFloat = 17
    static let lineBox: CGFloat = 17 * 1.45
    static let natural: CGFloat = AppFont.ui(17).lineHeight
    static var extra: CGFloat { max(0, lineBox - natural) }
}

extension Theme {
    /// The faint drop under a bubble on the light wallpaper (--chip-shadow; none in dark).
    static let bubbleShadow = Color.token(0x0b141a, 0x000000, 0.13, 0)
    static let keyHighlight = Color.token(0x787880, 0xffffff, 0.13, 0.16)
    /// Time marks: the system face, 12pt medium (--time-ink).
    static let timeInk = Color.token(0x6b7280, 0xa1a1aa)
    static let noticeBg = Color.token(0xffefd1, 0x232626)
    static let noticeText = Color.token(0x6b5525, 0xf0f0fa, 1, 0.6)
    static let chipAccent = Color.token(0x0062cc, 0x27a8ff)
}

// MARK: - Content

/// What a message shows inside (or instead of) its bubble.
struct BubbleContent: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let style: BubbleStyle
    var maxWidth: CGFloat
    var onOpenMedia: ((CGRect) -> Void)? = nil
    var onJumpTo: ((String) -> Void)? = nil
    var onRetry: (() -> Void)? = nil

    private var mine: Bool { style.mine }
    private var fg: Color { mine ? Theme.bubbleOutText : Theme.bubbleInText }
    private var bg: Color { mine ? Theme.bubbleOut : Theme.bubbleIn }

    var body: some View {
        Group {
            if message.isRevoked {
                revoked
            } else {
                switch message.type {
                case "image", "drawing": picture
                case "sticker": StickerView(meta: message.meta, size: 140)
                case "voice": voice
                case "video": video
                case "file": file
                case "call": call
                default: text
                }
            }
        }
    }

    // MARK: text

    @ViewBuilder
    private var text: some View {
        if Fmt.isJumboEmoji(message.body) && message.reply == nil {
            Text(message.body)
                .font(.system(size: 44))
                .padding(.horizontal, 2)
        } else {
            let half = BodyMetrics.extra / 2
            VStack(alignment: .leading, spacing: 0) {
                if let reply = message.reply { quote(reply) }
                Text(attributed)
                    .font(.bodyC)
                    .lineSpacing(BodyMetrics.extra)
                    .foregroundStyle(fg)
                    .tint(mine ? fg : Theme.linkIn)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.disabled)
                if message.edited > 0 {
                    Text("Edited").font(.caption2C).foregroundStyle(fg.opacity(0.6)).padding(.top, 2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 11 + half)
            .padding(.bottom, 12 + half)
            .background(bg, in: style.shape)
            .shadow(color: Theme.bubbleShadow, radius: 0.25, y: 1)
            .contentShape(style.shape)
        }
    }

    private var attributed: AttributedString {
        var s = AttributedString(message.body)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let ns = message.body as NSString
            for match in detector.matches(in: message.body, range: NSRange(location: 0, length: ns.length)) {
                guard let url = match.url, let r = Range(match.range, in: message.body),
                      let ar = Range(r, in: s) else { continue }
                s[ar].link = url
                s[ar].underlineStyle = Text.LineStyle.single
            }
        }
        // Key words the hub picked out (time, place, people, numbers, to-dos): semibold on a tint.
        if model.highlights, let keys = message.meta?.keys {
            for k in keys where !k.isEmpty {
                var search = s.startIndex..<s.endIndex
                while let r = s[search].range(of: k) {
                    s[r].font = AppFont.make(17, .semibold)
                    s[r].backgroundColor = mine ? Color.white.opacity(0.18) : Theme.keyHighlight
                    search = r.upperBound..<s.endIndex
                }
            }
        }
        // @mentions: a tinted token, never just coloured text.
        if let ids = message.meta?.mentions {
            for id in ids {
                let name = id == model.me?.id ? (model.me?.name ?? "") : (model.user(id)?.name ?? "")
                guard !name.isEmpty, let r = s.range(of: "@\(name)") else { continue }
                s[r].font = AppFont.make(17, .medium)
                if id == model.me?.id {
                    s[r].backgroundColor = mine ? Color.white : Theme.badge
                    s[r].foregroundColor = mine ? Theme.bubbleOut : Theme.onBrand
                } else {
                    s[r].backgroundColor = mine ? Color.white.opacity(0.2) : Theme.blue.opacity(0.14)
                    if !mine { s[r].foregroundColor = Theme.mention }
                }
            }
        }
        return s
    }

    /// A quote: a leading 3pt rule, the name over one line of text.
    private func quote(_ r: ReplySnapshot) -> some View {
        Button {
            onJumpTo?(r.id)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.name(of: r.sender))
                        .font(AppFont.make(13, .semibold))
                        .foregroundStyle(mine ? fg : Theme.blueText)
                        .lineLimit(1)
                    Text(r.state == "revoked" ? String(localized: "Message unsent") : replyText(r))
                        .font(.footnoteC)
                        .italic(r.state == "revoked")
                        .foregroundStyle(fg.opacity(r.state == "revoked" ? 0.55 : 0.78))
                        .lineLimit(1)
                }
                if let url = r.url, r.type == "image" || r.type == "drawing" {
                    RemoteImage(url, maxPixel: 120).frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .padding(.leading, 13)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(mine ? fg.opacity(0.7) : Theme.blue).frame(width: 3).padding(.vertical, 1).padding(.leading, 5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 1)
        .padding(.bottom, 7)
        .padding(.horizontal, -6)
    }

    private func replyText(_ r: ReplySnapshot) -> String {
        switch r.type {
        case "image": return String(localized: "Photo")
        case "drawing": return String(localized: "Drawing")
        case "voice": return String(localized: "Voice message")
        case "video": return String(localized: "Video")
        case "sticker": return [String(localized: "Sticker"), r.emoji ?? ""].joined(separator: " ")
        default: return r.body
        }
    }

    private var revoked: some View {
        Text(mine ? "You unsent a message" : "\(model.name(of: message.sender)) unsent a message")
            .font(.subheadC.italic())
            .foregroundStyle(Theme.label3)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .overlay(style.shape.stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    // MARK: media

    private func mediaSize(_ meta: MessageMeta?, maxW: CGFloat, maxH: CGFloat = 340) -> CGSize {
        guard let w = meta?.w, let h = meta?.h, w > 0, h > 0 else { return CGSize(width: maxW * 0.75, height: maxW * 0.75) }
        let s = min(maxW / w, maxH / h, 1)
        var W = max(110, w * s), H = h * s
        if w * s < 110 { H = H * 110 / (w * s) }
        H = min(max(H, 80), maxH)
        W = min(W, maxW)
        return CGSize(width: W, height: H)
    }

    private var picture: some View {
        let size = mediaSize(message.meta, maxW: min(maxWidth, 300))
        return VStack(alignment: .leading, spacing: 4) {
            if let reply = message.reply { quote(reply).padding(.horizontal, 10).padding(.top, 4) }
            FrameReporting { frame in
                RemoteImage(message.meta?.url ?? "", maxPixel: 900,
                            placeholder: message.type == "drawing" ? Color.white : Theme.fill4)
                    .frame(width: size.width, height: size.height)
                    .background(message.type == "drawing" ? Color.white : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.imageOutline, lineWidth: 1))
                    .overlay(alignment: .bottomTrailing) {
                        if let p = message.progress, message.local == .sending {
                            ProgressRing(progress: p).padding(10)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onOpenMedia?(frame()) }
            }
            .frame(width: size.width, height: size.height)
        }
    }

    private var video: some View {
        let size = mediaSize(message.meta, maxW: min(maxWidth, 280))
        return FrameReporting { frame in
            ZStack {
                if let url = message.meta?.url, !url.hasPrefix("local:") {
                    VideoThumb(path: url)
                } else {
                    Theme.fill4
                }
                SymbolView(.play, size: 22)
                    .foregroundStyle(.white)
                    .offset(x: 2)
                    .frame(width: 52, height: 52)
                    .glassEffect(.regular.tint(.black.opacity(0.25)), in: Circle())
                if let d = message.meta?.dur {
                    Text(Fmt.duration(d)).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.black.opacity(0.4), in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(8)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.imageOutline, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture { onOpenMedia?(frame()) }
        }
        .frame(width: size.width, height: size.height)
    }

    private var voice: some View {
        VoiceBubble(message: message, mine: mine)
            .padding(.leading, 8)
            .padding(.trailing, 14)
            .padding(.vertical, 8)
            .frame(minWidth: 132)
            .background(bg, in: style.shape)
            .shadow(color: Theme.bubbleShadow, radius: 0.25, y: 1)
    }

    private var file: some View {
        HStack(spacing: 12) {
            SymbolView(.doc, size: 22)
                .foregroundStyle(mine ? Theme.bubbleOut : Theme.label)
                .frame(width: 42, height: 42)
                .background(mine ? Color.white : Theme.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(message.meta?.name ?? String(localized: "File")).font(.subheadBoldC).foregroundStyle(fg).lineLimit(2)
                Text(Fmt.fileSize(message.meta?.size)).font(.footnoteC).foregroundStyle(fg.opacity(0.7))
            }
        }
        .padding(10)
        .padding(.trailing, 6)
        .frame(maxWidth: 260, alignment: .leading)
        .background(bg, in: style.shape)
        .shadow(color: Theme.bubbleShadow, radius: 0.25, y: 1)
        .onTapGesture { FileOpener.open(message) }
    }

    /// A call record: a compact, quiet chip; only a call you missed is red.
    private var call: some View {
        let s = CallSummary(meta: message.meta, mine: message.meta?.caller == model.me?.id)
        return HStack(spacing: 7) {
            SymbolView(s.isVideo ? .video : .phone, size: 15)
            Text(s.label).font(.footnoteC)
        }
        .foregroundStyle(s.missed ? Theme.redText : Theme.label2)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            if let room = model.room(message.room) { model.calls.start(room: room, video: s.isVideo) }
        }
    }
}

struct ProgressRing: View {
    var progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.35), lineWidth: 3)
            Circle().trim(from: 0, to: max(0.03, progress))
                .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: progress)
        }
        .frame(width: 26, height: 26)
        .padding(6)
        .background(.black.opacity(0.35), in: Circle())
    }
}

// MARK: - Frame probe

/// Gives its content a way to ask where it is on screen right now (for
/// photos that grow into the viewer and messages that lift into the menu).
struct FrameReporting<Content: View>: View {
    @State private var box = ProbeBox()
    @ViewBuilder var content: (@escaping () -> CGRect) -> Content

    var body: some View {
        content { box.frame }
            .background(FrameProbe(box: box))
    }
}

final class ProbeBox {
    weak var view: UIView?
    var frame: CGRect {
        guard let view, let window = view.window else { return .zero }
        return view.convert(view.bounds, to: window)
    }
}

struct FrameProbe: UIViewRepresentable {
    let box: ProbeBox
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        box.view = v
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) { box.view = uiView }
}

// MARK: - Voice

@MainActor
@Observable
final class AudioPlayback {
    static let shared = AudioPlayback()
    var playing: String?
    var progress: Double = 0
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var observer: Any?

    func toggle(_ m: Message) {
        if playing == m.id {
            stop()
            return
        }
        stop()
        guard let url = m.meta?.url, let asset = AuthorizedAsset.make(url) else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        player = p
        playing = m.id
        progress = 0
        let total = m.meta?.dur ?? 0
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] t in
            Task { @MainActor in
                guard let self else { return }
                let d = item.duration.seconds.isFinite && item.duration.seconds > 0 ? item.duration.seconds : total
                self.progress = d > 0 ? min(1, t.seconds / d) : 0
                if d > 0 && t.seconds >= d - 0.05 { self.stop() }
            }
        }
        p.play()
    }

    func stop() {
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        player = nil
        playing = nil
        progress = 0
    }
}

struct VoiceBubble: View {
    let message: Message
    let mine: Bool
    private var playback: AudioPlayback { AudioPlayback.shared }

    var body: some View {
        let active = playback.playing == message.id
        let ink = mine ? Theme.bubbleOutText : Theme.label
        let paper = mine ? Theme.bubbleOut : Theme.bubbleIn
        HStack(spacing: 10) {
            Button { playback.toggle(message) } label: {
                SymbolView(active ? .pause : .play, size: 13)
                    .foregroundStyle(paper)
                    .offset(x: active ? 0 : 1)
                    .frame(width: 30, height: 30)
                    .background(ink, in: Circle())
            }
            .buttonStyle(.press(0.9))
            .accessibilityLabel(active ? "Pause" : "Play")
            Waveform(seed: message.id, progress: active ? playback.progress : 0,
                     color: mine ? Theme.bubbleOutText : Theme.bubbleInText)
                .frame(width: min(160, max(60, CGFloat(message.meta?.dur ?? 4) * 7)), height: 26)
            Text(Fmt.duration(message.meta?.dur ?? 0))
                .font(.footnoteC.monospacedDigit())
                .foregroundStyle((mine ? Theme.bubbleOutText : Theme.bubbleInText).opacity(0.8))
        }
    }
}

struct Waveform: View {
    let seed: String
    var progress: Double
    var color: Color

    var body: some View {
        Canvas { ctx, size in
            var h: UInt64 = 1469598103934665603
            for b in seed.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
            let gap: CGFloat = 2
            let w: CGFloat = 2.5
            let bars = max(8, Int((size.width + gap) / (w + gap)))
            for i in 0..<bars {
                h = h &* 6364136223846793005 &+ 1442695040888963407
                let v = CGFloat((h >> 33) % 100) / 100
                let shape = 0.3 + 0.7 * sin(CGFloat(i) / CGFloat(bars) * .pi)
                let bh = max(3, size.height * (0.25 + 0.75 * v) * shape)
                let rect = CGRect(x: CGFloat(i) * (w + gap), y: (size.height - bh) / 2, width: w, height: bh)
                let played = CGFloat(i) / CGFloat(bars) < progress
                ctx.fill(Path(roundedRect: rect, cornerRadius: w / 2), with: .color(color.opacity(played ? 1 : 0.35)))
            }
        }
    }
}

// MARK: - Files

enum FileOpener {
    @MainActor
    static func open(_ m: Message) {
        guard let url = m.meta?.url else { return }
        Task {
            guard let data = await ImageStore.shared.data(url) else { return }
            let name = m.meta?.name ?? "file"
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? data.write(to: tmp)
            await MainActor.run { Share.present([tmp]) }
        }
    }
}

enum Share {
    @MainActor
    static func present(_ items: [Any]) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController else { return }
        var top = root
        while let p = top.presentedViewController { top = p }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = top.view
        vc.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
        top.present(vc, animated: true)
    }
}

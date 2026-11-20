import SwiftUI
import AVFoundation
import UIKit

// MARK: - Shape

/// A rounded bubble whose corners tighten where it joins its neighbours in
/// a group, with a small curled tail on the last one.
struct BubbleShape: Shape {
    var mine: Bool
    var joinTop: Bool
    var joinBottom: Bool
    var tail: Bool
    var radius: CGFloat = 20

    func path(in rect: CGRect) -> Path {
        let big = min(radius, rect.height / 2, rect.width / 2)
        let small: CGFloat = min(6, big)
        // Corners: the side facing the sender's avatar tightens where joined.
        let tl = !mine && joinTop ? small : big
        let bl = !mine && (joinBottom || tail) ? small : big
        let tr = mine && joinTop ? small : big
        let br = mine && (joinBottom || tail) ? small : big
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + tr), radius: tr)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        if tail && mine {
            p.addQuadCurve(to: CGPoint(x: rect.maxX + 6, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY - 1))
            p.addQuadCurve(to: CGPoint(x: rect.maxX - 10, y: rect.maxY - 2), control: CGPoint(x: rect.maxX - 3, y: rect.maxY + 1))
            p.addQuadCurve(to: CGPoint(x: rect.maxX - 16, y: rect.maxY), control: CGPoint(x: rect.maxX - 12, y: rect.maxY))
        } else {
            p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - br, y: rect.maxY), radius: br)
        }
        if tail && !mine {
            p.addLine(to: CGPoint(x: rect.minX + 16, y: rect.maxY))
            p.addQuadCurve(to: CGPoint(x: rect.minX + 10, y: rect.maxY - 2), control: CGPoint(x: rect.minX + 12, y: rect.maxY))
            p.addQuadCurve(to: CGPoint(x: rect.minX - 6, y: rect.maxY), control: CGPoint(x: rect.minX + 3, y: rect.maxY + 1))
            p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - bl), control: CGPoint(x: rect.minX, y: rect.maxY - 1))
        } else {
            p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
            p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bl), radius: bl)
        }
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + tl, y: rect.minY), radius: tl)
        p.closeSubpath()
        return p
    }
}

struct BubbleStyle {
    var mine: Bool
    var joinTop = false
    var joinBottom = false
    var tail = false
    var shape: BubbleShape { BubbleShape(mine: mine, joinTop: joinTop, joinBottom: joinBottom, tail: tail) }
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
                .font(.system(size: 52))
                .padding(.vertical, 2)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if let reply = message.reply { quote(reply) }
                Text(attributed)
                    .font(.bodyC)
                    .foregroundStyle(fg)
                    .tint(mine ? .white : Theme.systemBlue)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.disabled)
                if message.edited > 0 {
                    Text("Edited").font(.caption2C).foregroundStyle(fg.opacity(0.6))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(bg, in: style.shape)
            .contentShape(style.shape)
        }
    }

    private var attributed: AttributedString {
        var s = AttributedString(message.body)
        // Links
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let ns = message.body as NSString
            for match in detector.matches(in: message.body, range: NSRange(location: 0, length: ns.length)) {
                guard let url = match.url, let r = Range(match.range, in: message.body),
                      let ar = Range(r, in: s) else { continue }
                s[ar].link = url
                s[ar].underlineStyle = Text.LineStyle.single
            }
        }
        // Key words the hub picked out (time, place, people, numbers, to-dos)
        if model.highlights, let keys = message.meta?.keys {
            for k in keys where !k.isEmpty {
                var search = s.startIndex..<s.endIndex
                while let r = s[search].range(of: k) {
                    s[r].font = AppFont.make(17, .bold)
                    if !mine { s[r].backgroundColor = Theme.keyHighlight }
                    else { s[r].underlineStyle = Text.LineStyle(pattern: .solid, color: .white.opacity(0.7)) }
                    search = r.upperBound..<s.endIndex
                }
            }
        }
        // @mentions in groups
        if let ids = message.meta?.mentions {
            for id in ids {
                let name = id == model.me?.id ? (model.me?.name ?? "") : (model.user(id)?.name ?? "")
                guard !name.isEmpty, let r = s.range(of: "@\(name)") else { continue }
                s[r].font = AppFont.make(17, .bold)
                if !mine { s[r].foregroundColor = Theme.blue }
            }
        }
        return s
    }

    private func quote(_ r: ReplySnapshot) -> some View {
        Button {
            onJumpTo?(r.id)
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(mine ? Color.white.opacity(0.7) : Theme.blue).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.name(of: r.sender)).font(.caption2C.weight(.bold)).foregroundStyle(mine ? .white : Theme.blue)
                    Text(r.state == "revoked" ? String(localized: "Message unsent") : replyText(r))
                        .font(.footnoteC).foregroundStyle(fg.opacity(0.8)).lineLimit(2)
                }
                if let url = r.url, r.type == "image" || r.type == "drawing" {
                    RemoteImage(url, maxPixel: 120).frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background((mine ? Color.white : Theme.blue).opacity(mine ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
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
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
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
            if let reply = message.reply { quote(reply).padding(.horizontal, 4).padding(.top, 4) }
            FrameReporting { frame in
                RemoteImage(message.meta?.url ?? "", maxPixel: 900,
                            placeholder: message.type == "drawing" ? Color.white : Theme.fillQuiet)
                    .frame(width: size.width, height: size.height)
                    .background(message.type == "drawing" ? Color.white : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.black.opacity(0.06), lineWidth: 0.5))
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
                    Theme.fillQuiet
                }
                Image(systemName: "play.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(.ultraThinMaterial, in: Circle())
                if let d = message.meta?.dur {
                    Text(Fmt.duration(d)).font(.caption2C.monospacedDigit()).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.4), in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(8)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { onOpenMedia?(frame()) }
        }
        .frame(width: size.width, height: size.height)
    }

    private var voice: some View {
        VoiceBubble(message: message, mine: mine)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(bg, in: style.shape)
    }

    private var file: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .font(.system(size: 20))
                .foregroundStyle(mine ? Theme.blue : .white)
                .frame(width: 42, height: 42)
                .background(mine ? Color.white : Theme.blue, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(message.meta?.name ?? String(localized: "File")).font(.subheadMediumC).foregroundStyle(fg).lineLimit(2)
                Text(Fmt.fileSize(message.meta?.size)).font(.captionC).foregroundStyle(fg.opacity(0.7))
            }
        }
        .padding(10)
        .frame(maxWidth: 260, alignment: .leading)
        .background(bg, in: style.shape)
        .onTapGesture { FileOpener.open(message) }
    }

    private var call: some View {
        let s = CallSummary(meta: message.meta, mine: message.meta?.caller == model.me?.id)
        return HStack(spacing: 10) {
            Image(systemName: s.isVideo ? "video.fill" : "phone.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(s.missed ? Theme.red : (mine ? .white : Theme.blue))
                .frame(width: 34, height: 34)
                .background((mine ? Color.white : Theme.blue).opacity(mine ? 0.2 : 0.12), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(s.media).font(.subheadMediumC).foregroundStyle(fg)
                Text(s.text).font(.captionC).foregroundStyle(s.missed ? Theme.redText : fg.opacity(0.7))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(bg, in: style.shape)
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
        HStack(spacing: 10) {
            Button { playback.toggle(message) } label: {
                Image(systemName: active ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(mine ? Theme.blue : .white)
                    .frame(width: 32, height: 32)
                    .background(mine ? Color.white : Theme.blue, in: Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.press(0.9))
            Waveform(seed: message.id, progress: active ? playback.progress : 0, color: mine ? .white : Theme.blue)
                .frame(width: 120, height: 26)
            Text(Fmt.duration(message.meta?.dur ?? 0))
                .font(.captionC.monospacedDigit())
                .foregroundStyle(mine ? .white.opacity(0.85) : Theme.label2)
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
            let bars = 28
            let gap: CGFloat = 2
            let w = (size.width - gap * CGFloat(bars - 1)) / CGFloat(bars)
            for i in 0..<bars {
                h = h &* 6364136223846793005 &+ 1442695040888963407
                let v = CGFloat((h >> 33) % 100) / 100
                let shape = 0.3 + 0.7 * sin(CGFloat(i) / CGFloat(bars) * .pi)
                let bh = max(3, size.height * (0.25 + 0.75 * v) * shape)
                let rect = CGRect(x: CGFloat(i) * (w + gap), y: (size.height - bh) / 2, width: w, height: bh)
                let played = CGFloat(i) / CGFloat(bars) < progress
                ctx.fill(Path(roundedRect: rect, cornerRadius: w / 2), with: .color(color.opacity(played ? 1 : 0.45)))
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

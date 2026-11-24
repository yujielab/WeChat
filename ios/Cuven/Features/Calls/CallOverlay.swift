import SwiftUI
import AVKit
import WebRTC

/// The call screen: their picture (or their photo on a dark field), a dark
/// capsule at the top with who and how long, and one dark glass capsule of
/// controls at the bottom; it shrinks to a pill so the chat stays usable.
struct CallOverlay: View {
    /// The app's own frame and insets (StripGeometry's), like every other
    /// layer: on the Duo the call stands clear of the system's column.
    let size: CGSize
    let insets: EdgeInsets
    /// The fold of a half-open Duo: the call then takes one side each (HIG:
    /// an overlay arrangement moves its views to either side of the fold).
    var fold: CGRect? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pip: CGSize = .zero
    @Namespace private var ns
    /// A live video call: a tap hides the controls (and they hide by
    /// themselves after a while); another brings them back.
    @State private var chromeHidden = false
    @State private var hideTask: Task<Void, Never>?
    /// The small picture tapped: yours big, theirs small.
    @State private var swapped = false
    /// Theirs fitted whole rather than filling the screen (double-tap).
    @State private var fitted = false

    private var calls: CallManager { model.calls }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if calls.active {
                if calls.expanded, let fold = sideFold {
                    folded(fold)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else if calls.expanded {
                    full
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    pill
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .animation(Motion.morph, value: calls.active)
        .animation(Motion.morph, value: calls.expanded)
    }

    // MARK: half open

    /// A fold down the middle of the open display (book pose).
    private var sideFold: CGRect? {
        guard let fold, fold.minX > 80, fold.maxX < size.width - 80, fold.height >= size.height * 0.8 else { return nil }
        return fold
    }

    /// Book pose: their picture (or who they are) on the leading side, and on
    /// the trailing side the status, your own picture and the controls, so
    /// nothing sits in the fold and neither covers the other.
    private func folded(_ fold: CGRect) -> some View {
        let leadW = fold.minX
        let trailW = max(0, size.width - fold.maxX - insets.trailing)
        return ZStack(alignment: .topLeading) {
            background.frame(width: size.width, height: size.height)
            HStack(spacing: 0) {
                ZStack {
                    if remoteShowing, let remote = calls.remoteVideo {
                        CallVideoView(track: remote, mirror: false, fill: !fitted)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { withAnimation(Motion.ui) { fitted.toggle() } }
                    } else {
                        identity.padding(.horizontal, 20)
                    }
                }
                .frame(width: leadW, height: size.height)
                .clipped()

                Color.clear.frame(width: fold.width)

                VStack(spacing: 16) {
                    topCapsule
                        .padding(.top, insets.top + 8)
                    if remoteShowing {
                        Text(calls.title).font(AppFont.make(22, .bold)).foregroundStyle(.white).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if localShowing, let local = calls.localVideo {
                        CallVideoView(track: local, mirror: calls.frontCamera, fill: true)
                            .frame(width: min(trailW - 40, 220), height: min(trailW - 40, 220) * 4 / 3)
                            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.white.opacity(0.25), lineWidth: 1))
                    }
                    Spacer(minLength: 8)
                    controls
                        .padding(.bottom, max(insets.bottom, 16) + 12)
                }
                .frame(width: trailW, height: size.height)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .preferredColorScheme(.dark)
    }

    // MARK: full screen

    private var remoteShowing: Bool { calls.video && calls.remoteVideo != nil && calls.remoteCam }
    private var localShowing: Bool { calls.video && calls.localVideo != nil && !calls.camOff && calls.phase != .incoming }
    /// Before they're on, your own camera fills the screen behind who you're calling.
    private var previewing: Bool { localShowing && !remoteShowing && calls.phase != .live }
    private var liveVideo: Bool { remoteShowing && calls.phase == .live }
    private var columnWidth: CGFloat { max(0, size.width - insets.leading - insets.trailing) }

    private var full: some View {
        let bottomGap = max(insets.bottom, 16) + 12
        return ZStack(alignment: .topLeading) {
            background
                .frame(width: size.width, height: size.height)

            // The big picture: theirs, yours when swapped, or yours while it rings.
            if let big = bigVideo {
                CallVideoView(track: big.track, mirror: big.mirror, fill: !(big.remote && fitted))
                    .frame(width: size.width, height: size.height)
                    .background(Color.black)
                    .overlay {
                        if previewing {
                            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.15), .black.opacity(0.6)],
                                           startPoint: .top, endPoint: .bottom)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard big.remote else { return }
                        withAnimation(Motion.ui) { fitted.toggle() }
                        Haptics.selection()
                    }
                    .onTapGesture { toggleChrome() }
                    .transition(.opacity)
                    .id(big.remote ? "remote" : "local")
            }

            // Who, the status, the controls: in the app's own column.
            ZStack {
                if !liveVideo && !(remoteShowing && swapped) {
                    identity
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.bottom, 80)
                        .allowsHitTesting(false)
                }

                VStack(spacing: 8) {
                    topCapsule
                    if calls.shaky && calls.phase == .live {
                        HStack(spacing: 6) {
                            SymbolView(.wifi, size: 13)
                            Text("Poor connection").font(.footnoteC)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Theme.orange.opacity(0.85), in: Capsule())
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .padding(.top, insets.top + 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .opacity(chromeHidden ? 0 : 1)
                .offset(y: chromeHidden ? -16 : 0)

                controls
                    .padding(.bottom, bottomGap)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .opacity(chromeHidden ? 0 : 1)
                    .offset(y: chromeHidden ? 24 : 0)
                    .allowsHitTesting(!chromeHidden)
            }
            .frame(width: columnWidth, height: size.height)
            .offset(x: insets.leading)
            .animation(Motion.ui, value: chromeHidden)
            .animation(Motion.ui, value: calls.shaky)

            // The small picture, drag it to a corner; tap it to swap.
            if let small = smallVideo {
                let w: CGFloat = 112
                let h: CGFloat = 160
                let right = size.width - insets.trailing - 16 - w
                let left = insets.leading + 16
                let top = insets.top + 70
                let bottom = size.height - bottomGap - 120 - 16 - h
                CallVideoView(track: small.track, mirror: small.mirror, fill: true)
                    .frame(width: w, height: h)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.white.opacity(0.25), lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                    .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .onTapGesture {
                        Haptics.tap()
                        withAnimation(Motion.morph) { swapped.toggle() }
                        showChrome()
                    }
                    .offset(x: right + pip.width, y: top + pip.height)
                    .gesture(DragGesture().onChanged { pip = $0.translation }.onEnded { v in
                        let x: CGFloat = v.predictedEndLocation.x < size.width / 2 ? left - right : 0
                        let y: CGFloat = v.predictedEndLocation.y > size.height / 2 ? bottom - top : 0
                        withAnimation(Motion.move) { pip = CGSize(width: x, height: y) }
                    })
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel(swapped ? "Their video" : "Your video")
                    .accessibilityHint("Swaps the two pictures")
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .preferredColorScheme(.dark)
        .onChange(of: liveVideo) { _, live in
            if live { scheduleHide() } else { showChrome(schedule: false) }
        }
        .onChange(of: calls.active) { _, on in
            if !on { swapped = false; fitted = false; chromeHidden = false; hideTask?.cancel() }
        }
    }

    private struct Shown { let track: RTCVideoTrack; let mirror: Bool; let remote: Bool }

    private var bigVideo: Shown? {
        if remoteShowing, let remote = calls.remoteVideo {
            if swapped, localShowing, let local = calls.localVideo { return Shown(track: local, mirror: calls.frontCamera, remote: false) }
            return Shown(track: remote, mirror: false, remote: true)
        }
        if previewing, let local = calls.localVideo { return Shown(track: local, mirror: calls.frontCamera, remote: false) }
        return nil
    }

    private var smallVideo: Shown? {
        guard remoteShowing, localShowing, let remote = calls.remoteVideo, let local = calls.localVideo else { return nil }
        return swapped ? Shown(track: remote, mirror: false, remote: true) : Shown(track: local, mirror: calls.frontCamera, remote: false)
    }

    private var identity: some View {
        VStack(spacing: 18) {
            Avatar(user: calls.peerUser ?? User(id: calls.roomId ?? "", display: calls.title), size: 132)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
            Text(calls.title).font(AppFont.make(30, .bold)).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.6)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(statusLine).font(.subheadC.monospacedDigit()).foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .contentTransition(.numericText())
            }
            if calls.phase == .live && (!calls.remoteMic || (calls.video && !calls.remoteCam)) {
                HStack(spacing: 14) {
                    if !calls.remoteMic {
                        Label("Muted", systemImage: "mic.slash.fill")
                    }
                    if calls.video && !calls.remoteCam {
                        Label("Camera off", systemImage: "video.slash.fill")
                    }
                }
                .font(.footnoteC)
                .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private func toggleChrome() {
        guard liveVideo else { return }
        if chromeHidden { showChrome() } else {
            hideTask?.cancel()
            chromeHidden = true
        }
    }

    private func showChrome(schedule: Bool = true) {
        chromeHidden = false
        if schedule && liveVideo { scheduleHide() } else { hideTask?.cancel() }
    }

    /// Out of the way after five seconds of watching.
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, liveVideo else { return }
            chromeHidden = true
        }
    }

    private var background: some View {
        ZStack {
            Color(hex: 0x0b0d12)
            GlowField(palette: "ocean", intensity: 2.2).opacity(0.9)
            if let avatar = calls.peerUser?.avatar, !avatar.isEmpty {
                RemoteImage(avatar, maxPixel: 400).blur(radius: 60).opacity(0.45)
            }
        }
        .clipped()
    }

    private var statusLine: String {
        if let live = calls.liveAt, calls.phase == .live {
            return (calls.shaky ? String(localized: "Reconnecting… ") : "") + Fmt.duration(Date().timeIntervalSince(live))
        }
        return calls.status
    }

    private var topCapsule: some View {
        HStack(spacing: 10) {
            Button { withAnimation(Motion.morph) { calls.expanded = false } } label: {
                SymbolView(.chevronDown, size: 18).foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle().inset(by: -5))
            }
            .accessibilityLabel("Minimize")
            if calls.video && calls.remoteVideo != nil {
                Avatar(user: calls.peerUser, size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(calls.title).font(.subheadMediumC).foregroundStyle(.white)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(statusLine).font(.caption2C.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                    }
                }
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(calls.phase == .live ? statusLine : (calls.video ? String(localized: "Video call") : String(localized: "Voice call")))
                        .font(.subheadMediumC.monospacedDigit()).foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .padding(.leading, 4).padding(.trailing, 16)
        .frame(height: 44)
        .background(.black.opacity(0.35), in: Capsule())
        .glassCapsule(tint: .black.opacity(0.25), interactive: false)
    }

    @ViewBuilder
    private var controls: some View {
        if calls.phase == .incoming {
            HStack(spacing: 64) {
                captioned(String(localized: "Decline")) {
                    roundButton(.phoneDown, "Decline", color: Theme.red, size: 72) { calls.decline() }
                }
                captioned(String(localized: "call.answer", defaultValue: "Answer")) {
                    roundButton(calls.video ? .video : .phoneFill, "Accept", color: Theme.green, size: 72) { calls.accept() }
                }
            }
        } else {
            // As many buttons as fit the column, each with its word under it (the web's captions).
            let count = calls.video ? (calls.externalRoute ? 5 : 4) : 3
            let d = min(60, max(46, (columnWidth - 28 - CGFloat(count - 1) * 12) / CGFloat(count)))
            GlassGroup(spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    if calls.video {
                        captioned(String(localized: "call.camera", defaultValue: "Camera")) {
                            control(.video, slashed: calls.camOff, "Camera", on: !calls.camOff, size: d) { calls.toggleCamera() }
                        }
                        captioned(String(localized: "call.flip", defaultValue: "Flip")) {
                            control(.cameraRotate, "Flip camera", on: true, size: d) { calls.flip() }
                        }
                        if calls.externalRoute { routeControl(size: d) }
                    } else if calls.externalRoute {
                        routeControl(size: d)
                    } else {
                        captioned(String(localized: "Speaker")) {
                            control(.speaker, "Speaker", on: !calls.speaker, size: d) { calls.toggleSpeaker() }
                                .accessibilityAddTraits(calls.speaker ? .isSelected : [])
                        }
                    }
                    captioned(String(localized: "call.mute", defaultValue: "Mute")) {
                        control(.mic, slashed: calls.muted, "Microphone", on: !calls.muted, size: d) { calls.toggleMute() }
                            .accessibilityAddTraits(calls.muted ? .isSelected : [])
                    }
                    captioned(String(localized: "call.end", defaultValue: "End")) {
                        roundButton(.phoneDown, "End call", color: Theme.red, size: d) { calls.hangUp() }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
                .glass(RoundedRectangle(cornerRadius: 34, style: .continuous), tint: .black.opacity(0.35), interactive: false)
            }
        }
    }

    /// A control with its word under it.
    private func captioned<V: View>(_ caption: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(spacing: 6) {
            content()
            Text(caption)
                .font(.caption2C)
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .fixedSize()
                .accessibilityHidden(true)
        }
    }

    /// AirPods, a car, headphones connected: the button opens the system's
    /// list of where the sound can go, showing where it goes now.
    private func routeControl(size d: CGFloat) -> some View {
        let symbol: String = switch calls.route {
        case .bluetooth: "airpods"
        case .headphones: "headphones"
        case .car: "car.fill"
        case .speaker: "speaker.wave.2.fill"
        case .receiver: "iphone"
        case .other: "hifispeaker.fill"
        }
        let lit = calls.route != .receiver
        return captioned(String(localized: "call.audio", defaultValue: "Audio")) {
            ZStack {
                Image(systemName: symbol)
                    .font(.system(size: d * 0.36, weight: .semibold))
                    .foregroundStyle(lit ? .black : .white)
                    .frame(width: d, height: d)
                    .background(lit ? Color.white : Color.white.opacity(0.16), in: Circle())
                    .contentTransition(.symbolEffect(.replace))
                RoutePicker()
                    .frame(width: d, height: d)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Audio output")
        }
    }

    private func control(_ sym: Sym, slashed: Bool = false, _ title: LocalizedStringKey, on: Bool, size d: CGFloat = 60, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SymbolView(sym, size: d * 0.43, slashed: slashed)
                .foregroundStyle(on ? .white : .black)
                .frame(width: d, height: d)
                .background(on ? Color.white.opacity(0.16) : Color.white, in: Circle())
                .animation(Motion.quick, value: on)
        }
        .buttonStyle(.press(0.9))
        .accessibilityLabel(Text(title))
    }

    private func roundButton(_ sym: Sym, _ title: LocalizedStringKey, color: Color, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SymbolView(sym, size: size * 0.42)
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(color, in: Circle())
        }
        .buttonStyle(.press(0.9))
        .accessibilityLabel(Text(title))
    }

    // MARK: pill

    private var pill: some View {
        Button { withAnimation(Motion.morph) { calls.expanded = true } } label: {
            HStack(spacing: 10) {
                SymbolView(calls.video ? .video : .phoneFill, size: 17).foregroundStyle(Theme.green)
                Text(calls.title).font(.subheadMediumC).foregroundStyle(.white).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(statusLine).font(.footnoteC.monospacedDigit()).foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 40)
            .background(Color.black.opacity(0.85), in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        }
        .buttonStyle(.press(0.95))
        .padding(.top, max(insets.top, 6) + 2)
        .frame(width: max(0, size.width - insets.leading - insets.trailing))
        .offset(x: insets.leading)
        .accessibilityLabel("Return to call")
    }
}

/// A WebRTC video track drawn with Metal.
struct CallVideoView: UIViewRepresentable {
    let track: RTCVideoTrack
    var mirror: Bool
    var fill: Bool

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let v = RTCMTLVideoView(frame: .zero)
        v.videoContentMode = fill ? .scaleAspectFill : .scaleAspectFit
        v.clipsToBounds = true
        // Taps go to SwiftUI (show the controls, swap, fit).
        v.isUserInteractionEnabled = false
        track.add(v)
        context.coordinator.track = track
        v.transform = mirror ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        return v
    }

    func updateUIView(_ v: RTCMTLVideoView, context: Context) {
        if context.coordinator.track !== track {
            context.coordinator.track?.remove(v)
            track.add(v)
            context.coordinator.track = track
        }
        v.transform = mirror ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        let mode: UIView.ContentMode = fill ? .scaleAspectFill : .scaleAspectFit
        if v.videoContentMode != mode { v.videoContentMode = mode }
    }

    static func dismantleUIView(_ v: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.track?.remove(v)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var track: RTCVideoTrack?
    }
}

/// The system's audio route button (AirPods, speaker, car…), drawn clear so
/// our own button shows through; it only takes the tap and opens the list.
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = false
        v.tintColor = .clear
        v.activeTintColor = .clear
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

import SwiftUI
import WebRTC

/// The call screen: their picture (or their photo on a dark field), a dark
/// capsule at the top with who and how long, and one dark glass capsule of
/// controls at the bottom; it shrinks to a pill so the chat stays usable.
struct CallOverlay: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pip: CGSize = .zero
    @Namespace private var ns

    private var calls: CallManager { model.calls }

    var body: some View {
        ZStack(alignment: .top) {
            if calls.active {
                if calls.expanded {
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

    // MARK: full screen

    private var full: some View {
        GeometryReader { geo in
            ZStack {
                background
                if calls.video, let remote = calls.remoteVideo, calls.remoteCam {
                    CallVideoView(track: remote, mirror: false, fill: true)
                        .ignoresSafeArea()
                        .transition(.opacity)
                } else {
                    VStack(spacing: 18) {
                        Avatar(user: calls.peerUser ?? User(id: calls.roomId ?? "", display: calls.title), size: 132)
                            .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                            .scaleEffect(calls.phase == .incoming || calls.phase == .outgoing ? 1.04 : 1)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: calls.phase)
                        Text(calls.title).font(AppFont.make(30, .bold)).foregroundStyle(.white)
                        Text(statusLine).font(.subheadC.monospacedDigit()).foregroundStyle(.white.opacity(0.75))
                            .contentTransition(.numericText())
                        if !calls.remoteMic && calls.phase == .live {
                            Label("Muted", systemImage: "mic.slash.fill").font(.footnoteC).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .padding(.bottom, 80)
                }

                // Your own picture, small and rounder, drag it to a corner.
                if calls.video, let local = calls.localVideo, !calls.camOff, calls.phase != .incoming {
                    CallVideoView(track: local, mirror: calls.frontCamera, fill: true)
                        .frame(width: 112, height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.white.opacity(0.25), lineWidth: 1))
                        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                        .offset(pip)
                        .gesture(DragGesture().onChanged { pip = $0.translation }.onEnded { v in
                            let x: CGFloat = v.predictedEndLocation.x < geo.size.width / 2 ? -(geo.size.width - 112 - 40) : 0
                            let y: CGFloat = v.predictedEndLocation.y > geo.size.height / 2 ? geo.size.height - 160 - 260 : 0
                            withAnimation(Motion.move) { pip = CGSize(width: x, height: y) }
                        })
                        .padding(.top, geo.safeAreaInsets.top + 70)
                        .padding(.trailing, max(geo.safeAreaInsets.trailing, 16) + 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.scale.combined(with: .opacity))
                }

                topCapsule
                    .padding(.top, geo.safeAreaInsets.top + 8)
                    .frame(maxHeight: .infinity, alignment: .top)

                controls
                    .padding(.bottom, max(geo.safeAreaInsets.bottom, 16) + 12)
                    .padding(.trailing, geo.safeAreaInsets.trailing)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var background: some View {
        ZStack {
            Color(hex: 0x0b0d12)
            GlowField(palette: "ocean", intensity: 2.2).opacity(0.9)
            if let avatar = calls.peerUser?.avatar, !avatar.isEmpty {
                RemoteImage(avatar, maxPixel: 400).blur(radius: 60).opacity(0.45)
            }
        }
        .ignoresSafeArea()
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
                roundButton(.phoneDown, "Decline", color: Theme.red, size: 72) { calls.decline() }
                roundButton(calls.video ? .video : .phoneFill, "Accept", color: Theme.green, size: 72) { calls.accept() }
                    .phaseAnimator([1.0, 1.08]) { v, k in v.scaleEffect(k) } animation: { _ in .easeInOut(duration: 0.6) }
            }
        } else {
            GlassGroup(spacing: 8) {
                HStack(spacing: 12) {
                    if calls.video {
                        control(.video, slashed: calls.camOff, "Camera", on: !calls.camOff) { calls.toggleCamera() }
                        control(.cameraRotate, "Flip camera", on: true) { calls.flip() }
                    } else {
                        control(calls.speaker ? .speaker : .speakerOff, "Speaker", on: calls.speaker) { calls.toggleSpeaker() }
                    }
                    control(.mic, slashed: calls.muted, "Microphone", on: !calls.muted) { calls.toggleMute() }
                    roundButton(.phoneDown, "End call", color: Theme.red, size: 60) { calls.hangUp() }
                }
                .padding(10)
                .glass(Capsule(), tint: .black.opacity(0.35), interactive: false)
            }
        }
    }

    private func control(_ sym: Sym, slashed: Bool = false, _ title: LocalizedStringKey, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SymbolView(sym, size: 26, slashed: slashed)
                .foregroundStyle(on ? .white : .black)
                .frame(width: 60, height: 60)
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
        .padding(.top, 6)
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
    }

    static func dismantleUIView(_ v: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.track?.remove(v)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var track: RTCVideoTrack?
    }
}

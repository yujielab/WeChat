import SwiftUI
import CuvenCore

// MARK: - Apple HIG & Cuven Web Grounding
// - Apple HIG: Designing for iPhone Duo (clearing Dynamic Island, bottom dock, and 84pt/91pt right rail)
// - Apple WWDC18: Designing Fluid Interfaces (0.998 corner projection, 1:1 rubber-band, spring settle)
// - Cuven Web Parity: public/js/views/call.js (699-710, 890-976), public/js/ui/float.js (28-174),
//   public/js/ui/corners.js (16-89), public/css/call.css (266-336)

/// Minimized floating Picture-in-Picture call tile (`call.pipTile`) with 1:1 drag,
/// `VelocityProjector` (`0.998`) 4-corner spring snapping (`response: 0.38, damping: 0.84`),
/// and `28pt` off-screen edge-stash peek handle (`0.99` projection, `"Show call"`).
public struct FloatingCallPiPTile: View {
    public let session: CallSession
    public let metrics: DuoLayoutMetrics
    public let glassMode: GlassAppearanceMode
    public let useFrontCamera: Bool
    public let remoteAudioLevel: Double
    public let currentUserName: String
    public let currentUserAvatarURL: String?
    public let morphNamespace: Namespace.ID
    public let onExpand: () -> Void
    public let onToggleMute: () -> Void
    public let onToggleCamera: () -> Void
    public let onToggleSpeaker: () -> Void
    public let onEndCall: () -> Void

    @AppStorage("ui.call.pip.corner") private var savedCornerRaw: String = CallPiPCorner.topTrailing.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var restingPlace: CallPiPRestingPlace = .corner(.topTrailing)
    @State private var didInitializePlace = false
    @State private var dragStartOrigin: CGPoint?
    @State private var liveDragOrigin: CGPoint?
    @State private var velocityTracker = CuvenGestureVelocityTracker()

    public init(
        session: CallSession,
        metrics: DuoLayoutMetrics,
        glassMode: GlassAppearanceMode,
        useFrontCamera: Bool = true,
        remoteAudioLevel: Double = 0.0,
        currentUserName: String = "Me",
        currentUserAvatarURL: String? = nil,
        morphNamespace: Namespace.ID,
        onExpand: @escaping () -> Void,
        onToggleMute: @escaping () -> Void,
        onToggleCamera: @escaping () -> Void,
        onToggleSpeaker: @escaping () -> Void,
        onEndCall: @escaping () -> Void
    ) {
        self.session = session
        self.metrics = metrics
        self.glassMode = glassMode
        self.useFrontCamera = useFrontCamera
        self.remoteAudioLevel = remoteAudioLevel
        self.currentUserName = currentUserName
        self.currentUserAvatarURL = currentUserAvatarURL
        self.morphNamespace = morphNamespace
        self.onExpand = onExpand
        self.onToggleMute = onToggleMute
        self.onToggleCamera = onToggleCamera
        self.onToggleSpeaker = onToggleSpeaker
        self.onEndCall = onEndCall
    }

    public var body: some View {
        GeometryReader { proxy in
            let containerSize = proxy.size.width > 0 ? proxy.size : metrics.viewportSize
            let safeFrame = CallPiPGeometry.safePiPFrame(in: metrics, containerSize: containerSize)
            let edgeBounds = CallPiPGeometry.stashEdgeBounds(in: metrics, containerSize: containerSize)
            let tileSize = CallPiPGeometry.pipTileSize(
                in: metrics,
                mediaKind: session.mediaKind,
                containerSize: containerSize
            )
            let targetRestOrigin = CallPiPGeometry.targetOrigin(
                for: restingPlace,
                in: safeFrame,
                tileSize: tileSize,
                edgeBounds: edgeBounds
            )
            let activeOrigin = liveDragOrigin ?? targetRestOrigin
            let isDragging = liveDragOrigin != nil

            ZStack(alignment: .topLeading) {
                pipCardContent(
                    tileSize: tileSize,
                    isDragging: isDragging,
                    safeFrame: safeFrame
                )
                .frame(width: tileSize.width, height: tileSize.height)
                .matchedGeometryEffect(id: "call.surface.\(session.id)", in: morphNamespace)
                .position(
                    x: activeOrigin.x + tileSize.width * 0.5,
                    y: activeOrigin.y + tileSize.height * 0.5
                )
                .gesture(
                    dragGesture(
                        safeFrame: safeFrame,
                        tileSize: tileSize,
                        edgeBounds: edgeBounds,
                        currentTargetOrigin: targetRestOrigin
                    )
                )
                .onTapGesture {
                    handleTileTap(safeFrame: safeFrame, tileSize: tileSize)
                }
                .contextMenu {
                    Button {
                        CuvenHaptics.lightTap()
                        if restingPlace.isStashed {
                            unstashTile(in: safeFrame, tileSize: tileSize)
                        }
                        onExpand()
                    } label: {
                        Label("Back to Call", systemImage: session.mediaKind == .video ? "video.fill" : "phone.fill")
                    }

                    Button {
                        CuvenHaptics.lightTap()
                        onToggleMute()
                    } label: {
                        Label(
                            session.isMuted ? "Unmute Microphone" : "Mute Microphone",
                            systemImage: session.isMuted ? "mic.fill" : "mic.slash.fill"
                        )
                    }

                    if session.mediaKind == .video {
                        Button {
                            CuvenHaptics.lightTap()
                            onToggleCamera()
                        } label: {
                            Label(
                                session.isCameraEnabled ? "Turn Off Camera" : "Turn On Camera",
                                systemImage: session.isCameraEnabled ? "video.slash.fill" : "video.fill"
                            )
                        }
                    }

                    Button {
                        CuvenHaptics.selectionChanged()
                        onToggleSpeaker()
                    } label: {
                        Label(
                            session.isSpeakerEnabled ? "Use Receiver" : "Speakerphone",
                            systemImage: session.isSpeakerEnabled ? "speaker.wave.1.fill" : "speaker.wave.3.fill"
                        )
                    }

                    Divider()

                    Button(role: .destructive) {
                        CuvenHaptics.rigidImpact()
                        onEndCall()
                    } label: {
                        Label("End Call", systemImage: "phone.down.fill")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("call.pipTile")
                .accessibilityLabel(pipAccessibilityLabel)
                .accessibilityHint(restingPlace.isStashed ? "Double-tap to pull call window back onto screen" : "Double-tap to return to full call")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    if restingPlace.isStashed {
                        unstashTile(in: safeFrame, tileSize: tileSize)
                    } else {
                        onExpand()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .onAppear {
                guard !didInitializePlace else { return }
                didInitializePlace = true
                if let stored = CallPiPCorner(rawValue: savedCornerRaw) {
                    restingPlace = .corner(stored)
                }
            }
            .onChange(of: metrics.posture) { _, _ in
                // Keep tucked/corner PiP safely inside updated Duo posture bounds (`call.js:1197-1229`).
                if case let .stashed(side, y) = restingPlace {
                    let clampedY = min(max(y, safeFrame.minY), max(safeFrame.minY, safeFrame.maxY - tileSize.height))
                    restingPlace = .stashed(side: side, y: clampedY)
                }
            }
        }
    }

    // MARK: - Visual Tile Content

    @ViewBuilder
    private func pipCardContent(
        tileSize: CGSize,
        isDragging: Bool,
        safeFrame: CGRect
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: CallPiPGeometry.pipCornerRadius, style: .continuous)

        ZStack {
            // Stage surface: live/simulated video feed or atmospheric voice portrait
            if session.mediaKind == .video {
                SimulatedStudioVideoStage(
                    displayName: session.peerDisplay,
                    avatarURL: session.peerAvatarURL,
                    isCompactTile: true,
                    accentWarm: false,
                    reduceMotion: reduceMotion,
                    audioLevel: remoteAudioLevel
                )

                // Mini local camera inset when local camera is active
                if session.isCameraEnabled && !restingPlace.isStashed {
                    VStack {
                        HStack {
                            Spacer()
                            LocalCameraPreviewView(
                                userName: currentUserName,
                                avatarURL: currentUserAvatarURL,
                                isCameraEnabled: session.isCameraEnabled,
                                useFrontCamera: useFrontCamera,
                                isCompactTile: true
                            )
                            .frame(width: max(30, tileSize.width * 0.30), height: max(42, tileSize.height * 0.30))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(.white.opacity(0.28), lineWidth: 0.75)
                            }
                            .padding(6)
                        }
                        Spacer()
                    }
                }
            } else {
                ZStack {
                    Color(red: 0.094, green: 0.094, blue: 0.106)
                    VStack(spacing: 6) {
                        ZStack {
                            let ringScale = 1.0 + CGFloat(min(0.24, remoteAudioLevel * 0.25))
                            Circle()
                                .strokeBorder(CuvenColors.onlineGreen.opacity(0.45 + remoteAudioLevel * 0.4), lineWidth: 2)
                                .frame(width: 50 * ringScale, height: 50 * ringScale)

                            CuvenAvatarView(
                                name: session.peerDisplay,
                                urlString: session.peerAvatarURL,
                                size: 44,
                                isOnline: session.phase == .connected
                            )
                        }
                        Text(session.peerDisplay)
                            .font(CuvenFonts.cappedCaption(weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                    }
                }
            }

            // Top-left muted badge (`call.css:297-306`)
            if session.isMuted && !restingPlace.isStashed {
                VStack {
                    HStack {
                        Image(systemName: "mic.slash.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(.black.opacity(0.56), in: Circle())
                            .padding(7)
                        Spacer()
                    }
                    Spacer()
                }
            }

            // Bottom tabular live duration / status pill (`call.css:282-296`)
            if !restingPlace.isStashed {
                VStack {
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1.0)) { context in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(statusDotColor)
                                .frame(width: 5.5, height: 5.5)
                            Text(statusOrTimerText(at: context.date))
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(.black.opacity(0.58), in: Capsule())
                        .padding(.bottom, 7)
                    }
                }
            }

            // 28pt off-screen Edge-Stash Peek Handle ("Show call") (`call.css:308-321`, `float.js:28`)
            if case let .stashed(side, _) = restingPlace, !isDragging {
                HStack(spacing: 0) {
                    if side == .leading {
                        Spacer(minLength: 0)
                    }
                    stashPeekHandle(side: side)
                        .frame(width: CallPiPGeometry.stashPeekWidth)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            unstashTile(in: safeFrame, tileSize: tileSize)
                        }
                        .accessibilityLabel("Show call")
                    if side == .trailing {
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(.white.opacity(isDragging ? 0.34 : 0.18), lineWidth: 0.75)
        }
        .mask {
            if case let .stashed(side, _) = restingPlace, !isDragging {
                HStack(spacing: 0) {
                    if side == .leading {
                        Spacer(minLength: 0)
                    }
                    Rectangle()
                        .frame(width: CallPiPGeometry.stashPeekWidth)
                    if side == .trailing {
                        Spacer(minLength: 0)
                    }
                }
            } else {
                Rectangle()
            }
        }
        .shadow(
            color: .black.opacity(isDragging ? 0.50 : 0.38),
            radius: isDragging ? 22 : 16,
            x: 0,
            y: isDragging ? 14 : 10
        )
        .scaleEffect(isDragging ? 1.03 : 1.0)
        .animation(CuvenSprings.adaptive(CuvenSprings.pressBounce, reduceMotion: reduceMotion), value: isDragging)
    }

    private func stashPeekHandle(side: CallPiPStashSide) -> some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.54))
            VStack(spacing: 5) {
                Image(systemName: side == .leading ? "chevron.compact.right" : "chevron.compact.left")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white.opacity(0.92))
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 5, height: 5)
            }
        }
    }

    // MARK: - Gesture & Physics (`float.js:72-131`)

    private func dragGesture(
        safeFrame: CGRect,
        tileSize: CGSize,
        edgeBounds: (leading: CGFloat, trailing: CGFloat),
        currentTargetOrigin: CGPoint
    ) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { value in
                if dragStartOrigin == nil {
                    dragStartOrigin = liveDragOrigin ?? currentTargetOrigin
                    velocityTracker.reset()
                    CuvenHaptics.prepareAll()
                }
                velocityTracker.addSample(value.location)
                guard let start = dragStartOrigin else { return }
                let raw = CGPoint(
                    x: start.x + value.translation.width,
                    y: start.y + value.translation.height
                )
                liveDragOrigin = CallPiPGeometry.interactiveDragOrigin(
                    rawOrigin: raw,
                    in: safeFrame,
                    tileSize: tileSize,
                    allowStash: true,
                    edgeBounds: edgeBounds
                )
            }
            .onEnded { value in
                let finalOrigin = liveDragOrigin ?? currentTargetOrigin
                let tracked = velocityTracker.velocity()
                // Blend DragGesture's native velocity with our 100ms sliding-window tracker for rock-solid flick throws.
                let vx = abs(value.velocity.width) > abs(tracked.x) ? value.velocity.width : tracked.x
                let vy = abs(value.velocity.height) > abs(tracked.y) ? value.velocity.height : tracked.y

                // Project using canonical VelocityProjector (0.998 corner / 0.990 stash)
                let projectedStashMidX = finalOrigin.x
                    + VelocityProjector.project(velocity: vx, decelerationRate: CallPiPGeometry.stashDecelerationRate)
                    + tileSize.width * 0.5
                let projectedStashY = finalOrigin.y
                    + VelocityProjector.project(velocity: vy, decelerationRate: CallPiPGeometry.stashDecelerationRate)

                let nextPlace: CallPiPRestingPlace
                if projectedStashMidX < edgeBounds.leading {
                    let clampedY = min(max(projectedStashY, safeFrame.minY), max(safeFrame.minY, safeFrame.maxY - tileSize.height))
                    nextPlace = .stashed(side: .leading, y: clampedY)
                } else if projectedStashMidX > edgeBounds.trailing {
                    let clampedY = min(max(projectedStashY, safeFrame.minY), max(safeFrame.minY, safeFrame.maxY - tileSize.height))
                    nextPlace = .stashed(side: .trailing, y: clampedY)
                } else {
                    let projectedCornerOrigin = CGPoint(
                        x: finalOrigin.x + VelocityProjector.project(velocity: vx, decelerationRate: CallPiPGeometry.cornerDecelerationRate),
                        y: finalOrigin.y + VelocityProjector.project(velocity: vy, decelerationRate: CallPiPGeometry.cornerDecelerationRate)
                    )
                    let corner = CallPiPGeometry.nearestCorner(
                        in: safeFrame,
                        tileSize: tileSize,
                        to: projectedCornerOrigin
                    )
                    nextPlace = .corner(corner)
                }

                let becameStashed = nextPlace.isStashed && !restingPlace.isStashed
                if let newCorner = nextPlace.corner {
                    savedCornerRaw = newCorner.rawValue
                }

                dragStartOrigin = nil
                velocityTracker.reset()

                withAnimation(CuvenSprings.adaptive(CuvenSprings.pipSnap, reduceMotion: reduceMotion)) {
                    restingPlace = nextPlace
                    liveDragOrigin = nil
                }

                if becameStashed {
                    CuvenHaptics.selectionChanged()
                } else {
                    CuvenHaptics.softImpact()
                }
            }
    }

    private func handleTileTap(safeFrame: CGRect, tileSize: CGSize) {
        if restingPlace.isStashed {
            unstashTile(in: safeFrame, tileSize: tileSize)
        } else {
            CuvenHaptics.lightTap()
            onExpand()
        }
    }

    private func unstashTile(in safeFrame: CGRect, tileSize: CGSize) {
        guard case let .stashed(side, y) = restingPlace else { return }
        let corner = CallPiPGeometry.unstashCorner(
            in: safeFrame,
            tileSize: tileSize,
            side: side,
            currentY: y
        )
        savedCornerRaw = corner.rawValue
        CuvenHaptics.softImpact()
        withAnimation(CuvenSprings.adaptive(CuvenSprings.pipSnap, reduceMotion: reduceMotion)) {
            restingPlace = .corner(corner)
        }
    }

    private var statusDotColor: Color {
        switch session.phase {
        case .connected:
            return CuvenColors.onlineGreen
        case .unstable:
            return CuvenColors.warningAmber
        case .outgoingRinging, .incomingRinging, .connecting:
            return .white.opacity(0.85)
        case .idle, .ended:
            return CuvenColors.dangerRed
        }
    }

    private func statusOrTimerText(at date: Date) -> String {
        switch session.phase {
        case .connected:
            let secs = CallPiPGeometry.elapsedSeconds(from: session.startedAt, now: date)
            return CallPiPGeometry.formattedDuration(seconds: secs)
        case .unstable:
            return "Unstable"
        case .connecting:
            return "Connecting…"
        case .outgoingRinging:
            return "Calling…"
        case .incomingRinging:
            return "Ringing…"
        case .ended:
            return "Ended"
        case .idle:
            return "Call"
        }
    }

    private var pipAccessibilityLabel: String {
        if restingPlace.isStashed {
            return "Show call"
        }
        let status = statusOrTimerText(at: Date())
        return "Back to call: \(session.peerDisplay), \(status)"
    }
}

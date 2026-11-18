import SwiftUI
import CuvenCore

// MARK: - Apple HIG & Cuven Web Grounding
// - Apple HIG: Designing for iPhone Duo (duoHalfLaptop tabletop split: video stage above horizontal crease,
//   ergonomic Liquid Glass controls + live chat preview on flat lower half; duoOpen side-by-side stage
//   clearing 84pt right rail; duoHalfBook vertical spine clearance; duoClosed clearing 91pt right rail)
// - Apple HIG: Materials -> Liquid Glass (dark frosted heading & floating control capsules via CuvenGlassGroup)
// - Cuven Web Parity: public/js/views/call.js (619-1400), public/css/call.css (1-423), public/css/posture.css (26-50)

/// Full-featured native Active Audio & Video Call surface (`call.activeOverlay`) adapting across all 6 `DuoPosture` states.
public struct ActiveCallView: View {
    public let session: CallSession
    public let metrics: DuoLayoutMetrics
    public let backdropPreset: BackdropPreset
    public let glassMode: GlassAppearanceMode
    public let currentUserName: String
    public let currentUserAvatarURL: String?
    public let recentMessages: [Message]
    public let typingPreview: String?
    public let engine: CloudflareSFUWebRTCEngine
    public let morphNamespace: Namespace.ID
    public let onToggleMute: () -> Void
    public let onToggleCamera: () -> Void
    public let onToggleSpeaker: () -> Void
    public let onMinimize: () -> Void
    public let onEndCall: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isCalmChromeHidden = false
    @State private var selfTileCorner: CallPiPCorner = .topTrailing
    @State private var selfTileDragOffset: CGSize = .zero
    @State private var isDraggingSelfTile = false
    @State private var selfTileVelocityTracker = CuvenGestureVelocityTracker()

    @State private var pullDownOffset: CGSize = .zero
    @State private var isPullingToMinimize = false
    @State private var pullVelocityTracker = CuvenGestureVelocityTracker()

    public init(
        session: CallSession,
        metrics: DuoLayoutMetrics,
        backdropPreset: BackdropPreset,
        glassMode: GlassAppearanceMode,
        currentUserName: String,
        currentUserAvatarURL: String?,
        recentMessages: [Message] = [],
        typingPreview: String? = nil,
        engine: CloudflareSFUWebRTCEngine,
        morphNamespace: Namespace.ID,
        onToggleMute: @escaping () -> Void,
        onToggleCamera: @escaping () -> Void,
        onToggleSpeaker: @escaping () -> Void,
        onMinimize: @escaping () -> Void,
        onEndCall: @escaping () -> Void
    ) {
        self.session = session
        self.metrics = metrics
        self.backdropPreset = backdropPreset
        self.glassMode = glassMode
        self.currentUserName = currentUserName
        self.currentUserAvatarURL = currentUserAvatarURL
        self.recentMessages = recentMessages
        self.typingPreview = typingPreview
        self.engine = engine
        self.morphNamespace = morphNamespace
        self.onToggleMute = onToggleMute
        self.onToggleCamera = onToggleCamera
        self.onToggleSpeaker = onToggleSpeaker
        self.onMinimize = onMinimize
        self.onEndCall = onEndCall
    }

    private var rightRailClearance: CGFloat {
        guard metrics.hasRightSystemColumn else { return metrics.safeAreaRight }
        return max(metrics.safeAreaRight, metrics.railCenterFromRight + metrics.railWidth * 0.5 + 8)
    }

    private var pullShrinkScale: CGFloat {
        guard isPullingToMinimize, pullDownOffset.height > 0 else { return 1.0 }
        let ratio = min(1.0, pullDownOffset.height / 420.0)
        return 1.0 - ratio * 0.22
    }

    private var pullCornerRadius: CGFloat {
        guard isPullingToMinimize, pullDownOffset.height > 0 else { return 0 }
        let ratio = min(1.0, pullDownOffset.height / 240.0)
        return CallPiPGeometry.pipCornerRadius * ratio
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let availableWidth = max(1, size.width - rightRailClearance)

            ZStack(alignment: .topLeading) {
                callPostureBody(fullSize: size, stageWidth: availableWidth)
                    .frame(width: availableWidth, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: pullCornerRadius, style: .continuous))
                    .scaleEffect(pullShrinkScale)
                    .offset(pullDownOffset)
                    .matchedGeometryEffect(id: "call.surface.\(session.id)", in: morphNamespace)
                    .gesture(pullDownMinimizeGesture(in: size))
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("call.activeOverlay")
        .onChange(of: session.phase) { _, newPhase in
            if newPhase == .unstable {
                isCalmChromeHidden = false
            }
        }
    }

    // MARK: - Posture-Adaptive Stage Router

    @ViewBuilder
    private func callPostureBody(fullSize: CGSize, stageWidth: CGFloat) -> some View {
        switch metrics.posture {
        case .duoHalfLaptop:
            laptopTabletopSplitLayout(size: CGSize(width: stageWidth, height: fullSize.height))
        case .duoOpen:
            duoOpenSideBySideLayout(size: CGSize(width: stageWidth, height: fullSize.height))
        case .duoHalfBook:
            duoBookSplitLayout(fullSize: fullSize, stageWidth: stageWidth)
        case .iPhoneCompact, .iPhoneSplit, .duoClosed:
            standardFullStageLayout(size: CGSize(width: stageWidth, height: fullSize.height))
        }
    }

    // MARK: - 1. Standard / Closed / Landscape Full-Stage Layout (`call.css:9-423`)

    private func standardFullStageLayout(size: CGSize) -> some View {
        let topClearance = metrics.posture == .duoClosed
            ? max(metrics.safeAreaTop + 12, min(72, metrics.railTopReserve * 0.42))
            : max(metrics.safeAreaTop + 10, 20)
        let bottomClearance = max(metrics.safeAreaBottom, 16) + 10

        return ZStack {
            atmosphericCallBackground

            // Primary Remote Video or Voice Stage
            primaryMediaStage(isCompactContext: false)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard session.mediaKind == .video, session.phase == .connected else { return }
                    withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
                        isCalmChromeHidden.toggle()
                    }
                }

            // Draggable 4-Corner-Snapping Self-Preview Inset (`call.css:198-239, 422`)
            if session.mediaKind == .video {
                draggableSelfPreviewLayer(
                    in: size,
                    topInset: isCalmChromeHidden ? (metrics.safeAreaTop + 14) : (topClearance + 78),
                    bottomInset: isCalmChromeHidden ? (bottomClearance + 12) : (bottomClearance + 88)
                )
            }

            // Top Dark Liquid Glass Heading Capsule + Minimize Button (`call.css:83-147, 370-395`)
            VStack(spacing: 0) {
                topHeadingBar(includeMinimizeButton: true)
                    .padding(.top, topClearance)
                    .padding(.leading, metrics.safeAreaLeft + 12)
                    .padding(.trailing, 12)
                    .opacity(isCalmChromeHidden ? 0 : 1)
                    .offset(y: isCalmChromeHidden ? -10 : 0)
                    .allowsHitTesting(!isCalmChromeHidden)

                Spacer()

                // Bottom Dark Liquid Glass Floating Control Capsule (`call.css:396-421`)
                floatingControlCapsule(includeMinimizeAction: false)
                    .padding(.horizontal, 12)
                    .padding(.bottom, bottomClearance)
                    .opacity(isCalmChromeHidden ? 0 : 1)
                    .offset(y: isCalmChromeHidden ? 14 : 0)
                    .allowsHitTesting(!isCalmChromeHidden)
            }
            .animation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion), value: isCalmChromeHidden)
        }
    }

    // MARK: - 2. iPhone Duo Half-Laptop Tabletop Split (`posture.css:26-50`, Follow-up Spec §3 F11)
    // Upper half above horizontal crease: Full-bleed video/voice stage + floating status pill.
    // Crease band: 28pt hinge exclusion zone (zero controls in the bend).
    // Flat lower half: Ergonomic Dark Liquid Glass controls + Live Chat Preview strip!

    private func laptopTabletopSplitLayout(size: CGSize) -> some View {
        let hingeRect = metrics.hingeDivisionRect ?? CGRect(
            x: 0,
            y: floor((size.height - 28) * 0.5),
            width: size.width,
            height: 28
        )
        let topHeight = max(168, hingeRect.minY)
        let bottomHeight = max(168, size.height - hingeRect.maxY)

        return VStack(spacing: 0) {
            // UPPER DISPLAY HALF (Above Horizontal Fold Crease)
            ZStack(alignment: .top) {
                atmosphericCallBackground

                primaryMediaStage(isCompactContext: true)

                if session.mediaKind == .video {
                    HStack {
                        Spacer()
                        selfPreviewTileView(width: 96, height: 132)
                            .padding(.top, max(metrics.safeAreaTop + 58, 66))
                            .padding(.trailing, 14)
                    }
                }

                topHeadingBar(includeMinimizeButton: false)
                    .padding(.top, max(metrics.safeAreaTop + 8, 14))
                    .padding(.horizontal, 14)

                // Soft gradient feather into the hinge (`posture.css:40-50`)
                VStack {
                    Spacer()
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.82)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 36)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: topHeight)
            .clipped()

            // HORIZONTAL HINGE CREASE EXCLUSION ZONE (`ReservedRegion.Kind.division`)
            ZStack {
                Color.black
                CuvenColors.hingeGutterShade
                VStack(spacing: 0) {
                    Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5)
                    Spacer()
                    Rectangle().fill(.white.opacity(0.06)).frame(height: 0.5)
                }
            }
            .frame(width: size.width, height: hingeRect.height)
            .accessibilityHidden(true)

            // LOWER FLAT TABLETOP HALF (Ergonomic Glass Controls + Live Chat Preview)
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.05, green: 0.06, blue: 0.08),
                        Color.black
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(spacing: 12) {
                    // Ergonomic Tabletop Liquid Glass Control Deck
                    floatingControlCapsule(includeMinimizeAction: true)
                        .padding(.top, 12)

                    // Live Room Chat Preview & Quick Context Card on Flat Lower Half
                    tabletopChatPreviewCard
                        .padding(.horizontal, 16)

                    Spacer(minLength: max(metrics.safeAreaBottom, 8))
                }
            }
            .frame(width: size.width, height: bottomHeight)
            .clipped()
        }
    }

    // MARK: - 3. iPhone Duo Open Inner Canvas (`951x669pt`, Side-by-Side Stage Clearing 84pt Right Rail)

    private func duoOpenSideBySideLayout(size: CGSize) -> some View {
        let topClearance = max(metrics.safeAreaTop + 10, 18)
        let bottomClearance = max(metrics.safeAreaBottom, 16) + 10

        return ZStack {
            atmosphericCallBackground

            VStack(spacing: 14) {
                topHeadingBar(includeMinimizeButton: true)
                    .padding(.top, topClearance)
                    .padding(.horizontal, 18)

                // Side-by-Side Multi-Tile Stage Clearing 84pt Right Rail
                HStack(spacing: 14) {
                    // Primary Remote Stage Tile
                    ZStack {
                        primaryMediaStage(isCompactContext: false)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(.white.opacity(0.14), lineWidth: 0.75)
                    }

                    // Secondary Local Studio Video OR Live Room Context Tile
                    if session.mediaKind == .video {
                        ZStack(alignment: .bottomLeading) {
                            secondaryVideoStageContent
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                            HStack(spacing: 6) {
                                Image(systemName: session.isMuted ? "mic.slash.fill" : "mic.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(session.isMuted ? CuvenColors.dangerRed : .white)
                                Text(engine.isSwappedVideoStage ? session.peerDisplay : "\(currentUserName) (You)")
                                    .font(CuvenFonts.cappedCaption(weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.46), in: Capsule())
                            .padding(12)
                        }
                        .frame(width: max(220, size.width * 0.36))
                        .frame(maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .strokeBorder(.white.opacity(0.16), lineWidth: 0.75)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .onTapGesture {
                            CuvenHaptics.selectionChanged()
                            withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
                                engine.toggleSwappedStage()
                            }
                        }
                        .accessibilityIdentifier("call.selfPreviewTile")
                        .accessibilityLabel("Swap camera stage")
                        .accessibilityAddTraits(.isButton)
                    } else {
                        duoOpenAudioSideContextCard
                            .frame(width: max(240, size.width * 0.36))
                            .frame(maxHeight: .infinity)
                    }
                }
                .padding(.horizontal, 18)

                floatingControlCapsule(includeMinimizeAction: false)
                    .padding(.bottom, bottomClearance)
            }
        }
    }

    // MARK: - 4. iPhone Duo Half-Book Vertical Hinge Split (`462 | 28 | 461`)

    private func duoBookSplitLayout(fullSize: CGSize, stageWidth: CGFloat) -> some View {
        let hinge = metrics.hingeDivisionRect ?? CGRect(
            x: floor((fullSize.width - 28) * 0.5),
            y: 0,
            width: 28,
            height: fullSize.height
        )
        let leftWidth = min(stageWidth, max(180, hinge.minX))
        let rightWidth = max(160, stageWidth - hinge.maxX)
        let topClearance = max(metrics.safeAreaTop + 10, 18)
        let bottomClearance = max(metrics.safeAreaBottom, 16) + 12

        return ZStack {
            atmosphericCallBackground

            HStack(spacing: 0) {
                // Left Book Page: Primary Remote Stage + Heading Capsule
                ZStack(alignment: .top) {
                    primaryMediaStage(isCompactContext: false)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .padding(.top, topClearance + 66)
                        .padding(.bottom, bottomClearance)
                        .padding(.horizontal, 12)

                    topHeadingBar(includeMinimizeButton: true)
                        .padding(.top, topClearance)
                        .padding(.horizontal, 12)
                }
                .frame(width: leftWidth, height: fullSize.height)

                // Vertical Book Spine Exclusion Band (`28pt`)
                Rectangle()
                    .fill(.black.opacity(0.35))
                    .frame(width: hinge.width, height: fullSize.height)
                    .accessibilityHidden(true)

                // Right Book Page: Self Stage / Chat Context + Control Deck
                VStack(spacing: 14) {
                    Spacer(minLength: topClearance)

                    if session.mediaKind == .video {
                        secondaryVideoStageContent
                            .frame(maxWidth: .infinity)
                            .frame(height: min(260, fullSize.height * 0.42))
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .strokeBorder(.white.opacity(0.16), lineWidth: 0.75)
                            }
                            .padding(.horizontal, 14)
                    }

                    tabletopChatPreviewCard
                        .padding(.horizontal, 14)

                    Spacer()

                    floatingControlCapsule(includeMinimizeAction: false)
                        .padding(.horizontal, 10)
                        .padding(.bottom, bottomClearance)
                }
                .frame(width: rightWidth, height: fullSize.height)
            }
        }
    }

    // MARK: - Atmospheric Backdrop & Media Stage Building Blocks

    private var atmosphericCallBackground: some View {
        ZStack {
            CuvenBackdropView(preset: backdropPreset, customImageURL: nil, forceDark: true)
            LinearGradient(
                colors: [
                    .black.opacity(0.32),
                    .black.opacity(0.46),
                    .black.opacity(0.72)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func primaryMediaStage(isCompactContext: Bool) -> some View {
        if session.mediaKind == .video && !engine.remotePeerCameraOff {
            if engine.isSwappedVideoStage {
                LocalCameraPreviewView(
                    userName: currentUserName,
                    avatarURL: currentUserAvatarURL,
                    isCameraEnabled: session.isCameraEnabled,
                    useFrontCamera: engine.usingFrontCamera,
                    isCompactTile: false
                )
            } else {
                SimulatedStudioVideoStage(
                    displayName: session.peerDisplay,
                    avatarURL: session.peerAvatarURL,
                    isCompactTile: false,
                    accentWarm: false,
                    reduceMotion: reduceMotion,
                    audioLevel: engine.remoteAudioLevel
                )
            }
        } else {
            // Audio Call OR Peer Camera Off: Centered Portrait + Audio-Reactive Ring (`call.css:54-80`)
            voicePortraitStage(avatarSize: isCompactContext ? 88 : 112)
        }
    }

    @ViewBuilder
    private var secondaryVideoStageContent: some View {
        if engine.isSwappedVideoStage {
            SimulatedStudioVideoStage(
                displayName: session.peerDisplay,
                avatarURL: session.peerAvatarURL,
                isCompactTile: true,
                accentWarm: false,
                reduceMotion: reduceMotion,
                audioLevel: engine.remoteAudioLevel
            )
        } else {
            LocalCameraPreviewView(
                userName: currentUserName,
                avatarURL: currentUserAvatarURL,
                isCameraEnabled: session.isCameraEnabled,
                useFrontCamera: engine.usingFrontCamera,
                isCompactTile: false
            )
        }
    }

    private func voicePortraitStage(avatarSize: CGFloat) -> some View {
        let level = reduceMotion ? 0.0 : engine.remoteAudioLevel
        let ringScale = 1.0 + CGFloat(min(0.22, level * 0.22))
        let ringOpacity = min(0.95, 0.14 + level * 1.35)

        return VStack(spacing: 14) {
            ZStack {
                Circle()
                    .strokeBorder(.white.opacity(ringOpacity * 0.65), lineWidth: 3)
                    .shadow(color: .white.opacity(ringOpacity * 0.22), radius: 18)
                    .frame(width: avatarSize + 20, height: avatarSize + 20)
                    .scaleEffect(ringScale)
                    .animation(.linear(duration: 0.12), value: level)

                CuvenAvatarView(
                    name: session.peerDisplay,
                    urlString: session.peerAvatarURL,
                    size: avatarSize,
                    isOnline: session.phase == .connected
                )
                .shadow(color: .black.opacity(0.55), radius: 26, x: 0, y: 14)
            }

            if session.mediaKind == .video && engine.remotePeerCameraOff {
                HStack(spacing: 6) {
                    Image(systemName: "video.slash.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Their camera is off")
                        .font(CuvenFonts.cappedCaption(weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.76))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.black.opacity(0.40), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Top Dark Liquid Glass Heading Capsule (`call.css:370-395`)

    private func topHeadingBar(includeMinimizeButton: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            if includeMinimizeButton {
                Button {
                    CuvenHaptics.lightTap()
                    onMinimize()
                } label: {
                    Image(systemName: "pip.enter")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.32), in: Circle())
                        .cuvenLiquidGlass(mode: glassMode, cornerRadius: 22, interactiveBounce: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("call.minimize")
                .accessibilityLabel("Minimize")
            }

            TimelineView(.periodic(from: .now, by: 1.0)) { timeline in
                HStack(spacing: 10) {
                    CuvenAvatarView(
                        name: session.peerDisplay,
                        urlString: session.peerAvatarURL,
                        size: 40,
                        isOnline: session.phase == .connected
                    )
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            connectionStateIndicator
                            Text(statusText(at: timeline.date))
                                .font(CuvenFonts.cappedCaption(weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(statusTextColor)
                                .lineLimit(1)
                        }

                        Text(session.peerDisplay)
                            .font(CuvenFonts.cappedHeadline(weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if engine.remotePeerMuted {
                            HStack(spacing: 4) {
                                Image(systemName: "mic.slash.fill")
                                    .font(.system(size: 10, weight: .bold))
                                Text("They muted")
                                    .font(CuvenFonts.cappedCaption2(weight: .semibold))
                            }
                            .foregroundStyle(.white.opacity(0.78))
                        }
                    }

                    Spacer(minLength: 4)

                    // Encrypted Realtime SFU badge
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text(session.mediaKind == .video ? "HD" : "Voice")
                            .font(CuvenFonts.cappedCaption2(weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.10), in: Capsule())
                }
                .padding(.leading, 8)
                .padding(.trailing, 12)
                .padding(.vertical, 8)
                .background(Color(red: 0.11, green: 0.11, blue: 0.12).opacity(0.55), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .cuvenLiquidGlass(mode: glassMode, cornerRadius: 22)
            }
        }
        .cuvenCappedDynamicType()
    }

    @ViewBuilder
    private var connectionStateIndicator: some View {
        if session.phase == .unstable || engine.connectionQuality == .unstable {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(CuvenColors.warningAmber)
        } else if session.phase == .connected {
            Circle()
                .fill(CuvenColors.onlineGreen)
                .frame(width: 7, height: 7)
        } else {
            Circle()
                .fill(.white.opacity(0.65))
                .frame(width: 6, height: 6)
        }
    }

    private var statusTextColor: Color {
        if session.phase == .unstable || engine.connectionQuality == .unstable {
            return CuvenColors.warningAmber
        }
        return .white.opacity(0.78)
    }

    private func statusText(at date: Date) -> String {
        if let notice = engine.lastTransportNotice, !notice.isEmpty {
            return notice
        }
        switch session.phase {
        case .outgoingRinging:
            return session.mediaKind == .video ? "Video call · Calling…" : "Calling…"
        case .incomingRinging:
            return "Incoming call…"
        case .connecting:
            return "Connecting…"
        case .unstable:
            return "Connection unstable, reconnecting…"
        case .connected:
            let elapsed = CallPiPGeometry.elapsedSeconds(from: session.startedAt, now: date)
            return CallPiPGeometry.formattedDuration(seconds: elapsed)
        case .ended:
            return "Call ended"
        case .idle:
            return ""
        }
    }

    // MARK: - Bottom Dark Liquid Glass Floating Control Capsule (`call.css:396-421`)

    private func floatingControlCapsule(includeMinimizeAction: Bool) -> some View {
        CuvenGlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                if session.mediaKind == .video {
                    // 1. Camera On/Off (`call.camera`) — active white toggle when camera is turned OFF (`call.css:183`)
                    callCircleToggleButton(
                        id: "call.camera",
                        label: session.isCameraEnabled ? "Turn off camera" : "Turn on camera",
                        systemImage: session.isCameraEnabled ? "video.fill" : "video.slash.fill",
                        isActiveToggle: !session.isCameraEnabled,
                        action: onToggleCamera
                    )

                    // 2. Flip Camera (`call.flipCamera`)
                    if session.isCameraEnabled {
                        callCircleToggleButton(
                            id: "call.flipCamera",
                            label: "Flip camera",
                            systemImage: "arrow.triangle.2.circlepath.camera.fill",
                            isActiveToggle: !engine.usingFrontCamera,
                            action: { engine.flipCamera() }
                        )
                    }
                }

                // 3. Mute Microphone (`call.mute`) — active white toggle when muted (`call.css:183`)
                callCircleToggleButton(
                    id: "call.mute",
                    label: session.isMuted ? "Unmute" : "Mute",
                    systemImage: session.isMuted ? "mic.slash.fill" : "mic.fill",
                    isActiveToggle: session.isMuted,
                    action: onToggleMute
                )

                // 4. Speaker / Audio Route (`call.speaker`)
                callCircleToggleButton(
                    id: "call.speaker",
                    label: "Speaker",
                    systemImage: session.isSpeakerEnabled ? "speaker.wave.3.fill" : "speaker.wave.1.fill",
                    isActiveToggle: session.isSpeakerEnabled && session.mediaKind == .audio,
                    action: onToggleSpeaker
                )

                // 5. Tabletop Minimize Button (when header omits it in duoHalfLaptop)
                if includeMinimizeAction {
                    callCircleToggleButton(
                        id: "call.minimize",
                        label: "Minimize",
                        systemImage: "pip.enter",
                        isActiveToggle: false,
                        action: onMinimize
                    )
                }

                // 6. Red End-Call Pill (`call.end`, `#FF4D5E` / `CuvenColors.dangerRed`)
                Button {
                    CuvenHaptics.rigidImpact()
                    onEndCall()
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 1.0, green: 0.30, blue: 0.37),
                                        CuvenColors.dangerRed
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 58, height: 58)
                            .overlay {
                                Circle().strokeBorder(.white.opacity(0.28), lineWidth: 0.75)
                            }
                            .shadow(color: CuvenColors.dangerRed.opacity(0.45), radius: 14, x: 0, y: 6)

                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 23, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("call.end")
                .accessibilityLabel("End Call")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                Color(red: 0.11, green: 0.11, blue: 0.12).opacity(0.60),
                in: Capsule()
            )
            .cuvenLiquidGlass(mode: glassMode, cornerRadius: 40, interactiveBounce: true)
        }
    }

    private func callCircleToggleButton(
        id: String,
        label: String,
        systemImage: String,
        isActiveToggle: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            CuvenHaptics.lightTap()
            action()
        } label: {
            ZStack {
                Circle()
                    .fill(isActiveToggle ? Color.white : Color.white.opacity(0.15))
                    .frame(width: 56, height: 56)
                    .overlay {
                        Circle()
                            .strokeBorder(.white.opacity(isActiveToggle ? 0.0 : 0.18), lineWidth: 0.5)
                    }

                Image(systemName: systemImage)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(isActiveToggle ? Color(red: 0.094, green: 0.094, blue: 0.106) : Color.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityLabel(label)
    }

    // MARK: - Tabletop & DuoOpen Chat Preview Cards

    private var tabletopChatPreviewCard: some View {
        let tailMessages = Array(recentMessages.suffix(2))

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Conversation · \(session.peerDisplay)", systemImage: "bubble.left.and.bubble.right.fill")
                    .font(CuvenFonts.cappedCaption(weight: .semibold))
                    .foregroundStyle(.white.opacity(0.74))
                    .lineLimit(1)

                Spacer()

                Button {
                    CuvenHaptics.selectionChanged()
                    onMinimize()
                } label: {
                    HStack(spacing: 4) {
                        Text("Reply in Chat")
                            .font(CuvenFonts.cappedCaption(weight: .semibold))
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(CuvenColors.momentsSkyBlue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            if let typingPreview, !typingPreview.isEmpty {
                HStack(spacing: 6) {
                    Circle().fill(CuvenColors.onlineGreen).frame(width: 6, height: 6)
                    Text("\(session.peerDisplay) is typing: \"\(typingPreview)\"")
                        .font(CuvenFonts.cappedFootnote(weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                }
            } else if tailMessages.isEmpty {
                Text("Call stays live in a floating window when you return to the conversation.")
                    .font(CuvenFonts.cappedFootnote())
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(2)
            } else {
                ForEach(tailMessages) { msg in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(msg.senderDisplay):")
                            .font(CuvenFonts.cappedFootnote(weight: .semibold))
                            .foregroundStyle(.white.opacity(0.82))
                        Text(msg.text.isEmpty ? "[\(msg.kind.rawValue.capitalized)]" : msg.text)
                            .font(CuvenFonts.cappedFootnote())
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 520)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        }
        .cuvenCappedDynamicType()
    }

    private var duoOpenAudioSideContextCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Cloudflare Realtime SFU")
                    .font(CuvenFonts.cappedCaption(weight: .semibold))
                    .foregroundStyle(CuvenColors.onlineGreen)
                Text("Direct UDP audio path active. Minimize anytime to browse Moments or Memories while staying connected.")
                    .font(CuvenFonts.cappedFootnote())
                    .foregroundStyle(.white.opacity(0.70))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(.white.opacity(0.12))

            tabletopChatPreviewCard

            Spacer()
        }
        .padding(18)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.75)
        }
    }

    // MARK: - Draggable 4-Corner Self-Preview Tile (`call.js:1062-1107`, `call.css:198-239, 422`)

    private func draggableSelfPreviewLayer(
        in stageSize: CGSize,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> some View {
        let isWide = stageSize.width > stageSize.height
        let tileW: CGFloat = isWide ? 150 : 104
        let tileH: CGFloat = isWide ? 104 : 150
        let tileSize = CGSize(width: tileW, height: tileH)

        let minX = metrics.safeAreaLeft + 12
        let maxX = max(minX + tileW, stageSize.width - 12)
        let minY = topInset
        let maxY = max(minY + tileH, stageSize.height - bottomInset)
        let frame = CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))

        let restOrigin = CallPiPGeometry.cornerOrigin(in: frame, tileSize: tileSize, corner: selfTileCorner)
        let rawOrigin = CGPoint(
            x: restOrigin.x + selfTileDragOffset.width,
            y: restOrigin.y + selfTileDragOffset.height
        )
        let activeOrigin = isDraggingSelfTile
            ? CallPiPGeometry.interactiveDragOrigin(
                rawOrigin: rawOrigin,
                in: frame,
                tileSize: tileSize,
                allowStash: false
            )
            : restOrigin

        return ZStack(alignment: .topLeading) {
            selfPreviewTileView(width: tileW, height: tileH)
                .position(
                    x: activeOrigin.x + tileW * 0.5,
                    y: activeOrigin.y + tileH * 0.5
                )
                .gesture(
                    DragGesture(minimumDistance: 6, coordinateSpace: .local)
                        .onChanged { value in
                            if !isDraggingSelfTile {
                                isDraggingSelfTile = true
                                isCalmChromeHidden = false
                                selfTileVelocityTracker.reset()
                            }
                            selfTileVelocityTracker.addSample(value.location)
                            selfTileDragOffset = value.translation
                        }
                        .onEnded { value in
                            selfTileVelocityTracker.addSample(value.location)
                            let v = selfTileVelocityTracker.velocity()
                            let releaseOrigin = CGPoint(
                                x: restOrigin.x + value.translation.width,
                                y: restOrigin.y + value.translation.height
                            )
                            let destination = CallPiPGeometry.restingPlace(
                                in: frame,
                                tileSize: tileSize,
                                currentOrigin: releaseOrigin,
                                velocity: CGVector(dx: v.x, dy: v.y),
                                allowStash: false
                            )
                            withAnimation(CuvenSprings.adaptive(CuvenSprings.pipSnap, reduceMotion: reduceMotion)) {
                                isDraggingSelfTile = false
                                selfTileDragOffset = .zero
                                if let nextCorner = destination.corner {
                                    selfTileCorner = nextCorner
                                }
                            }
                            CuvenHaptics.softImpact()
                        }
                )
                .onTapGesture {
                    guard !engine.remotePeerCameraOff, session.isCameraEnabled else { return }
                    CuvenHaptics.selectionChanged()
                    withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
                        engine.toggleSwappedStage()
                    }
                }
                .accessibilityIdentifier("call.selfPreviewTile")
                .accessibilityLabel("Swap camera stage")
                .accessibilityAddTraits(.isButton)
        }
        .frame(width: stageSize.width, height: stageSize.height, alignment: .topLeading)
    }

    private func selfPreviewTileView(width: CGFloat, height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return ZStack {
            if engine.isSwappedVideoStage {
                SimulatedStudioVideoStage(
                    displayName: session.peerDisplay,
                    avatarURL: session.peerAvatarURL,
                    isCompactTile: true,
                    accentWarm: false,
                    reduceMotion: reduceMotion,
                    audioLevel: engine.remoteAudioLevel
                )
            } else {
                LocalCameraPreviewView(
                    userName: currentUserName,
                    avatarURL: currentUserAvatarURL,
                    isCameraEnabled: session.isCameraEnabled,
                    useFrontCamera: engine.usingFrontCamera,
                    isCompactTile: true
                )
            }
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(.white.opacity(0.20), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.50), radius: 16, x: 0, y: 10)
    }

    // MARK: - 1:1 Pull-Down-to-Minimize Spring Gesture (`call.js:978-1043`)

    private func pullDownMinimizeGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .local)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                if !isPullingToMinimize {
                    // Activate only on predominantly downward vertical swipes (`dy > abs(dx) * 1.15`)
                    guard dy > 12, dy > abs(dx) * 1.15 else { return }
                    isPullingToMinimize = true
                    pullVelocityTracker.reset()
                }
                pullVelocityTracker.addSample(value.location)
                let dampedY = dy < 0
                    ? CuvenSprings.rubberBand(overshoot: dy, dimension: max(1, size.height))
                    : dy
                pullDownOffset = CGSize(width: dx * 0.45, height: dampedY)
            }
            .onEnded { value in
                guard isPullingToMinimize else { return }
                pullVelocityTracker.addSample(value.location)
                let v = pullVelocityTracker.velocity()
                let projectedY = value.translation.height + VelocityProjector.project(velocity: v.y)
                let shouldMinimize = v.y > -300 && (projectedY > max(140, size.height * 0.24) || v.y > 680)

                if shouldMinimize {
                    CuvenHaptics.softImpact()
                    withAnimation(CuvenSprings.adaptive(CuvenSprings.pipSnap, reduceMotion: reduceMotion)) {
                        isPullingToMinimize = false
                        pullDownOffset = .zero
                        onMinimize()
                    }
                } else {
                    withAnimation(CuvenSprings.adaptive(CuvenSprings.sheetPresent, reduceMotion: reduceMotion)) {
                        isPullingToMinimize = false
                        pullDownOffset = .zero
                    }
                }
            }
    }
}

import SwiftUI
import CuvenCore

// MARK: - Apple HIG & Cuven Web Grounding
// - Apple HIG: Designing for iPhone Duo (Postures: duoHalfLaptop controls below fold, duoOpen clearing 84pt rail)
// - Apple HIG: Materials -> Liquid Glass (floating Accept / Decline pills over atmospheric backdrop)
// - Cuven Web Parity: public/js/views/call.js (1309-1337), public/css/call.css (64-194), public/css/posture.css (31-39)

/// Posture-adaptive Incoming Call Liquid Glass Screen / Split Overlay (`Accept` / `Decline`),
/// supporting `iPhoneCompact`, `duoClosed`, `duoHalfBook`, `duoHalfLaptop` (tabletop split), and `duoOpen`.
public struct IncomingCallOverlayView: View {
    public let session: CallSession
    public let metrics: DuoLayoutMetrics
    public let backdropPreset: BackdropPreset
    public let glassMode: GlassAppearanceMode
    public let morphNamespace: Namespace.ID
    public let onAccept: () -> Void
    public let onDecline: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseExpanded = false

    public init(
        session: CallSession,
        metrics: DuoLayoutMetrics,
        backdropPreset: BackdropPreset,
        glassMode: GlassAppearanceMode,
        morphNamespace: Namespace.ID,
        onAccept: @escaping () -> Void,
        onDecline: @escaping () -> Void
    ) {
        self.session = session
        self.metrics = metrics
        self.backdropPreset = backdropPreset
        self.glassMode = glassMode
        self.morphNamespace = morphNamespace
        self.onAccept = onAccept
        self.onDecline = onDecline
    }

    private var rightRailClearance: CGFloat {
        guard metrics.hasRightSystemColumn else { return metrics.safeAreaRight }
        return max(metrics.safeAreaRight, metrics.railCenterFromRight + metrics.railWidth * 0.5 + 8)
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                CuvenBackdropView(preset: backdropPreset, customImageURL: nil)
                    .ignoresSafeArea()

                LinearGradient(
                    colors: [
                        .black.opacity(0.46),
                        .black.opacity(0.62),
                        .black.opacity(0.84)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                if metrics.posture == .duoHalfLaptop {
                    laptopIncomingLayout(size: proxy.size)
                } else {
                    standardIncomingLayout(size: proxy.size)
                }
            }
            .matchedGeometryEffect(id: "call.surface.\(session.id)", in: morphNamespace)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("call.incomingOverlay")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.35).repeatForever(autoreverses: true)) {
                pulseExpanded = true
            }
        }
    }

    // MARK: - Standard / Closed / Open / Book Layout

    private func standardIncomingLayout(size: CGSize) -> some View {
        let topInset = max(metrics.safeAreaTop + 28, metrics.posture == .duoClosed ? metrics.railTopReserve * 0.45 : metrics.safeAreaTop + 36)
        return VStack(spacing: 0) {
            Spacer(minLength: topInset)

            callerIdentityStage(avatarSize: 112)

            Spacer()

            incomingActionRow(largeTabletopStyle: false)
                .padding(.bottom, max(metrics.safeAreaBottom + 36, 48))
        }
        .padding(.leading, metrics.safeAreaLeft + 24)
        .padding(.trailing, rightRailClearance + 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - iPhone Duo Laptop / Tabletop Split (`posture.css:31-39`)

    private func laptopIncomingLayout(size: CGSize) -> some View {
        let hingeRect = metrics.hingeDivisionRect ?? CGRect(
            x: 0,
            y: floor((size.height - 28) * 0.5),
            width: size.width,
            height: 28
        )
        let topHeight = max(160, hingeRect.minY)
        let bottomHeight = max(160, size.height - hingeRect.maxY)

        return VStack(spacing: 0) {
            // Top display half above hinge: Caller portrait & animated ring
            ZStack(alignment: .bottom) {
                callerIdentityStage(avatarSize: 96)
                    .padding(.top, max(metrics.safeAreaTop, 16))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                LinearGradient(
                    colors: [.clear, .black.opacity(0.65)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 36)
                .allowsHitTesting(false)
            }
            .frame(height: topHeight)

            // Hinge fold exclusion zone (`ReservedRegion.Kind.division`)
            Rectangle()
                .fill(.black.opacity(0.45))
                .overlay {
                    Rectangle()
                        .fill(.white.opacity(0.08))
                        .frame(height: 1)
                }
                .frame(height: hingeRect.height)

            // Bottom flat tabletop half: Large ergonomic Liquid Glass Accept / Decline deck
            VStack(spacing: 20) {
                Text("Tabletop Call Controls")
                    .font(CuvenFonts.cappedCaption(weight: .semibold))
                    .foregroundStyle(.white.opacity(0.54))
                    .textCase(.uppercase)

                incomingActionRow(largeTabletopStyle: true)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, max(metrics.safeAreaBottom, 18))
            .frame(maxWidth: .infinity)
            .frame(height: bottomHeight)
        }
        .padding(.trailing, rightRailClearance)
    }

    // MARK: - Shared Caller Stage & Liquid Glass Controls

    private func callerIdentityStage(avatarSize: CGFloat) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .strokeBorder(.white.opacity(pulseExpanded ? 0.06 : 0.22), lineWidth: 2)
                    .frame(width: avatarSize + 44, height: avatarSize + 44)
                    .scaleEffect(pulseExpanded ? 1.16 : 0.96)

                Circle()
                    .strokeBorder(CuvenColors.onlineGreen.opacity(pulseExpanded ? 0.36 : 0.16), lineWidth: 2)
                    .frame(width: avatarSize + 22, height: avatarSize + 22)
                    .scaleEffect(pulseExpanded ? 1.07 : 0.98)

                CuvenAvatarView(
                    name: session.peerDisplay,
                    urlString: session.peerAvatarURL,
                    size: avatarSize,
                    isOnline: true
                )
                .overlay {
                    Circle()
                        .strokeBorder(.white.opacity(0.24), lineWidth: 1.5)
                }
                .shadow(color: .black.opacity(0.42), radius: 22, x: 0, y: 12)
            }

            VStack(spacing: 6) {
                Text(session.peerDisplay)
                    .font(CuvenFonts.clarinettaDisplay(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Image(systemName: session.mediaKind == .video ? "video.fill" : "phone.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CuvenColors.onlineGreen)
                    Text(session.mediaKind == .video ? "Video call invitation" : "Voice call invitation")
                        .font(CuvenFonts.cappedSubheadline(weight: .medium))
                        .foregroundStyle(.white.opacity(0.76))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .cuvenLiquidGlass(mode: glassMode, cornerRadius: 18)
            }
        }
    }

    private func incomingActionRow(largeTabletopStyle: Bool) -> some View {
        let buttonDiameter: CGFloat = largeTabletopStyle ? 72 : 66
        return HStack(spacing: largeTabletopStyle ? 56 : 64) {
            // Decline Button (`call.decline`)
            Button {
                CuvenHaptics.rigidImpact()
                onDecline()
            } label: {
                VStack(spacing: 9) {
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
                            .frame(width: buttonDiameter, height: buttonDiameter)
                            .overlay {
                                Circle()
                                    .strokeBorder(.white.opacity(0.28), lineWidth: 0.75)
                            }
                            .shadow(color: CuvenColors.dangerRed.opacity(0.44), radius: 16, x: 0, y: 8)

                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    Text("Decline")
                        .font(CuvenFonts.cappedFootnote(weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("call.decline")
            .accessibilityLabel("Decline")

            // Accept Button (`call.accept`) with repeating bounce symbol effect (`call.js:1336`)
            Button {
                CuvenHaptics.success()
                onAccept()
            } label: {
                VStack(spacing: 9) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.22, green: 0.86, blue: 0.44),
                                        CuvenColors.onlineGreen
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: buttonDiameter, height: buttonDiameter)
                            .overlay {
                                Circle()
                                    .strokeBorder(.white.opacity(0.32), lineWidth: 0.75)
                            }
                            .shadow(color: CuvenColors.onlineGreen.opacity(0.46), radius: 18, x: 0, y: 8)

                        Image(systemName: session.mediaKind == .video ? "video.fill" : "phone.fill")
                            .font(.system(size: 25, weight: .bold))
                            .foregroundStyle(.white)
                            .symbolEffect(.bounce, options: reduceMotion ? .nonRepeating : .repeating, value: pulseExpanded)
                    }
                    Text("Accept")
                        .font(CuvenFonts.cappedFootnote(weight: .semibold))
                        .foregroundStyle(.white.opacity(0.94))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("call.accept")
            .accessibilityLabel("Accept")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .cuvenLiquidGlass(mode: glassMode, cornerRadius: 42, interactiveBounce: true)
    }
}

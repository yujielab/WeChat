import SwiftUI
import CuvenCore

// MARK: - Fullscreen Hero Media Lightbox View (M10 — `PROJECT.md § 5.4`)
//
// Apple HIG & Developer Documentation Grounding:
// - Apple HIG › Gestures › Standard Gestures (Pinch to zoom `1x...4x`, Double-tap zoom `1x <-> 2.5x`,
//   1:1 vertical drag-to-dismiss with interactive backdrop alpha fade and velocity-projected spring return).
// - Apple HIG › Designing for iPhone Duo: Respects asymmetric right safe-area column (`safeRight >= 64pt`)
//   for top/bottom floating Liquid Glass controls, and adapts smoothly across compact, split, and tabletop poses.
// - Cuven Web Parity: `public/js/views/viewer.js:380-541` (`clampRest`, `zoomAt`, `project(v.y)` > `0.22 * H`).

public struct FullscreenMediaLightboxView: View {
    public let mediaURLs: [String]
    public let initialIndex: Int
    public let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var currentIndex: Int
    @State private var zoomScale: CGFloat = 1.0
    @State private var livePinchMultiplier: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var dragStartPanOffset: CGSize = .zero
    @State private var dismissDragOffset: CGSize = .zero
    @State private var backdropAlpha: Double = 1.0
    @State private var isChromeHidden: Bool = false
    @State private var isDismissing: Bool = false

    public init(mediaURLs: [String], initialIndex: Int, onDismiss: @escaping () -> Void) {
        let sanitized = mediaURLs.isEmpty ? ["demo://memories/placeholder"] : mediaURLs
        self.mediaURLs = sanitized
        let clamped = min(max(0, initialIndex), sanitized.count - 1)
        self.initialIndex = clamped
        self._currentIndex = State(initialValue: clamped)
        self.onDismiss = onDismiss
    }

    private var effectiveScale: CGFloat {
        zoomScale * livePinchMultiplier
    }

    public var body: some View {
        GeometryReader { proxy in
            let stageSize = proxy.size
            let dismissShrink: CGFloat = zoomScale <= 1.01
                ? max(0.70, 1.0 - min(0.30, abs(dismissDragOffset.height) / max(1, stageSize.height) * 0.58))
                : 1.0

            ZStack {
                // Interactive backdrop fading 1:1 with vertical drag-to-dismiss (`viewer.js:487`)
                Color.black
                    .opacity(backdropAlpha)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isChromeHidden.toggle()
                        }
                    }

                // Media stage
                ZStack {
                    if mediaURLs.indices.contains(currentIndex) {
                        let activeURL = mediaURLs[currentIndex]
                        let isDrawingAsset = activeURL.localizedCaseInsensitiveContains("draw")
                            || activeURL.hasPrefix("data:image/png")

                        CuvenMediaAssetView(
                            urlString: activeURL,
                            isDrawing: isDrawingAsset,
                            contentMode: .fit
                        )
                        .frame(maxWidth: stageSize.width, maxHeight: stageSize.height)
                        .clipShape(RoundedRectangle(cornerRadius: dismissDragOffset == .zero ? 0 : 18, style: .continuous))
                        .scaleEffect(effectiveScale * dismissShrink)
                        .offset(
                            x: panOffset.width + dismissDragOffset.width,
                            y: panOffset.height + dismissDragOffset.height
                        )
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            handleDoubleTapZoom()
                        }
                        .onTapGesture(count: 1) {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                isChromeHidden.toggle()
                            }
                        }
                        .gesture(pinchMagnificationGesture(in: stageSize))
                        .simultaneousGesture(panOrDismissDragGesture(in: stageSize))
                        .id(currentIndex)
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Top & bottom Liquid Glass chrome (`viewer.js:30-95`)
                if !isChromeHidden {
                    VStack(spacing: 0) {
                        topControlBar(safeTop: proxy.safeAreaInsets.top, safeRight: proxy.safeAreaInsets.trailing)
                        Spacer(minLength: 0)
                        bottomControlDock(safeBottom: proxy.safeAreaInsets.bottom, safeRight: proxy.safeAreaInsets.trailing)
                    }
                    .opacity(max(0, min(1, backdropAlpha)))
                    .transition(.opacity)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lightbox.root")
    }

    // MARK: - Chrome Bars

    private func topControlBar(safeTop: CGFloat, safeRight: CGFloat) -> some View {
        HStack(spacing: 12) {
            Button {
                CuvenHaptics.lightTap()
                triggerDismissAnimation(velocityY: 0, viewportHeight: 800)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.16), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.24), lineWidth: 0.6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close viewer")
            .accessibilityIdentifier("lightbox.closeButton")

            Spacer(minLength: 8)

            if mediaURLs.count > 1 {
                Text("\(currentIndex + 1) / \(mediaURLs.count)")
                    .font(CuvenFonts.cappedSubheadline(weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.45), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                    .accessibilityLabel("Item \(currentIndex + 1) of \(mediaURLs.count)")
            }

            Spacer(minLength: 8)

            if zoomScale > 1.02 {
                Button {
                    CuvenHaptics.selectionChanged()
                    resetZoomToRest()
                } label: {
                    Text("\(String(format: "%.1f", effectiveScale))×")
                        .font(CuvenFonts.cappedCaption(weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(minWidth: 44, minHeight: 44)
                        .padding(.horizontal, 8)
                        .background(Color.white.opacity(0.18), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reset zoom")
            } else if let shareURL = URL(string: mediaURLs[currentIndex]) {
                ShareLink(item: shareURL) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.16), in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.24), lineWidth: 0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share media")
            }
        }
        .padding(.top, max(12, safeTop + 6))
        .padding(.leading, 16)
        .padding(.trailing, max(16, safeRight + 12))
    }

    private func bottomControlDock(safeBottom: CGFloat, safeRight: CGFloat) -> some View {
        VStack(spacing: 12) {
            if mediaURLs.count > 1 {
                HStack(spacing: 16) {
                    Button {
                        navigateGallery(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(currentIndex > 0 ? 1.0 : 0.35))
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(currentIndex == 0)
                    .accessibilityLabel("Previous photo")

                    HStack(spacing: 6) {
                        ForEach(Array(mediaURLs.indices.prefix(12)), id: \.self) { idx in
                            Capsule()
                                .fill(idx == currentIndex ? Color.white : Color.white.opacity(0.35))
                                .frame(width: idx == currentIndex ? 18 : 6, height: 6)
                                .animation(CuvenSprings.adaptive(CuvenSprings.pressBounce, reduceMotion: reduceMotion), value: currentIndex)
                                .onTapGesture {
                                    selectSlide(idx)
                                }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.38), in: Capsule())

                    Button {
                        navigateGallery(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(currentIndex < mediaURLs.count - 1 ? 1.0 : 0.35))
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(currentIndex >= mediaURLs.count - 1)
                    .accessibilityLabel("Next photo")
                }
            }
        }
        .padding(.bottom, max(18, safeBottom + 10))
        .padding(.leading, 16)
        .padding(.trailing, max(16, safeRight + 12))
    }

    // MARK: - Gestures (`1x...4x` Pinch, Double-Tap Zoom, 1:1 Drag-to-Dismiss)

    private func pinchMagnificationGesture(in stageSize: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard !isDismissing else { return }
                let raw = zoomScale * value.magnification
                // Allow gentle rubberband outside 1x...4x while pinching (`viewer.js:452`)
                if raw < 1.0 {
                    livePinchMultiplier = max(0.72, raw) / max(0.01, zoomScale)
                } else if raw > 4.0 {
                    let over = raw - 4.0
                    let damped = 4.0 + CuvenSprings.rubberBand(overshoot: over, dimension: 4.0)
                    livePinchMultiplier = damped / max(0.01, zoomScale)
                } else {
                    livePinchMultiplier = value.magnification
                }
            }
            .onEnded { value in
                let proposed = zoomScale * value.magnification
                let clamped = min(4.0, max(1.0, proposed))
                withAnimation(CuvenSprings.adaptive(CuvenSprings.sheetPresent, reduceMotion: reduceMotion)) {
                    zoomScale = clamped
                    livePinchMultiplier = 1.0
                    if clamped <= 1.01 {
                        panOffset = .zero
                        dragStartPanOffset = .zero
                    } else {
                        panOffset = clampedPanOffset(panOffset, scale: clamped, stageSize: stageSize)
                        dragStartPanOffset = panOffset
                    }
                }
                CuvenHaptics.selectionChanged()
            }
    }

    private func panOrDismissDragGesture(in stageSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !isDismissing else { return }
                let tx = value.translation.width
                let ty = value.translation.height

                if zoomScale > 1.02 {
                    // 2D panning inside zoomed photo with rubberband at edges (`viewer.js:467-478`)
                    let candidate = CGSize(
                        width: dragStartPanOffset.width + tx,
                        height: dragStartPanOffset.height + ty
                    )
                    let maxX = max(0, (stageSize.width * zoomScale - stageSize.width) * 0.5)
                    let maxY = max(0, (stageSize.height * zoomScale - stageSize.height) * 0.5)
                    panOffset = CGSize(
                        width: CuvenSprings.clampWithRubberBand(value: candidate.width, min: -maxX, max: maxX, dimension: stageSize.width),
                        height: CuvenSprings.clampWithRubberBand(value: candidate.height, min: -maxY, max: maxY, dimension: stageSize.height)
                    )
                } else if mediaURLs.count > 1 && abs(tx) > abs(ty) * 1.35 && abs(dismissDragOffset.height) < 12 {
                    // Horizontal rubberband preview before gallery snap
                    dismissDragOffset = CGSize(
                        width: CuvenSprings.rubberBand(overshoot: tx, dimension: stageSize.width),
                        height: 0
                    )
                } else {
                    // Interactive 1:1 vertical drag-to-dismiss with backdrop alpha fade (`viewer.js:482-490`)
                    dismissDragOffset = value.translation
                    let fadeDenominator = max(160, stageSize.height * 0.50)
                    backdropAlpha = Double(max(0.0, 1.0 - abs(ty) / fadeDenominator))
                }
            }
            .onEnded { value in
                guard !isDismissing else { return }
                let tx = value.translation.width
                let ty = value.translation.height
                let vx = value.velocity.width
                let vy = value.velocity.height

                if zoomScale > 1.02 {
                    withAnimation(CuvenSprings.adaptive(CuvenSprings.sheetPresent, reduceMotion: reduceMotion)) {
                        panOffset = clampedPanOffset(panOffset, scale: zoomScale, stageSize: stageSize)
                        dragStartPanOffset = panOffset
                    }
                    return
                }

                // Check horizontal gallery swipe
                if abs(dismissDragOffset.height) < 14 && mediaURLs.count > 1 && (abs(tx) > 48 || abs(vx) > 520) {
                    let direction = tx < 0 ? 1 : -1
                    let target = currentIndex + direction
                    if mediaURLs.indices.contains(target) {
                        dismissDragOffset = .zero
                        backdropAlpha = 1.0
                        selectSlide(target)
                        return
                    }
                }

                // Velocity-projected vertical dismiss threshold (`viewer.js:529`: `abs(dy + project(v.y)) > H * 0.22 || abs(v.y) > 900`)
                let projectedY = ty + CuvenVelocityProjector.project(velocity: vy, decelerationRate: CuvenVelocityProjector.normalDecelerationRate)
                if abs(projectedY) > max(110, stageSize.height * 0.22) || abs(vy) > 900 {
                    triggerDismissAnimation(velocityY: vy, viewportHeight: stageSize.height)
                } else {
                    // Spring snap-back to rest
                    withAnimation(CuvenSprings.adaptive(CuvenSprings.sheetPresent, reduceMotion: reduceMotion)) {
                        dismissDragOffset = .zero
                        backdropAlpha = 1.0
                    }
                }
            }
    }

    private func handleDoubleTapZoom() {
        CuvenHaptics.lightTap()
        withAnimation(CuvenSprings.adaptive(CuvenSprings.sheetPresent, reduceMotion: reduceMotion)) {
            if zoomScale > 1.05 {
                zoomScale = 1.0
                livePinchMultiplier = 1.0
                panOffset = .zero
                dragStartPanOffset = .zero
            } else {
                zoomScale = 2.5
                livePinchMultiplier = 1.0
            }
        }
    }

    private func resetZoomToRest() {
        withAnimation(CuvenSprings.adaptive(CuvenSprings.sheetPresent, reduceMotion: reduceMotion)) {
            zoomScale = 1.0
            livePinchMultiplier = 1.0
            panOffset = .zero
            dragStartPanOffset = .zero
        }
    }

    private func navigateGallery(by delta: Int) {
        selectSlide(currentIndex + delta)
    }

    private func selectSlide(_ nextIndex: Int) {
        guard mediaURLs.indices.contains(nextIndex), nextIndex != currentIndex else { return }
        CuvenHaptics.selectionChanged()
        withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
            currentIndex = nextIndex
            zoomScale = 1.0
            livePinchMultiplier = 1.0
            panOffset = .zero
            dragStartPanOffset = .zero
            dismissDragOffset = .zero
            backdropAlpha = 1.0
        }
    }

    private func clampedPanOffset(_ raw: CGSize, scale: CGFloat, stageSize: CGSize) -> CGSize {
        let maxX = max(0, (stageSize.width * scale - stageSize.width) * 0.5)
        let maxY = max(0, (stageSize.height * scale - stageSize.height) * 0.5)
        return CGSize(
            width: min(maxX, max(-maxX, raw.width)),
            height: min(maxY, max(-maxY, raw.height))
        )
    }

    private func triggerDismissAnimation(velocityY: CGFloat, viewportHeight: CGFloat) {
        guard !isDismissing else { return }
        isDismissing = true
        if reduceMotion {
            onDismiss()
            return
        }
        let direction: CGFloat = (dismissDragOffset.height == 0 ? (velocityY >= 0 ? 1 : -1) : (dismissDragOffset.height >= 0 ? 1 : -1))
        withAnimation(.easeOut(duration: 0.18)) {
            dismissDragOffset.height += direction * max(120, viewportHeight * 0.28)
            backdropAlpha = 0.0
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            onDismiss()
        }
    }
}

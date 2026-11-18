import SwiftUI
import CuvenCore

// MARK: - Monthly Recap Flashback Cinema Player (M10 — `PROJECT.md § 4, § 5.5`)
//
// Grounded in `public/js/views/memories.js:137-150`, Apple HIG › Motion & Accessibility,
// and `CuvenTier1FeatureUITests.testF7_06` / `CuvenTier4RealWorldScenariosUITests.testS4`:
// - Segmented top story progress bars advancing every `3.8s` (with Pause/Play control and
//   tap-left / tap-right slide navigation).
// - Respects `accessibilityReduceMotion` (suppresses subtle Ken Burns zoom drift and uses
//   clean opacity cross-fades).
// - Interactive 1:1 vertical drag-to-dismiss backed by `CuvenVelocityProjector.project(...)`.
// - Insets top-right controls clear of iPhone Duo's `84pt`/`91pt` right system column (`rightRailClearance`).

public struct MemoriesFlashbackSlideshowView: View {
    public let title: String
    public let subtitle: String
    public let items: [MemoryItem]
    public let serverBaseURL: URL
    public let rightRailClearance: CGFloat
    public let leftSafeInset: CGFloat
    public let topSafeInset: CGFloat
    public let bottomSafeInset: CGFloat
    public let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var currentIndex: Int = 0
    @State private var slideProgress: CGFloat = 0.0
    @State private var isPaused: Bool = false
    @State private var isHoldingPause: Bool = false
    @State private var verticalDragOffset: CGFloat = 0.0
    @State private var isDraggingDismiss: Bool = false
    @State private var velocityTracker = CuvenGestureVelocityTracker()

    private static let slideDurationSeconds: Double = 3.8

    public init(
        title: String,
        subtitle: String,
        items: [MemoryItem],
        serverBaseURL: URL,
        rightRailClearance: CGFloat = 16,
        leftSafeInset: CGFloat = 16,
        topSafeInset: CGFloat = 16,
        bottomSafeInset: CGFloat = 16,
        onDismiss: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.items = items
        self.serverBaseURL = serverBaseURL
        self.rightRailClearance = rightRailClearance
        self.leftSafeInset = leftSafeInset
        self.topSafeInset = topSafeInset
        self.bottomSafeInset = bottomSafeInset
        self.onDismiss = onDismiss
    }

    private var safeIndex: Int {
        guard !items.isEmpty else { return 0 }
        return min(max(0, currentIndex), items.count - 1)
    }

    private var currentSlide: MemoryItem? {
        guard !items.isEmpty else { return nil }
        return items[safeIndex]
    }

    private var backdropAlpha: Double {
        let progress = min(1.0, Double(abs(verticalDragOffset)) / 320.0)
        return max(0.25, 1.0 - progress * 0.72)
    }

    private var cardDragScale: CGFloat {
        guard !reduceMotion else { return 1.0 }
        let progress = min(1.0, abs(verticalDragOffset) / 420.0)
        return 1.0 - progress * 0.12
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                    .opacity(backdropAlpha)
                    .ignoresSafeArea()

                if let slide = currentSlide {
                    ZStack {
                        // Ambient blurred glow behind slide
                        CuvenMediaAssetView(
                            urlString: slide.mediaURL,
                            isDrawing: slide.kind == .drawing,
                            contentMode: .fill,
                            serverBaseURL: serverBaseURL
                        )
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: 36)
                        .opacity(0.38)
                        .clipped()

                        // Hero media stage with subtle Ken Burns motion (disabled under Reduce Motion)
                        CuvenMediaAssetView(
                            urlString: slide.mediaURL,
                            isDrawing: slide.kind == .drawing,
                            contentMode: .fit,
                            serverBaseURL: serverBaseURL
                        )
                        .scaleEffect(reduceMotion ? 1.0 : (1.0 + slideProgress * 0.045))
                        .frame(
                            maxWidth: max(200, geo.size.width - leftSafeInset - rightRailClearance),
                            maxHeight: max(220, geo.size.height * 0.72)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: .black.opacity(0.48), radius: 24, y: 10)
                        .padding(.leading, leftSafeInset)
                        .padding(.trailing, rightRailClearance)
                        .id(slide.id)
                        .transition(.opacity)

                        // Invisible Left/Right Tap & Hold-to-Pause Regions
                        HStack(spacing: 0) {
                            Color.clear
                                .contentShape(Rectangle())
                                .frame(width: geo.size.width * 0.34)
                                .onTapGesture {
                                    stepBackward()
                                }
                                .onLongPressGesture(
                                    minimumDuration: 60.0,
                                    maximumDistance: 28,
                                    pressing: { pressing in isHoldingPause = pressing },
                                    perform: {}
                                )
                                .accessibilityLabel("Previous memory")
                                .accessibilityAddTraits(.isButton)

                            Color.clear
                                .contentShape(Rectangle())
                                .frame(maxWidth: .infinity)
                                .onTapGesture {
                                    stepForward()
                                }
                                .onLongPressGesture(
                                    minimumDuration: 60.0,
                                    maximumDistance: 28,
                                    pressing: { pressing in isHoldingPause = pressing },
                                    perform: {}
                                )
                                .accessibilityLabel("Next memory")
                                .accessibilityAddTraits(.isButton)
                        }
                        .padding(.vertical, 96)
                    }
                    .offset(y: verticalDragOffset)
                    .scaleEffect(cardDragScale)
                }

                // Top Story Progress Bars & Header Controls
                VStack(spacing: 12) {
                    segmentedProgressHeader
                    topControlRow
                    Spacer()
                    if let slide = currentSlide {
                        bottomCaptionFooter(for: slide)
                    }
                }
                .padding(.top, max(14, topSafeInset + 6))
                .padding(.bottom, max(20, bottomSafeInset + 10))
                .padding(.leading, max(16, leftSafeInset))
                .padding(.trailing, max(16, rightRailClearance))
                .opacity(isDraggingDismiss ? 0.35 : 1.0)
            }
            .gesture(verticalDismissDragGesture)
        }
        .task(id: "\(safeIndex)_\(isPaused)") {
            await runAutoAdvanceTimer()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memories.flashbackPlayer")
    }

    // MARK: - Segmented Story Progress Bars

    private var segmentedProgressHeader: some View {
        HStack(spacing: 4) {
            ForEach(0..<max(1, items.count), id: \.self) { index in
                GeometryReader { barGeo in
                    let fillFraction: CGFloat = {
                        if index < safeIndex { return 1.0 }
                        if index > safeIndex { return 0.0 }
                        return min(max(slideProgress, 0.0), 1.0)
                    }()

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.28))
                        Capsule()
                            .fill(Color.white)
                            .frame(width: barGeo.size.width * fillFraction)
                    }
                }
                .frame(height: 3)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Top Control Row (`Play/Pause` + Title + `Close`)

    private var topControlRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(CuvenFonts.cappedHeadline(weight: .bold))
                    .foregroundStyle(.white)
                Text("\(safeIndex + 1) of \(max(1, items.count)) · \(subtitle)")
                    .font(CuvenFonts.cappedCaption())
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.76))
            }

            Spacer()

            Button {
                CuvenHaptics.selectionChanged()
                isPaused.toggle()
            } label: {
                Image(systemName: (isPaused || isHoldingPause) ? "play.fill" : "pause.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel((isPaused || isHoldingPause) ? "Resume slideshow" : "Pause slideshow")
            .accessibilityIdentifier("memories.slideshowPauseToggle")

            Button {
                CuvenHaptics.lightTap()
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("memories.slideshowClose")
        }
        .cuvenCappedDynamicType()
    }

    // MARK: - Bottom Caption & Room Origin Badge

    private func bottomCaptionFooter(for slide: MemoryItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: slide.kind == .drawing ? "paintbrush.pointed.fill" : (slide.kind == .video ? "video.fill" : "photo.fill"))
                    .font(.system(size: 11, weight: .semibold))
                Text("Shared in \(slide.roomTitle) · \(formattedDateString(from: slide.createdAt))")
                    .font(CuvenFonts.cappedCaption(weight: .semibold))
            }
            .foregroundStyle(Color.white.opacity(0.88))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())

            if !slide.caption.isEmpty {
                Text(slide.caption)
                    .font(CuvenFonts.clarinettaDisplay(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Navigation & Auto-Advance Timer

    private func stepBackward() {
        CuvenHaptics.selectionChanged()
        withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
            if safeIndex > 0 {
                currentIndex = safeIndex - 1
            } else {
                currentIndex = 0
            }
            slideProgress = 0
        }
    }

    private func stepForward() {
        CuvenHaptics.selectionChanged()
        if safeIndex + 1 < items.count {
            withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
                currentIndex = safeIndex + 1
                slideProgress = 0
            }
        } else {
            onDismiss()
        }
    }

    @MainActor
    private func runAutoAdvanceTimer() async {
        guard !isPaused, !items.isEmpty else { return }
        let tickSeconds: Double = 0.05
        let increment = CGFloat(tickSeconds / Self.slideDurationSeconds)

        while !Task.isCancelled && !isPaused {
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, !isPaused, !isHoldingPause, !isDraggingDismiss else { continue }
            if slideProgress + increment >= 1.0 {
                slideProgress = 1.0
                if safeIndex + 1 < items.count {
                    withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
                        currentIndex = safeIndex + 1
                        slideProgress = 0.0
                    }
                } else {
                    // Loop back to start cleanly so open slideshow stays playable until user closes
                    withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
                        currentIndex = 0
                        slideProgress = 0.0
                    }
                }
                return
            } else {
                slideProgress += increment
            }
        }
    }

    // MARK: - Interactive Vertical Drag-to-Dismiss

    private var verticalDismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                if !isDraggingDismiss {
                    isDraggingDismiss = true
                    velocityTracker.reset()
                }
                velocityTracker.addSample(value.location)
                verticalDragOffset = value.translation.height
            }
            .onEnded { value in
                guard isDraggingDismiss else { return }
                isDraggingDismiss = false
                let trackedVy = velocityTracker.velocity().y
                let vy = abs(trackedVy) > 10 ? trackedVy : value.velocity.height
                let projectedY = verticalDragOffset + CuvenVelocityProjector.project(
                    velocity: vy,
                    decelerationRate: CuvenVelocityProjector.fastDecelerationRate
                )
                velocityTracker.reset()

                if abs(projectedY) > 140 || abs(vy) > 850 {
                    CuvenHaptics.lightTap()
                    onDismiss()
                } else {
                    withAnimation(CuvenSprings.adaptive(CuvenSprings.sheetPresent, reduceMotion: reduceMotion)) {
                        verticalDragOffset = 0
                    }
                }
            }
    }

    private func formattedDateString(from epoch: Int64) -> String {
        let seconds = epoch > 10_000_000_000 ? Double(epoch) / 1000.0 : Double(epoch)
        let date = Date(timeIntervalSince1970: seconds)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

//
//  StripContainerView.swift
//  Cuven
//
//  Apple HIG & iOS 27.1 SDK Grounding:
//  - Human Interface Guidelines › Designing for iPhone Duo › Dynamic layouts, Split views & Continuity
//    (2-column split `342 | 609` <-> `525 | 426` with constant `525pt` Conversation content width on `951×669`
//     Duo Open; `462 | 28..40pt hinge | 461` on `duoHalfBook`; tabletop split on `duoHalfLaptop`)
//  - Human Interface Guidelines › Gestures & Motion (40pt leading-edge 1:1 interactive swipe-back with
//    `VelocityProjector` `0.998` momentum projection, mid-flight spring catch, and stationary counter-translated
//    `Back` button with `0.0pt` screen drift)
//  - Cuven Web Parity: `public/js/ui/strip.js:1-380`, `public/js/ui/columns.js:1-90`,
//    `public/js/views/shell.js:20-475`, `public/css/duo-layout.css:74-185`
//

import CuvenCore
import SwiftUI

/// Persistent 4-column horizontal sliding strip (`0: Sidebar | 1: ChatList | 2: Thread | 3: Artifact`)
/// seen through a 1-column viewport when folded/compact or a 2-adjacent-column viewport when unfolded/split.
///
/// Key guarantees:
/// - **Zero-Reflow `525pt` Conversation Width**: On `951×669pt` `duoOpen`, sliding between `List | Thread`
///   (`342 | 609` where `609 = 525 content + 84 DuoRail`) and `Thread | Artifact` (`525 | 426` where
///   `426 = 342 details + 84 DuoRail`) keeps `Thread`'s usable content width identically `525.0pt` at every frame.
/// - **Stationary Pinned `Back` (`<= 1px` Drift)**: In 1-column stack transitions, every sliding column's
///   `Back` button is counter-translated by `-box.x` (`(p - columnIndex) * viewportWidth`) via SwiftUI's
///   `Animatable` pipeline so it remains physically pinned under the user's thumb (`0.0pt` mathematical drift).
/// - **Posture Fold/Unfold Continuity**: All four columns remain mounted in stable view slots so folding or
///   unfolding preserves scroll position, unsent composer drafts, and `DrawingBoardCanvasView` strokes;
///   unfolding from `Sidebar` (`0`) automatically advances to `List | Thread` (`1 | 2`).
public struct StripContainerView: View {
    private let store: AppStore
    public let metrics: DuoLayoutMetrics
    public let onPresentModal: (CuvenShellModalDestination) -> Void

    @Environment(\.cuvenHingeAngleDegrees) private var hingeAngleDegrees
    @Environment(\.cuvenKeyboardHeight) private var keyboardHeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Leading-edge touch zone width (`strip.js:83` `swipeZone = 40`).
    public static let leadingEdgeSwipeZone: CGFloat = 40

    // Continuous window start position (`0.0 ... 3.0` in 1-col, `0.0 ... 2.0` in 2-col)
    @State private var animatedWindowPosition: CGFloat = 1.0
    @State private var hasInitializedPosition: Bool = false
    @State private var lastVisibleColumnCount: Int = 1
    @State private var lastPosture: DuoPosture?

    // Analytical flight tracking for exact mid-flight gesture catch (`CuvenSpringSolver`)
    @State private var activeFlight: SpringFlightRecord?

    // Interactive 1:1 leading-edge swipe-back state
    @State private var isDraggingBack: Bool = false
    @State private var dragRejected: Bool = false
    @State private var dragOriginPosition: CGFloat = 1.0
    @State private var dragAnchorX: CGFloat = 0
    @State private var dragStepDistance: CGFloat = 393
    @State private var velocityTracker = CuvenGestureVelocityTracker()

    // Retained column context so closing `Thread` or `Artifact` animates smoothly off-screen without blanking
    @State private var retainedRoomID: String?
    @State private var retainedArtifactMode: ArtifactMode = .roomInfo

    private struct SpringFlightRecord: Equatable {
        let startTime: TimeInterval
        let from: Double
        let to: Double
        let initialVelocity: Double
    }

    public init(
        store: AppStore,
        metrics: DuoLayoutMetrics,
        onPresentModal: @escaping (CuvenShellModalDestination) -> Void
    ) {
        self.store = store
        self.metrics = metrics
        self.onPresentModal = onPresentModal
    }

    // MARK: - Canonical Strip Window Math (`strip.js:27-35`)

    /// Resolves the first visible column index for a given focused column (`0...3`) and visible column count (`1` or `2`).
    public static func windowStart(focus: Int, visibleCount: Int) -> Int {
        let clampedFocus = max(0, min(3, focus))
        if visibleCount <= 1 {
            return clampedFocus
        }
        return max(0, min(2, clampedFocus <= 1 ? clampedFocus : clampedFocus - 1))
    }

    /// Counter-translation offset keeping a 1-column `Back` button stationary on screen (`strip.js:117`).
    public static func stationaryBackOffset(
        for columnIndex: Int,
        boxX: CGFloat,
        visibleCount: Int,
        isColumnNearViewport: Bool
    ) -> CGFloat {
        guard visibleCount == 1, isColumnNearViewport else { return 0 }
        let offset = -boxX
        return abs(offset) < 0.01 ? 0 : offset
    }

    private var effectiveFocusColumn: Int {
        let raw = max(0, min(3, store.activeColumnIndex))
        if store.activeArtifactMode != nil && raw >= 2 {
            return 3
        }
        if store.activeArtifactMode == nil && raw == 3 {
            return 2
        }
        return raw
    }

    private var targetWindowStart: Int {
        Self.windowStart(focus: effectiveFocusColumn, visibleCount: metrics.visibleColumnCount)
    }

    private var resolvedThreadRoomID: String? {
        if let selected = store.selectedRoomID {
            return selected
        }
        if let retainedRoomID, store.rooms.contains(where: { $0.id == retainedRoomID && !$0.isHidden }) {
            if metrics.visibleColumnCount >= 2 || animatedWindowPosition > 1.01 {
                return retainedRoomID
            }
        }
        if metrics.visibleColumnCount >= 2 {
            return store.rooms.first(where: { !$0.isHidden })?.id
        }
        return nil
    }

    private var resolvedArtifactMode: ArtifactMode {
        store.activeArtifactMode ?? retainedArtifactMode
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            CuvenColors.paperBackground

            AnimatableStripStage(
                position: animatedWindowPosition,
                store: store,
                metrics: metrics,
                threadRoomID: resolvedThreadRoomID,
                artifactMode: resolvedArtifactMode,
                keyboardHeight: keyboardHeight,
                onNavigateColumn: { nextCol in
                    navigateToColumn(nextCol)
                },
                onBackFromThread: {
                    navigateBack(from: 2)
                },
                onCloseArtifact: {
                    closeArtifactColumn()
                },
                onPresentModal: onPresentModal
            )

            // Book-spine or Laptop-tabletop crease shadow & non-interactive hinge exclusion zone
            HingeBookCreaseOverlay(
                metrics: metrics,
                hingeAngleDegrees: hingeAngleDegrees
            )
        }
        .frame(
            width: metrics.viewportSize.width,
            height: metrics.viewportSize.height,
            alignment: .topLeading
        )
        .clipped()
        .coordinateSpace(name: "cuven.strip")
        .simultaneousGesture(leadingEdgeSwipeBackGesture)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shell.strip")
        .onAppear {
            initializeStripStateIfNeeded()
        }
        .onChange(of: store.selectedRoomID) { _, newRoomID in
            if let newRoomID {
                retainedRoomID = newRoomID
            }
        }
        .onChange(of: store.activeArtifactMode) { _, newMode in
            if let newMode {
                retainedArtifactMode = newMode
            }
            synchronizeToStoreTarget()
        }
        .onChange(of: store.activeColumnIndex) { _, _ in
            synchronizeToStoreTarget()
        }
        .onChange(of: metrics.visibleColumnCount) { oldCount, newCount in
            handleVisibleColumnCountChange(from: oldCount, to: newCount)
        }
        .onChange(of: metrics.posture) { oldPosture, newPosture in
            handlePostureTransition(from: oldPosture, to: newPosture)
        }
    }

    // MARK: - Lifecycle, Navigation & Posture Continuity (`shell.js:436-467`)

    private func initializeStripStateIfNeeded() {
        guard !hasInitializedPosition else { return }
        hasInitializedPosition = true
        lastVisibleColumnCount = metrics.visibleColumnCount
        lastPosture = metrics.posture
        if let selected = store.selectedRoomID {
            retainedRoomID = selected
        } else if metrics.visibleColumnCount >= 2,
                  let firstRoom = store.rooms.first(where: { !$0.isHidden }) {
            retainedRoomID = firstRoom.id
            store.selectRoom(firstRoom.id)
        }
        if let mode = store.activeArtifactMode {
            retainedArtifactMode = mode
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            animatedWindowPosition = CGFloat(targetWindowStart)
        }
    }

    private func synchronizeToStoreTarget(initialVelocity: Double = 0) {
        guard !isDraggingBack else { return }
        let destination = CGFloat(targetWindowStart)
        guard abs(animatedWindowPosition - destination) > 0.0005 else {
            activeFlight = nil
            return
        }

        if reduceMotion {
            activeFlight = nil
            withAnimation(CuvenSprings.reducedMotionFade) {
                animatedWindowPosition = destination
            }
            return
        }

        let startFrom = Double(currentInstantaneousPosition())
        activeFlight = SpringFlightRecord(
            startTime: ProcessInfo.processInfo.systemUptime,
            from: startFrom,
            to: Double(destination),
            initialVelocity: initialVelocity
        )
        let springAnim = Animation.interpolatingSpring(
            mass: 1.0,
            stiffness: pow((2.0 * .pi) / 0.34, 2),
            damping: (4.0 * .pi) / 0.34,
            initialVelocity: initialVelocity
        )
        withAnimation(springAnim) {
            animatedWindowPosition = destination
        }
    }

    private func handleVisibleColumnCountChange(from oldCount: Int, to newCount: Int) {
        lastVisibleColumnCount = newCount
        activeFlight = nil
        isDraggingBack = false

        // Unfolding (`1 -> 2` columns) while on `Sidebar` (`0`) advances directly to `List | Thread` (`1 | 2`),
        // matching `shell.js:443-446` & `DISPATCH.md` posture continuity rule.
        if oldCount == 1 && newCount >= 2 {
            if store.activeColumnIndex == 0 {
                store.activeColumnIndex = 1
            }
            if store.selectedRoomID == nil,
               let fallbackID = retainedRoomID ?? store.rooms.first(where: { !$0.isHidden })?.id {
                retainedRoomID = fallbackID
                store.selectRoom(fallbackID)
            }
        }

        let snappedTarget = CGFloat(Self.windowStart(focus: effectiveFocusColumn, visibleCount: newCount))
        if reduceMotion {
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) {
                animatedWindowPosition = snappedTarget
            }
        } else {
            withAnimation(CuvenSprings.railMorph) {
                animatedWindowPosition = snappedTarget
            }
        }
    }

    private func handlePostureTransition(from oldPosture: DuoPosture, to newPosture: DuoPosture) {
        lastPosture = newPosture
        if newPosture == .duoOpen || newPosture == .duoHalfBook || newPosture == .iPhoneSplit {
            if store.selectedRoomID == nil,
               let fallbackID = retainedRoomID ?? store.rooms.first(where: { !$0.isHidden })?.id {
                retainedRoomID = fallbackID
            }
        }
        let target = CGFloat(targetWindowStart)
        if abs(animatedWindowPosition - target) > 0.001 {
            withAnimation(CuvenSprings.adaptive(CuvenSprings.railMorph, reduceMotion: reduceMotion)) {
                animatedWindowPosition = target
            }
        }
    }

    public func navigateToColumn(_ column: Int, velocity: Double = 0) {
        let clamped = max(0, min(3, column))
        if clamped < 3 && store.activeArtifactMode != nil {
            store.closeArtifact()
        }
        if clamped == 2 && store.selectedRoomID == nil,
           let fallbackID = retainedRoomID ?? store.rooms.first(where: { !$0.isHidden })?.id {
            store.selectRoom(fallbackID)
        }
        store.activeColumnIndex = clamped
        synchronizeToStoreTarget(initialVelocity: velocity)
    }

    private func navigateBack(from column: Int, velocity: Double = 0) {
        if column >= 3 {
            closeArtifactColumn(velocity: velocity)
            return
        }
        let prev = max(0, column - 1)
        if store.activeArtifactMode != nil {
            store.closeArtifact()
        }
        store.activeColumnIndex = prev
        synchronizeToStoreTarget(initialVelocity: velocity)
    }

    private func closeArtifactColumn(velocity: Double = 0) {
        store.closeArtifact()
        if store.activeColumnIndex >= 3 {
            store.activeColumnIndex = 2
        }
        synchronizeToStoreTarget(initialVelocity: velocity)
    }

    // MARK: - Analytical Mid-Flight Position Sampling (`CuvenSpringSolver`)

    private func currentInstantaneousPosition() -> CGFloat {
        guard let flight = activeFlight else {
            return animatedWindowPosition
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - flight.startTime
        if elapsed >= 0.55 {
            return CGFloat(flight.to)
        }
        let sampled = CuvenSpringSolver.state(
            at: max(0, elapsed),
            from: flight.from,
            to: flight.to,
            velocity: flight.initialVelocity,
            damping: 1.0,
            response: 0.34
        )
        return CGFloat(sampled)
    }

    // MARK: - 40pt Leading-Edge 1:1 Interactive Swipe-Back (`strip.js:262-347`)

    private var leadingEdgeSwipeBackGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .named("cuven.strip"))
            .onChanged { value in
                if dragRejected { return }

                if !isDraggingBack {
                    let instantaneous = currentInstantaneousPosition()
                    let isMidFlight = activeFlight != nil && abs(instantaneous - CGFloat(targetWindowStart)) > 0.02

                    // Cannot swipe back past Column 0 (`Sidebar`)
                    guard instantaneous > 0.01 || targetWindowStart > 0 else {
                        dragRejected = true
                        return
                    }

                    // Protect `DrawingBoardCanvasView` strokes when active in split mode
                    if metrics.visibleColumnCount >= 2 && store.activeArtifactMode == .drawingBoard && value.startLocation.x > 20 {
                        dragRejected = true
                        return
                    }

                    let allowedEdgeMaxX = metrics.safeAreaLeft + Self.leadingEdgeSwipeZone + (isMidFlight ? 48 : 0)
                    guard value.startLocation.x <= allowedEdgeMaxX else {
                        dragRejected = true
                        return
                    }

                    let dx = value.translation.width
                    let dy = value.translation.height

                    // Reject predominantly vertical scroll gestures immediately (`strip.js:295`)
                    if abs(dy) > 10 && abs(dy) > abs(dx) {
                        dragRejected = true
                        return
                    }
                    guard dx >= 10 && dx >= abs(dy) * 1.2 else {
                        return
                    }

                    // Latch 1:1 interactive swipe-back (catching mid-flight spring seamlessly if moving!)
                    isDraggingBack = true
                    let caughtPos = isMidFlight ? instantaneous : CGFloat(targetWindowStart)
                    activeFlight = nil
                    dragOriginPosition = max(0.01, caughtPos)
                    dragAnchorX = value.location.x
                    dragStepDistance = computeStepDistance(fromWindowStart: Int(ceil(dragOriginPosition - 1e-4)))
                    velocityTracker.reset()
                    velocityTracker.addSample(value.location)
                    CuvenHaptics.prepareAll()

                    var freezeTx = Transaction()
                    freezeTx.disablesAnimations = true
                    withTransaction(freezeTx) {
                        animatedWindowPosition = caughtPos
                    }
                }

                velocityTracker.addSample(value.location)
                let fingerDeltaX = value.location.x - dragAnchorX
                let step = max(1, dragStepDistance)

                let nextPosition: CGFloat
                if fingerDeltaX >= 0 {
                    let normalized = fingerDeltaX / step
                    if normalized <= dragOriginPosition {
                        nextPosition = dragOriginPosition - normalized
                    } else {
                        let over = normalized - dragOriginPosition
                        nextPosition = -CuvenSprings.rubberBand(overshoot: over, dimension: 0.35, resistance: 0.30)
                    }
                } else {
                    let backOver = (-fingerDeltaX) / step
                    let maxPos = CGFloat(metrics.visibleColumnCount >= 2 ? 2 : 3)
                    let candidate = dragOriginPosition + CuvenSprings.rubberBand(overshoot: backOver, dimension: 0.35, resistance: 0.25)
                    nextPosition = min(maxPos + 0.12, candidate)
                }

                var dragTx = Transaction()
                dragTx.disablesAnimations = true
                withTransaction(dragTx) {
                    animatedWindowPosition = nextPosition
                }
            }
            .onEnded { value in
                defer {
                    dragRejected = false
                    velocityTracker.reset()
                }
                guard isDraggingBack else { return }
                isDraggingBack = false

                let trackedVx = velocityTracker.velocity().x
                let releaseVx = abs(trackedVx) > 10 ? trackedVx : value.velocity.width
                let step = max(1, dragStepDistance)
                let originStart = max(1, Int(ceil(dragOriginPosition - 1e-4)))
                let draggedPoints = max(0, (CGFloat(originStart) - animatedWindowPosition) * step)

                // Momentum projection using canonical `VelocityProjector` (`0.998` deceleration, `strip.js:332`)
                let projectedPoints = VelocityProjector.project(
                    velocity: releaseVx,
                    decelerationRate: VelocityProjector.normalDecelerationRate
                )
                let shouldCommitBack = (draggedPoints + projectedPoints) > (step * 0.50) || releaseVx > 900
                let normalizedVelocity = Double(-releaseVx / step)

                if shouldCommitBack {
                    CuvenHaptics.lightTap()
                    let previousWindowStart = max(0, originStart - 1)
                    if originStart == 2 && metrics.visibleColumnCount >= 2 {
                        // Swiping back from `Thread | Artifact` (`start = 2`) closes `Artifact` -> `List | Thread` (`start = 1`)
                        closeArtifactColumn(velocity: normalizedVelocity)
                    } else if metrics.visibleColumnCount == 1 {
                        navigateBack(from: originStart, velocity: normalizedVelocity)
                    } else {
                        navigateToColumn(previousWindowStart, velocity: normalizedVelocity)
                    }
                } else {
                    // Spring snap-back to resting window start (`CuvenSprings.stripSlide`, critically damped)
                    synchronizeToStoreTarget(initialVelocity: normalizedVelocity)
                }
            }
    }

    private func computeStepDistance(fromWindowStart start: Int) -> CGFloat {
        let width = max(1, metrics.viewportSize.width)
        let count = metrics.visibleColumnCount
        guard count >= 2 else { return width }

        let geoProvider = AnimatableStripStage.makeGeometryProvider(for: metrics)
        let clampedStart = max(1, min(2, start))
        let a = DuoColumnMath.boxes(
            at: clampedStart,
            columnCount: 4,
            viewportWidth: width,
            visibleCount: count,
            geometryProvider: geoProvider
        )
        let b = DuoColumnMath.boxes(
            at: clampedStart - 1,
            columnCount: 4,
            viewportWidth: width,
            visibleCount: count,
            geometryProvider: geoProvider
        )
        guard clampedStart < a.count, clampedStart < b.count else { return width }
        return max(1, abs(b[clampedStart].x - a[clampedStart].x))
    }
}

// MARK: - Animatable 4-Column Stage (`DuoColumnMath.boxesAtPosition` Frame-Synchronized Pipeline)

private struct AnimatableStripStage: View, @MainActor Animatable {
    var position: CGFloat
    let store: AppStore
    let metrics: DuoLayoutMetrics
    let threadRoomID: String?
    let artifactMode: ArtifactMode
    let keyboardHeight: CGFloat
    let onNavigateColumn: (Int) -> Void
    let onBackFromThread: () -> Void
    let onCloseArtifact: () -> Void
    let onPresentModal: (CuvenShellModalDestination) -> Void

    var animatableData: CGFloat {
        get { position }
        set { position = newValue }
    }

    static func makeGeometryProvider(for metrics: DuoLayoutMetrics) -> (Int) -> DuoWindowGeometry {
        let isHalfBook = (metrics.posture == .duoHalfBook)
        let hingeRange: Range<CGFloat>? = {
            guard isHalfBook, let div = metrics.hingeDivisionRect, div.maxX > div.minX else { return nil }
            return div.minX..<div.maxX
        }()
        let rightEdgeWidth: CGFloat = {
            guard metrics.hasRightSystemColumn else { return 0 }
            return max(metrics.safeAreaRight, metrics.posture == .duoClosed ? 91 : 84)
        }()

        return { startCol in
            DuoColumnMath.openGeometry(
                isHalfBook: isHalfBook,
                width: metrics.viewportSize.width,
                verticalHinge: hingeRange,
                startColumn: startCol,
                rightSystemColumnWidth: rightEdgeWidth
            )
        }
    }

    var body: some View {
        let viewportWidth = max(1, metrics.viewportSize.width)
        let viewportHeight = max(1, metrics.viewportSize.height)
        let count = metrics.visibleColumnCount
        let clampedPosition = max(-0.25, min(CGFloat(count >= 2 ? 2 : 3) + 0.25, position))

        let boxes = DuoColumnMath.boxesAtPosition(
            clampedPosition,
            columnCount: 4,
            viewportWidth: viewportWidth,
            visibleCount: count,
            geometryProvider: Self.makeGeometryProvider(for: metrics)
        )

        let loIndex = Int(floor(clampedPosition + 1e-4))
        let hiIndex = Int(ceil(clampedPosition - 1e-4)) + count - 1
        let isSettled = abs(clampedPosition - clampedPosition.rounded()) < 0.01
        let settledStart = Int(clampedPosition.rounded())

        ZStack(alignment: .topLeading) {
            // Column 0: Sidebar (`Home`)
            columnSlot(
                index: 0,
                box: boxes[0],
                viewportHeight: viewportHeight,
                loIndex: loIndex,
                hiIndex: hiIndex,
                settledStart: settledStart,
                isSettled: isSettled
            ) { colMetrics, backOffset, isSplitLeading in
                SidebarColumnView(store: store, metrics: colMetrics)
                    .overlay(alignment: .bottom) {
                        if shouldShowHorizontalDock(for: 0, isSplitLeading: isSplitLeading) {
                            horizontalDockContainer(
                                columnIndex: 0,
                                isSplitLeading: isSplitLeading,
                                colMetrics: colMetrics,
                                backOffset: backOffset
                            )
                        }
                    }
            }

            // Column 1: ChatList (`Messages`)
            columnSlot(
                index: 1,
                box: boxes[1],
                viewportHeight: viewportHeight,
                loIndex: loIndex,
                hiIndex: hiIndex,
                settledStart: settledStart,
                isSettled: isSettled
            ) { colMetrics, backOffset, isSplitLeading in
                ChatListColumnView(store: store, metrics: colMetrics)
                    .overlay(alignment: .bottom) {
                        if shouldShowHorizontalDock(for: 1, isSplitLeading: isSplitLeading) {
                            horizontalDockContainer(
                                columnIndex: 1,
                                isSplitLeading: isSplitLeading,
                                colMetrics: colMetrics,
                                backOffset: backOffset
                            )
                        }
                    }
            }

            // Column 2: Conversation (`Thread` — constant `525pt` content width on `951×669` `duoOpen`!)
            columnSlot(
                index: 2,
                box: boxes[2],
                viewportHeight: viewportHeight,
                loIndex: loIndex,
                hiIndex: hiIndex,
                settledStart: settledStart,
                isSettled: isSettled
            ) { colMetrics, backOffset, _ in
                if let roomID = threadRoomID {
                    ConversationColumnView(
                        store: store,
                        roomID: roomID,
                        metrics: colMetrics,
                        panLeadOffset: backOffset,
                        onBack: onBackFromThread
                    )
                } else {
                    EmptyConversationPlaceholderView(
                        metrics: colMetrics,
                        glassMode: store.prefs.glassMode,
                        onStartChat: { onPresentModal(.friendsAndRequests) }
                    )
                }
            }

            // Column 3: Artifact (`RoomDetailsInfoView` or `DrawingBoardCanvasView`)
            columnSlot(
                index: 3,
                box: boxes[3],
                viewportHeight: viewportHeight,
                loIndex: loIndex,
                hiIndex: hiIndex,
                settledStart: settledStart,
                isSettled: isSettled
            ) { colMetrics, backOffset, isSplitLeading in
                if let roomID = threadRoomID {
                    ArtifactColumnView(
                        store: store,
                        roomID: roomID,
                        mode: artifactMode,
                        metrics: colMetrics,
                        onClose: onCloseArtifact
                    )
                    .overlay(alignment: .bottom) {
                        if shouldShowHorizontalDock(for: 3, isSplitLeading: isSplitLeading) && artifactMode != .drawingBoard {
                            horizontalDockContainer(
                                columnIndex: 3,
                                isSplitLeading: isSplitLeading,
                                colMetrics: colMetrics,
                                backOffset: backOffset
                            )
                        }
                    }
                } else {
                    Color.clear
                }
            }
        }
        .frame(width: viewportWidth, height: viewportHeight, alignment: .topLeading)
    }

    // MARK: - Per-Column Framing, Metrics & Hairline Seam

    @ViewBuilder
    private func columnSlot<ColumnContent: View>(
        index: Int,
        box: DuoColumnBox,
        viewportHeight: CGFloat,
        loIndex: Int,
        hiIndex: Int,
        settledStart: Int,
        isSettled: Bool,
        @ViewBuilder content: (DuoLayoutMetrics, CGFloat, Bool) -> ColumnContent
    ) -> some View {
        let isVisibleInFlight = (index >= loIndex && index <= hiIndex)
        let isSettledVisible = (index >= settledStart && index < settledStart + metrics.visibleColumnCount)
        let isInteractive = isSettled ? isSettledVisible : isVisibleInFlight
        let isSplitLeading = (metrics.visibleColumnCount >= 2 && index == settledStart)

        let colMetrics = columnScopedMetrics(
            for: index,
            columnWidth: max(1, box.width),
            windowPosition: position
        )
        let backOffset = StripContainerView.stationaryBackOffset(
            for: index,
            boxX: box.x,
            visibleCount: metrics.visibleColumnCount,
            isColumnNearViewport: isVisibleInFlight
        )

        content(colMetrics, backOffset, isSplitLeading)
            .frame(width: max(1, box.width), height: viewportHeight)
            .clipped()
            .overlay(alignment: .trailing) {
                // Crisp `0.5pt` column divider on flat 2-column splits (`duoOpen` & `iPhoneSplit`;
                // `duoHalfBook` uses `HingeBookCreaseOverlay` instead).
                if metrics.visibleColumnCount >= 2 &&
                    metrics.posture != .duoHalfBook &&
                    index >= loIndex &&
                    index < hiIndex {
                    Rectangle()
                        .fill(CuvenColors.hairlineSeparator)
                        .frame(width: 0.5)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .leading) {
                // Subtle depth edge while a 1-column pane slides over its predecessor (`strip.js`)
                if metrics.visibleColumnCount == 1 && !isSettled && index == hiIndex && box.x > 0.5 {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.08)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 10)
                    .offset(x: -10)
                    .allowsHitTesting(false)
                }
            }
            .offset(x: box.x, y: 0)
            .opacity(isVisibleInFlight ? 1.0 : 0.0)
            .allowsHitTesting(isInteractive)
            .accessibilityHidden(!isSettledVisible)
    }

    /// Computes column-local `DuoLayoutMetrics` so:
    /// - Leading split columns (`ChatList` at `342pt`, `Thread` at `525pt`) have `safeAreaRight = 0` and
    ///   `hasRightSystemColumn = false`.
    /// - Trailing split columns (`Thread` at `609pt`, `Artifact` at `426pt`) carry Duo's `84pt` `safeAreaRight`
    ///   and `hasRightSystemColumn = true`.
    /// - During `1.0 <-> 2.0` slide on `duoOpen`, `Thread`'s right clearance interpolates `(2 - p) * 84pt`,
    ///   preserving an exact `525.0pt` usable content width at every single animation frame!
    private func columnScopedMetrics(
        for columnIndex: Int,
        columnWidth: CGFloat,
        windowPosition: CGFloat
    ) -> DuoLayoutMetrics {
        guard metrics.visibleColumnCount >= 2 else {
            return metrics
        }

        let effectiveSystemRight: CGFloat = metrics.hasRightSystemColumn
            ? max(metrics.safeAreaRight, metrics.posture == .duoClosed ? 91 : 84)
            : metrics.safeAreaRight

        // Continuous trailingness factor (`0.0` when leading, `1.0` when trailing)
        let trailingFraction = min(1.0, max(0.0, CGFloat(columnIndex) - windowPosition))
        let leadingFraction = 1.0 - trailingFraction

        let colSafeLeft = metrics.safeAreaLeft * leadingFraction
        let colSafeRight = effectiveSystemRight * trailingFraction
        let colHasRightRail = metrics.hasRightSystemColumn && trailingFraction > 0.5

        return DuoLayoutMetrics(
            posture: metrics.posture,
            viewportSize: CGSize(width: columnWidth, height: metrics.viewportSize.height),
            safeAreaTop: metrics.safeAreaTop,
            safeAreaBottom: metrics.safeAreaBottom,
            safeAreaLeft: colSafeLeft,
            safeAreaRight: colSafeRight,
            hasRightSystemColumn: colHasRightRail,
            visibleColumnCount: metrics.visibleColumnCount,
            leadingColumnWidth: metrics.leadingColumnWidth,
            trailingColumnWidth: metrics.trailingColumnWidth,
            threadContentWidth: metrics.threadContentWidth,
            hingeDivisionRect: metrics.hingeDivisionRect,
            railWidth: colHasRightRail ? metrics.railWidth : 0,
            railCenterFromRight: metrics.railCenterFromRight,
            railTopReserve: colHasRightRail ? metrics.railTopReserve : 0
        )
    }

    private func shouldShowHorizontalDock(for columnIndex: Int, isSplitLeading: Bool) -> Bool {
        // Column 2 (`Thread`) owns its dedicated `ThreadComposerBar`.
        guard columnIndex != 2 else { return false }

        // In 1-column `duoClosed`, all controls live in the vertical `DuoRailView`.
        if metrics.visibleColumnCount == 1 && metrics.hasRightSystemColumn {
            return false
        }

        // In 2-column split:
        if metrics.visibleColumnCount >= 2 {
            // Leading `Sidebar` (`0`) already displays all scopes & places inline.
            if columnIndex == 0 && isSplitLeading {
                return false
            }
            // On iPhone Duo (`duoOpen` / `duoHalfBook`), ONLY the leading column (`ChatList` `342pt` / `462pt`)
            // gets the horizontal `Filter + Search` dock; the trailing column uses `DuoRailView`!
            if metrics.hasRightSystemColumn {
                return isSplitLeading && columnIndex == 1
            }
            // On symmetric `iPhoneSplit`, keep a single active `shell.bottomDock` on `ChatList` (`1`) or `Artifact` (`3`).
            if columnIndex == 1 {
                return true
            }
            if columnIndex == 3 && !isSplitLeading {
                return true
            }
            return false
        }

        return true
    }

    @ViewBuilder
    private func horizontalDockContainer(
        columnIndex: Int,
        isSplitLeading: Bool,
        colMetrics: DuoLayoutMetrics,
        backOffset: CGFloat
    ) -> some View {
        let bottomClearance: CGFloat = keyboardHeight > 40
            ? keyboardHeight + 8
            : max(colMetrics.safeAreaBottom, 16)
        let horizontalMargin: CGFloat = colMetrics.viewportSize.width >= 430 ? 18 : 14

        HorizontalBottomDockView(
            store: store,
            columnIndex: columnIndex,
            isSplitLeadingColumn: isSplitLeading,
            metrics: colMetrics,
            panLeadBackOffset: backOffset,
            onNavigateColumn: onNavigateColumn,
            onPresentModal: onPresentModal
        )
        .padding(.leading, colMetrics.safeAreaLeft + horizontalMargin)
        .padding(.trailing, colMetrics.safeAreaRight + horizontalMargin)
        .padding(.bottom, bottomClearance)
    }
}

// MARK: - Editorial Empty Conversation Stage (When Zero Rooms Exist)

private struct EmptyConversationPlaceholderView: View {
    let metrics: DuoLayoutMetrics
    let glassMode: GlassAppearanceMode
    let onStartChat: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(CuvenColors.inkTertiary)

            Text("Select a conversation")
                .font(CuvenFonts.clarinettaDisplay(size: 26, weight: .medium))
                .foregroundStyle(CuvenColors.inkPrimary)

            Text("Choose a chat from Messages or start a new conversation.")
                .font(CuvenFonts.cappedSubheadline())
                .foregroundStyle(CuvenColors.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            Button {
                CuvenHaptics.lightTap()
                onStartChat()
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
                    .font(CuvenFonts.cappedSubheadline(weight: .semibold))
                    .foregroundStyle(CuvenColors.inkPrimary)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.cuvenGlassPill(mode: glassMode, cornerRadius: 22))
        }
        .padding(.leading, metrics.safeAreaLeft + 24)
        .padding(.trailing, metrics.safeAreaRight + 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CuvenColors.paperBackground)
    }
}

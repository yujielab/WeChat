//
//  DuoPostureMonitor.swift
//  Cuven
//
//  Apple HIG & iOS 27.1 SDK Grounding:
//  - Human Interface Guidelines › Designing for iPhone Duo (Anatomy, Device poses, Dynamic layouts,
//    Reserved regions, Vertical controls — Sept 9, 2026)
//  - Apple Developer Documentation › Preparing your app for iPhone Duo (`GeometryProxy.reservedRegions(kind:options:)`,
//    `View.onHingeChange(isEnabled:_:)`, `EnvironmentValues.toolbarVerticalEdge`, `View.toolbarVerticalBehavior(_:)`)
//  - Cuven Web Parity: `public/js/ui/viewport.js:1-400`, `public/js/ui/posture.js:1-70`,
//    `public/css/rail.css:17-54`, `design-qa.md:137-156, 220-226, 975-982`
//

import Combine
import CuvenCore
import SwiftUI
import UIKit

// MARK: - Shell Coordination Actions & Environment Keys

/// Modal destinations hosted by `RootCoordinatorView` that can be invoked from any column chrome,
/// `AdaptiveActionBars`, `DuoRailView`, or `PagesCapsuleView`.
public enum CuvenShellModalDestination: Identifiable, Equatable, Sendable {
    case settings
    case settingsTab(String)
    case avatarCoverEditor
    case friendsAndRequests
    case globalSearch
    case wordExplain(initialText: String, roomContext: String)

    public var id: String {
        switch self {
        case .settings:
            return "settings"
        case .settingsTab(let tab):
            return "settings.\(tab)"
        case .avatarCoverEditor:
            return "avatarCoverEditor"
        case .friendsAndRequests:
            return "friendsAndRequests"
        case .globalSearch:
            return "globalSearch"
        case .wordExplain(let initialText, _):
            return "wordExplain.\(initialText.hashValue)"
        }
    }
}

private struct CuvenLayoutMetricsKey: EnvironmentKey {
    static let defaultValue = DuoLayoutMetrics.compute(
        size: CGSize(width: 393, height: 852),
        safeTop: 59,
        safeBottom: 34,
        safeLeft: 0,
        safeRight: 0,
        activePairStartsAtThread: false,
        postureOverride: nil
    )
}

private struct CuvenHingeAngleDegreesKey: EnvironmentKey {
    static let defaultValue: Double? = nil
}

private struct CuvenHingePartiallyOpenKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

private struct CuvenKeyboardHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private struct CuvenShellModalTriggerKey: EnvironmentKey {
    static let defaultValue: @Sendable @MainActor (CuvenShellModalDestination) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Live spatial layout metrics resolved by `DuoPostureMonitor`.
    public var cuvenLayoutMetrics: DuoLayoutMetrics {
        get { self[CuvenLayoutMetricsKey.self] }
        set { self[CuvenLayoutMetricsKey.self] = newValue }
    }

    /// Continuous physical hinge angle in degrees reported by iOS 27.1 `onHingeChange` (used strictly
    /// for optical crease shading in `HingeBookCreaseOverlay`, never to thrash layout frames).
    public var cuvenHingeAngleDegrees: Double? {
        get { self[CuvenHingeAngleDegreesKey.self] }
        set { self[CuvenHingeAngleDegreesKey.self] = newValue }
    }

    /// True when the physical iPhone Duo hinge reports `DeviceHinge.Status.partiallyOpen`.
    public var cuvenHingeIsPartiallyOpen: Bool {
        get { self[CuvenHingePartiallyOpenKey.self] }
        set { self[CuvenHingePartiallyOpenKey.self] = newValue }
    }

    /// Live software keyboard overlap height (`0` when dismissed or during width-changing fold/unfold transitions).
    public var cuvenKeyboardHeight: CGFloat {
        get { self[CuvenKeyboardHeightKey.self] }
        set { self[CuvenKeyboardHeightKey.self] = newValue }
    }

    /// Action closure allowing adaptive bars & rails to present shell-level modals cleanly.
    public var cuvenPresentShellModal: @Sendable @MainActor (CuvenShellModalDestination) -> Void {
        get { self[CuvenShellModalTriggerKey.self] }
        set { self[CuvenShellModalTriggerKey.self] = newValue }
    }
}

// MARK: - DuoPostureMonitor Container

/// Measures real `GeometryProxy` scene dimensions, `UIWindowScene` safe-area insets (including late-arriving
/// iOS 27.1/27.2 right-edge Duo status column updates), and native `@available(iOS 27.1, *)` fold division
/// regions & hinge angle updates, delegating geometry calculation to `DuoLayoutMetrics.compute(...)`.
///
/// Honors `store.postureOverride` (set via `--uitest-posture=...` or `PostureMatrixSwitcherHUD`) so all six
/// `DuoPosture` states can be inspected and verified live on both standard iPhone and iPhone Duo Simulators.
public struct DuoPostureMonitor<Content: View>: View {
    private let store: AppStore
    private let content: (DuoLayoutMetrics) -> Content

    @State private var windowSafeInsets: UIEdgeInsets = .zero
    @State private var trailingVerticalToolbarDetected: Bool = false
    @State private var hingeAngleDegrees: Double? = nil
    @State private var hingeIsPartiallyOpen: Bool = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var lastObservedHostWidth: CGFloat = 0

    public init(
        store: AppStore,
        @ViewBuilder content: @escaping (DuoLayoutMetrics) -> Content
    ) {
        self.store = store
        self.content = content
    }

    /// True when the 2-column sliding window starts at Column 2 (`Thread | Artifact`),
    /// matching `windowStart(focus, count) == 2` in `public/js/ui/strip.js:27-30`.
    private var activePairStartsAtThread: Bool {
        if store.activeColumnIndex >= 3 {
            return true
        }
        if store.activeArtifactMode != nil && store.activeColumnIndex >= 2 {
            return true
        }
        return false
    }

    public var body: some View {
        GeometryReader { proxy in
            let hostSize = proxy.size
            let mergedSafeTop = max(proxy.safeAreaInsets.top, windowSafeInsets.top)
            let mergedSafeBottom = max(proxy.safeAreaInsets.bottom, windowSafeInsets.bottom)
            let mergedSafeLeft = max(proxy.safeAreaInsets.leading, windowSafeInsets.left)
            let mergedSafeRight = max(proxy.safeAreaInsets.trailing, windowSafeInsets.right)

            let hardwareDivision = Self.extractHardwareDivisionRect(from: proxy)
            let viewportPlan = resolveViewportPlan(
                hostSize: hostSize,
                safeTop: mergedSafeTop,
                safeBottom: mergedSafeBottom,
                safeLeft: mergedSafeLeft,
                safeRight: mergedSafeRight,
                hardwareDivision: hardwareDivision
            )

            ZStack {
                if viewportPlan.isFramedPreview {
                    CuvenColors.secondaryElevatedSurface
                        .ignoresSafeArea()
                }

                content(viewportPlan.metrics)
                    .frame(
                        width: viewportPlan.canvasSize.width,
                        height: viewportPlan.canvasSize.height
                    )
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: viewportPlan.isFramedPreview ? 28 : 0,
                            style: .continuous
                        )
                    )
                    .overlay {
                        if viewportPlan.isFramedPreview {
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .strokeBorder(CuvenColors.hairlineSeparator, lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                    }
                    .scaleEffect(viewportPlan.scale, anchor: .center)
                    .frame(width: hostSize.width, height: hostSize.height, alignment: .center)
            }
            .background {
                WindowSafeAreaProbeView { insets in
                    if insets != windowSafeInsets {
                        windowSafeInsets = insets
                    }
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .modifier(
                IOS271DuoHardwareBridgeModifier(
                    onVerticalEdgeChange: { isTrailing in
                        if trailingVerticalToolbarDetected != isTrailing {
                            trailingVerticalToolbarDetected = isTrailing
                        }
                    },
                    onHingeUpdate: { angle, partiallyOpen in
                        hingeAngleDegrees = angle
                        hingeIsPartiallyOpen = partiallyOpen
                    }
                )
            )
            .environment(\.cuvenLayoutMetrics, viewportPlan.metrics)
            .environment(\.cuvenHingeAngleDegrees, hingeAngleDegrees)
            .environment(\.cuvenHingePartiallyOpen, hingeIsPartiallyOpen)
            .environment(\.cuvenKeyboardHeight, keyboardHeight)
            .onChange(of: hostSize.width) { oldWidth, newWidth in
                // Per `viewport.js:58-64` & `design-qa.md:131`: any width change is a fold, unfold,
                // or rotation — never the software keyboard — so clear stale keyboard state immediately.
                if abs(newWidth - oldWidth) > 1 {
                    keyboardHeight = 0
                }
                lastObservedHostWidth = newWidth
            }
            .onAppear {
                lastObservedHostWidth = hostSize.width
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                handleKeyboardNotification(note, screenHeight: hostSize.height + mergedSafeTop + mergedSafeBottom)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                if keyboardHeight != 0 {
                    keyboardHeight = 0
                }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Viewport & Metrics Resolution

    private struct ViewportResolutionPlan {
        let metrics: DuoLayoutMetrics
        let canvasSize: CGSize
        let scale: CGFloat
        let isFramedPreview: Bool
    }

    private func resolveViewportPlan(
        hostSize: CGSize,
        safeTop: CGFloat,
        safeBottom: CGFloat,
        safeLeft: CGFloat,
        safeRight: CGFloat,
        hardwareDivision: CGRect?
    ) -> ViewportResolutionPlan {
        let validHostWidth = max(1, hostSize.width)
        let validHostHeight = max(1, hostSize.height)

        // 1. Hardware Auto Mode (`store.postureOverride == nil`)
        guard let override = store.postureOverride else {
            // Check whether iOS 27.1 `toolbarVerticalEdge == .trailing` indicates an external/beside
            // Duo status column (`viewport.js:225-243` `data-column="beside"`).
            var effectiveSafeRight = safeRight
            if trailingVerticalToolbarDetected && safeRight < DuoLayoutMetrics.edgeColumnMinimum {
                effectiveSafeRight = validHostWidth >= DuoLayoutMetrics.splitThreshold ? 84 : 91
            }

            // Hardware fold layout bounds are driven exclusively by `GeometryProxy.reservedRegions(kind: .division, options: .includeInactive)`
            // (`isActive == true`); `onHingeChange` angle modulates `HingeBookCreaseOverlay` spine shading only.
            var inferredHardwarePosture: DuoPosture? = nil
            if let division = hardwareDivision, division.width > 0 || division.height > 0 {
                if division.height >= division.width {
                    inferredHardwarePosture = .duoHalfBook
                } else {
                    inferredHardwarePosture = .duoHalfLaptop
                }
            }

            let base = DuoLayoutMetrics.compute(
                size: CGSize(width: validHostWidth, height: validHostHeight),
                safeTop: safeTop,
                safeBottom: safeBottom,
                safeLeft: safeLeft,
                safeRight: effectiveSafeRight,
                activePairStartsAtThread: activePairStartsAtThread,
                postureOverride: inferredHardwarePosture
            )

            // If hardware supplied an exact division rect (`ReservedRegion.Kind.division`), honor its exact frame.
            let finalMetrics: DuoLayoutMetrics
            if let division = hardwareDivision,
               inferredHardwarePosture == .duoHalfBook || inferredHardwarePosture == .duoHalfLaptop {
                let leftW = inferredHardwarePosture == .duoHalfBook ? division.minX : validHostWidth
                let rightW = inferredHardwarePosture == .duoHalfBook ? max(0, validHostWidth - division.maxX) : 0
                let threadW: CGFloat
                if inferredHardwarePosture == .duoHalfBook {
                    threadW = activePairStartsAtThread ? leftW : max(0, rightW - (base.hasRightSystemColumn ? max(effectiveSafeRight, 84) : 0))
                } else {
                    threadW = base.threadContentWidth
                }
                finalMetrics = DuoLayoutMetrics(
                    posture: base.posture,
                    viewportSize: base.viewportSize,
                    safeAreaTop: base.safeAreaTop,
                    safeAreaBottom: base.safeAreaBottom,
                    safeAreaLeft: base.safeAreaLeft,
                    safeAreaRight: effectiveSafeRight,
                    hasRightSystemColumn: base.hasRightSystemColumn,
                    visibleColumnCount: base.visibleColumnCount,
                    leadingColumnWidth: leftW,
                    trailingColumnWidth: rightW,
                    threadContentWidth: threadW,
                    hingeDivisionRect: division,
                    railWidth: base.railWidth,
                    railCenterFromRight: base.railCenterFromRight,
                    railTopReserve: base.railTopReserve
                )
            } else {
                finalMetrics = base
            }

            return ViewportResolutionPlan(
                metrics: finalMetrics,
                canvasSize: CGSize(width: validHostWidth, height: validHostHeight),
                scale: 1.0,
                isFramedPreview: false
            )
        }

        // 2. Explicit Override Mode (`--uitest-posture=...` or `PostureMatrixSwitcherHUD`)
        let targetSpec = canonicalOverrideSpec(for: override, hostSize: CGSize(width: validHostWidth, height: validHostHeight), hostSafeTop: safeTop, hostSafeBottom: safeBottom)
        let computed = DuoLayoutMetrics.compute(
            size: targetSpec.canvasSize,
            safeTop: targetSpec.safeTop,
            safeBottom: targetSpec.safeBottom,
            safeLeft: targetSpec.safeLeft,
            safeRight: targetSpec.safeRight,
            activePairStartsAtThread: activePairStartsAtThread,
            postureOverride: override
        )

        // Ensure `safeAreaRight` reflects the effective Duo status column width (`84pt` inner / `91pt` outer)
        // when simulating Duo postures on standard iPhones, so downstream feature views inset content cleanly.
        let resolvedSafeRight: CGFloat
        if computed.hasRightSystemColumn && computed.safeAreaRight < DuoLayoutMetrics.edgeColumnMinimum {
            resolvedSafeRight = (override == .duoClosed) ? 91 : 84
        } else {
            resolvedSafeRight = computed.safeAreaRight
        }

        let normalizedMetrics = DuoLayoutMetrics(
            posture: computed.posture,
            viewportSize: computed.viewportSize,
            safeAreaTop: computed.safeAreaTop,
            safeAreaBottom: computed.safeAreaBottom,
            safeAreaLeft: computed.safeAreaLeft,
            safeAreaRight: resolvedSafeRight,
            hasRightSystemColumn: computed.hasRightSystemColumn,
            visibleColumnCount: computed.visibleColumnCount,
            leadingColumnWidth: computed.leadingColumnWidth,
            trailingColumnWidth: computed.trailingColumnWidth,
            threadContentWidth: computed.threadContentWidth,
            hingeDivisionRect: computed.hingeDivisionRect,
            railWidth: computed.railWidth,
            railCenterFromRight: computed.railCenterFromRight,
            railTopReserve: computed.railTopReserve
        )

        return ViewportResolutionPlan(
            metrics: normalizedMetrics,
            canvasSize: targetSpec.canvasSize,
            scale: targetSpec.scale,
            isFramedPreview: targetSpec.isFramedPreview
        )
    }

    private struct CanonicalOverrideSpec {
        let canvasSize: CGSize
        let safeTop: CGFloat
        let safeBottom: CGFloat
        let safeLeft: CGFloat
        let safeRight: CGFloat
        let scale: CGFloat
        let isFramedPreview: Bool
    }

    /// Maps an overridden `DuoPosture` to exact native dimensions when the physical Simulator window
    /// already fits that class (1.0x native points), or fits the canonical device grid cleanly inside
    /// the host window so 100% of columns, rails, and capsules remain visible and hittable.
    private func canonicalOverrideSpec(
        for posture: DuoPosture,
        hostSize: CGSize,
        hostSafeTop: CGFloat,
        hostSafeBottom: CGFloat
    ) -> CanonicalOverrideSpec {
        switch posture {
        case .iPhoneCompact:
            if hostSize.width < DuoLayoutMetrics.splitThreshold {
                return CanonicalOverrideSpec(
                    canvasSize: hostSize,
                    safeTop: max(hostSafeTop, 54),
                    safeBottom: max(hostSafeBottom, 34),
                    safeLeft: 0,
                    safeRight: 0,
                    scale: 1.0,
                    isFramedPreview: false
                )
            }
            let targetHeight = hostSize.height >= 600 ? min(852, hostSize.height - 16) : 852
            let target = CGSize(width: 393, height: targetHeight)
            let fit = min(1.0, min((hostSize.width - 16) / target.width, (hostSize.height - 16) / target.height))
            return CanonicalOverrideSpec(
                canvasSize: target,
                safeTop: 59,
                safeBottom: 34,
                safeLeft: 0,
                safeRight: 0,
                scale: max(0.5, fit),
                isFramedPreview: true
            )

        case .iPhoneSplit:
            if hostSize.width >= DuoLayoutMetrics.splitThreshold {
                return CanonicalOverrideSpec(
                    canvasSize: hostSize,
                    safeTop: hostSafeTop,
                    safeBottom: max(hostSafeBottom, 21),
                    safeLeft: 62,
                    safeRight: 62,
                    scale: 1.0,
                    isFramedPreview: false
                )
            }
            let target = CGSize(width: 956, height: 440)
            let fit = min(1.0, min(hostSize.width / target.width, hostSize.height / target.height))
            return CanonicalOverrideSpec(
                canvasSize: target,
                safeTop: 0,
                safeBottom: 21,
                safeLeft: 62,
                safeRight: 62,
                scale: max(0.38, fit),
                isFramedPreview: true
            )

        case .duoClosed:
            // Outer cover display: 466×678pt (`91pt` right safe area, `170pt` top camera+clock reserve).
            if hostSize.width < DuoLayoutMetrics.splitThreshold {
                return CanonicalOverrideSpec(
                    canvasSize: hostSize,
                    safeTop: max(hostSafeTop, 20),
                    safeBottom: max(hostSafeBottom, 24),
                    safeLeft: 0,
                    safeRight: 91,
                    scale: 1.0,
                    isFramedPreview: false
                )
            }
            let targetHeight = hostSize.height >= 600 ? min(678, hostSize.height - 12) : 678
            let target = CGSize(width: 466, height: targetHeight)
            let fit = min(1.0, min((hostSize.width - 12) / target.width, (hostSize.height - 12) / target.height))
            return CanonicalOverrideSpec(
                canvasSize: target,
                safeTop: 20,
                safeBottom: 24,
                safeLeft: 0,
                safeRight: 91,
                scale: max(0.5, fit),
                isFramedPreview: true
            )

        case .duoOpen, .duoHalfBook:
            // Inner unfolded display: 951×669pt (`84pt` right safe area, `118pt` top clock reserve).
            if hostSize.width >= DuoLayoutMetrics.splitThreshold {
                return CanonicalOverrideSpec(
                    canvasSize: hostSize,
                    safeTop: max(hostSafeTop, 16),
                    safeBottom: max(hostSafeBottom, 20),
                    safeLeft: 0,
                    safeRight: 84,
                    scale: 1.0,
                    isFramedPreview: false
                )
            }
            let target = CGSize(width: 951, height: 669)
            let fit = min(1.0, min(hostSize.width / target.width, hostSize.height / target.height))
            return CanonicalOverrideSpec(
                canvasSize: target,
                safeTop: 16,
                safeBottom: 20,
                safeLeft: 0,
                safeRight: 84,
                scale: max(0.38, fit),
                isFramedPreview: true
            )

        case .duoHalfLaptop:
            // Tabletop horizontal fold: top visual stage above crease, bottom controls deck below crease.
            return CanonicalOverrideSpec(
                canvasSize: hostSize,
                safeTop: max(hostSafeTop, 20),
                safeBottom: max(hostSafeBottom, 20),
                safeLeft: 0,
                safeRight: hostSize.width >= DuoLayoutMetrics.splitThreshold ? 84 : 0,
                scale: 1.0,
                isFramedPreview: false
            )
        }
    }

    // MARK: - iOS 27.1 Native ReservedRegion Extraction

    private static func extractHardwareDivisionRect(from proxy: GeometryProxy) -> CGRect? {
        if #available(iOS 27.1, *) {
            let regions = proxy.reservedRegions(kind: .division, options: .includeInactive)
            if let activeDivision = regions.first(where: { $0.isActive && ($0.frame.width > 0 || $0.frame.height > 0) }) {
                return activeDivision.frame
            }
        }
        return nil
    }

    // MARK: - Keyboard Overlap Tracking

    private func handleKeyboardNotification(_ notification: Notification, screenHeight: CGFloat) {
        guard let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }
        let overlap = max(0, screenHeight - endFrame.minY)
        let resolved = overlap > 60 ? overlap : 0
        if abs(keyboardHeight - resolved) > 1 {
            keyboardHeight = resolved
        }
    }
}

// MARK: - Native iOS 27.1 Duo Hardware Trait & Hinge Bridge

private struct IOS271DuoHardwareBridgeModifier: ViewModifier {
    let onVerticalEdgeChange: @MainActor @Sendable (Bool) -> Void
    let onHingeUpdate: @MainActor @Sendable (Double?, Bool) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            IOS271InnerHardwareBridge(
                content: content,
                onVerticalEdgeChange: onVerticalEdgeChange,
                onHingeUpdate: onHingeUpdate
            )
        } else {
            content
        }
    }
}

@available(iOS 27.1, *)
private struct IOS271InnerHardwareBridge<Content: View>: View {
    let content: Content
    let onVerticalEdgeChange: @MainActor @Sendable (Bool) -> Void
    let onHingeUpdate: @MainActor @Sendable (Double?, Bool) -> Void

    @Environment(\.toolbarVerticalEdge) private var toolbarVerticalEdge

    var body: some View {
        let hingeCallback = onHingeUpdate
        content
            // Disable stock UIKit/SwiftUI vertical bar injection so Cuven's bespoke 52pt Liquid Glass
            // `DuoRailView` and `PagesCapsuleView` own the right-edge system column cleanly.
            .toolbarVerticalBehavior(.disabled)
            .onAppear {
                onVerticalEdgeChange(toolbarVerticalEdge == .trailing)
            }
            .onChange(of: toolbarVerticalEdge) { _, newEdge in
                onVerticalEdgeChange(newEdge == .trailing)
            }
            // Verified Apple DocC signature: `onHingeChange(isEnabled:_:)` with `(DeviceHingeContext, DeviceHingeContext) -> Void`.
            // `DeviceHinge.Status` is a struct (`.closed`, `.partiallyOpen`, `.fullyOpen`).
            // `h.angle.degrees` modulates `HingeBookCreaseOverlay` spine shadow opacity ONLY, never layout bounds!
            .onHingeChange { oldContext, newContext in
                _ = oldContext
                guard let h = newContext.hinge else {
                    if Thread.isMainThread {
                        MainActor.assumeIsolated { hingeCallback(nil, false) }
                    } else {
                        Task { @MainActor in hingeCallback(nil, false) }
                    }
                    return
                }
                let isPartial = (h.status == .partiallyOpen)
                let reportedDegrees: Double? = (h.status == .closed || h.status == .fullyOpen) ? nil : h.angle.degrees
                if Thread.isMainThread {
                    MainActor.assumeIsolated { hingeCallback(reportedDegrees, isPartial) }
                } else {
                    Task { @MainActor in hingeCallback(reportedDegrees, isPartial) }
                }
            }
    }
}

// MARK: - UIWindowScene Safe-Area Probe (`design-qa.md:220-226` Late Safe-Area Fix)

/// Zero-footprint UIKit probe observing `safeAreaInsetsDidChange()` directly on the hosting window
/// so asynchronous safe-area updates on iPhone Duo (where iOS 27.x delivers the `84pt`/`91pt` right
/// status column inset after initial scene presentation without resizing) immediately recompute metrics.
private struct WindowSafeAreaProbeView: UIViewRepresentable {
    let onInsetsChange: (UIEdgeInsets) -> Void

    func makeUIView(context: Context) -> ProbeUIView {
        let view = ProbeUIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onInsetsChange = onInsetsChange
        return view
    }

    func updateUIView(_ uiView: ProbeUIView, context: Context) {
        uiView.onInsetsChange = onInsetsChange
        uiView.reportCurrentWindowInsets()
    }

    final class ProbeUIView: UIView {
        var onInsetsChange: ((UIEdgeInsets) -> Void)?
        private var lastReported: UIEdgeInsets = .zero

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reportCurrentWindowInsets()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            reportCurrentWindowInsets()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            reportCurrentWindowInsets()
        }

        func reportCurrentWindowInsets() {
            guard let window else { return }
            let current = window.safeAreaInsets
            if current != lastReported {
                lastReported = current
                onInsetsChange?(current)
            }
        }
    }
}

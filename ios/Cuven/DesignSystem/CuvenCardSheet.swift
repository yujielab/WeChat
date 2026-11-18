//
//  CuvenCardSheet.swift
//  Cuven
//
//  Apple HIG & iOS 27.1 SDK Grounding:
//  - Human Interface Guidelines › Designing for iPhone Duo › Sheets & Alerts
//    (centered on physical screen midpoint in `duoOpen` clear of 84pt right rail; confined to active side in `duoHalfBook`)
//  - Human Interface Guidelines › Sheets & Gestures (1:1 interactive drag-down dismissal with velocity projection)
//  - Cuven Web Parity: `public/css/overlays.css:31-119`, `public/css/fold.css:10-14`,
//    `public/css/base.css:113-126` (`.app.sheeted` `0.94` scale + `22pt` radius shell recession),
//    `public/js/views/overlay.js:111-330`, `design-qa.md:969-974`
//

import CuvenCore
import SwiftUI

// MARK: - Canonical View.cuvenAdaptiveModal Modifier (`PROJECT.md § 5.3`)

extension View {
    /// Presents a posture-adaptive Cuven modal sheet or centered card at window level:
    /// - **Compact / Stack (`iPhoneCompact`, `duoClosed`, `duoHalfLaptop`)**: `30pt`-radius bottom sheet with
    ///   grabber pill, `1:1` finger-tracked drag-down dismissal (`VelocityProjector.project(velocity:decelerationRate:)`),
    ///   and live `.shell` recession (`0.94` scale + `22pt` corner radius) synced to sheet state.
    /// - **Duo Open Flat & Split (`duoOpen`, `iPhoneSplit`)**: Centered floating `28pt`-radius card
    ///   (`maxWidth: 500pt`, `tall: 640pt`) anchored to the **physical screen midpoint** (`475.5pt` on `951×669pt`,
    ///   `design-qa.md:970-973`) and clamped `8pt` clear of iPhone Duo's asymmetric `84pt` right system column.
    /// - **Duo Half-Book (`duoHalfBook`)**: Automatically detects the originating half of the trigger view and
    ///   confines the `28pt`-radius floating card strictly to that half clear of `metrics.hingeDivisionRect`
    ///   (`fold.css:11-14`) and clear of the `84pt` right column.
    /// - **iOS 27.0+ Placement**: Applies `.presentationPlacement(...)` (`#available(iOS 27.0, *)`) matching
    ///   `.center` (`duoOpen` / `iPhoneSplit`), `.leading` / `.trailing` (`duoHalfBook`), or `.automatic` (stack).
    public func cuvenAdaptiveModal<ModalContent: View>(
        isPresented: Binding<Bool>,
        metrics: DuoLayoutMetrics,
        tall: Bool = false,
        @ViewBuilder content: @escaping () -> ModalContent
    ) -> some View {
        modifier(
            CuvenAdaptiveModalModifier(
                isPresented: isPresented,
                metrics: metrics,
                tall: tall,
                explicitOriginTrailing: nil,
                modalContent: content
            )
        )
    }

    /// Overload allowing callers to explicitly specify whether a `duoHalfBook` modal originated from the trailing half.
    public func cuvenAdaptiveModal<ModalContent: View>(
        isPresented: Binding<Bool>,
        metrics: DuoLayoutMetrics,
        tall: Bool = false,
        originatesOnTrailingHalf: Bool,
        @ViewBuilder content: @escaping () -> ModalContent
    ) -> some View {
        modifier(
            CuvenAdaptiveModalModifier(
                isPresented: isPresented,
                metrics: metrics,
                tall: tall,
                explicitOriginTrailing: originatesOnTrailingHalf,
                modalContent: content
            )
        )
    }

    /// Applies Apple's iOS 27.0+ `presentationPlacement(_:)` modifier for standard SwiftUI `.sheet` / `.popover`
    /// views according to `DuoLayoutMetrics` (`duoOpen` -> `.center`, `duoHalfBook` -> `.leading` / `.trailing`).
    @ViewBuilder
    public func cuvenPresentationPlacement(
        metrics: DuoLayoutMetrics,
        originatesOnTrailingHalf: Bool = false
    ) -> some View {
        if #available(iOS 27.0, *) {
            switch metrics.posture {
            case .duoOpen, .iPhoneSplit:
                self.presentationPlacement(.center)
            case .duoHalfBook:
                self.presentationPlacement(originatesOnTrailingHalf ? .trailing : .leading)
            case .iPhoneCompact, .duoClosed, .duoHalfLaptop:
                self.presentationPlacement(.automatic)
            }
        } else {
            self
        }
    }
}

private struct CuvenAdaptiveModalModifier<ModalContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let metrics: DuoLayoutMetrics
    let tall: Bool
    let explicitOriginTrailing: Bool?
    let modalContent: () -> ModalContent

    @State private var triggerGlobalFrame: CGRect = .zero
    @State private var dragOffsetY: CGFloat = 0
    @State private var measuredSheetHeight: CGFloat = 420
    @State private var velocityTracker = CuvenGestureVelocityTracker()
    @State private var isDraggingSheet = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var isStackPresentation: Bool {
        switch metrics.posture {
        case .iPhoneCompact, .duoClosed, .duoHalfLaptop:
            return true
        case .iPhoneSplit, .duoHalfBook, .duoOpen:
            return false
        }
    }

    /// `0.0` (dismissed) ... `1.0` (fully resting open), driven 1:1 by finger drag in compact stack mode (`overlay.js:185-187`).
    private var shellRecessionProgress: CGFloat {
        guard isPresented, isStackPresentation, !reduceMotion else { return 0.0 }
        let denom = max(measuredSheetHeight, 180.0)
        let dragFraction = min(max(dragOffsetY / denom, 0.0), 1.0)
        return 1.0 - dragFraction
    }

    private var scrimOpacityFactor: Double {
        guard isPresented else { return 0.0 }
        let denom = max(measuredSheetHeight, 180.0)
        let dragFraction = min(max(dragOffsetY / denom, 0.0), 1.0)
        return Double(1.0 - dragFraction)
    }

    private func originatesOnTrailingHalf(canvasWidth: CGFloat) -> Bool {
        if let explicitOriginTrailing {
            return explicitOriginTrailing
        }
        guard triggerGlobalFrame.width > 0 else { return false }
        let hingeStart = metrics.hingeDivisionRect?.minX
            ?? (metrics.leadingColumnWidth > 0 ? metrics.leadingColumnWidth : canvasWidth * 0.485)
        // Full-viewport hosts default to leading half on `duoHalfBook`; column-scoped hosts match their half.
        if triggerGlobalFrame.width >= canvasWidth * 0.75 {
            return false
        }
        return triggerGlobalFrame.midX > hingeStart
    }

    func body(content: Content) -> some View {
        let recedeK = shellRecessionProgress

        content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { newFrame in
                triggerGlobalFrame = newFrame
            }
            .scaleEffect(1.0 - 0.06 * recedeK, anchor: .top)
            .offset(y: (metrics.safeAreaTop * 0.22 + 8.0) * recedeK)
            .clipShape(RoundedRectangle(cornerRadius: 22.0 * recedeK, style: .continuous))
            .animation(
                isDraggingSheet
                    ? nil
                    : CuvenSprings.adaptive(CuvenSprings.sheetPresent, reduceMotion: reduceMotion),
                value: isPresented
            )
            .fullScreenCover(isPresented: $isPresented) {
                let referenceWidth = max(metrics.viewportSize.width, 320.0)
                modalOverlayLayer
                    .presentationBackground(.clear)
                    .cuvenPresentationPlacement(
                        metrics: metrics,
                        originatesOnTrailingHalf: originatesOnTrailingHalf(canvasWidth: referenceWidth)
                    )
                    .transaction { transaction in
                        if reduceMotion {
                            transaction.disablesAnimations = true
                        }
                    }
            }
            .transaction { transaction in
                if reduceMotion {
                    transaction.disablesAnimations = true
                }
            }
            .onChange(of: isPresented) { _, nowPresented in
                if !nowPresented {
                    dragOffsetY = 0
                    isDraggingSheet = false
                    velocityTracker.reset()
                }
            }
    }

    // MARK: - Window-Level Modal Overlay Layer (Stack Bottom Sheet vs Split 475.5pt Center / Half-Book Card)

    private var modalOverlayLayer: some View {
        GeometryReader { proxy in
            let canvasWidth = proxy.size.width > 0
                ? proxy.size.width
                : max(metrics.viewportSize.width, 320.0)
            let canvasHeight = max(proxy.size.height, 240.0)

            ZStack {
                // Dimming scrim (`overlays.css:15-22`) extends edge-to-edge including behind keyboard & status column.
                CuvenColors.overlayScrim
                    .opacity(scrimOpacityFactor)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissModal()
                    }
                    .accessibilityLabel("Dismiss modal")
                    .accessibilityAddTraits(.isButton)

                if isStackPresentation {
                    stackBottomSheet(canvasWidth: canvasWidth, canvasHeight: canvasHeight)
                } else {
                    splitFloatingCard(canvasWidth: canvasWidth, canvasHeight: canvasHeight)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        // Ignore hardware/bar container safe areas so `canvasWidth` equals the physical screen width
        // (`951pt` -> `475.5pt` midpoint on `duoOpen`), while preserving `.keyboard` safe-area avoidance!
        .ignoresSafeArea(.container)
    }

    // MARK: - 1. Stack Bottom Sheet (`30pt` Radius + Interactive 1:1 Drag Dismiss)

    private func stackBottomSheet(canvasWidth: CGFloat, canvasHeight: CGFloat) -> some View {
        let duoColumnWidth: CGFloat = metrics.posture == .duoClosed ? 91.0 : 84.0
        let rightClearance: CGFloat = metrics.hasRightSystemColumn
            ? max(metrics.safeAreaRight, duoColumnWidth) + 8.0
            : metrics.safeAreaRight + 8.0
        let leftClearance: CGFloat = metrics.safeAreaLeft + 8.0
        let availableWidth = max(260.0, canvasWidth - leftClearance - rightClearance)
        let sheetWidth = min(560.0, availableWidth)
        let maxSheetHeight = max(220.0, canvasHeight - metrics.safeAreaTop - 34.0)
        let bottomMargin = max(8.0, metrics.safeAreaBottom - 10.0)
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)

        return VStack(spacing: 0) {
            Spacer(minLength: metrics.safeAreaTop + 26.0)

            VStack(spacing: 0) {
                // Top grabber capsule (`overlays.css:99-107`)
                ZStack {
                    Capsule(style: .continuous)
                        .fill(CuvenColors.opaqueSeparator)
                        .frame(width: 32, height: 4)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 20)
                .contentShape(Rectangle())

                modalContent()
                    .frame(maxWidth: .infinity)
            }
            .frame(width: sheetWidth)
            .frame(height: tall ? maxSheetHeight : nil)
            .frame(maxHeight: maxSheetHeight)
            .background(CuvenColors.cardSurface, in: shape)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(CuvenColors.cardLine, lineWidth: 1.0)
            }
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.62 : 0.22),
                radius: 28,
                x: 0,
                y: 12
            )
            .onGeometryChange(for: CGFloat.self) { sheetGeo in
                sheetGeo.size.height
            } action: { newHeight in
                if newHeight > 40 {
                    measuredSheetHeight = newHeight
                }
            }
            .offset(y: dragOffsetY)
            .gesture(sheetDragDismissGesture)
            .padding(.leading, leftClearance)
            .padding(.trailing, rightClearance)
            .padding(.bottom, bottomMargin)
        }
        .accessibilityAddTraits(.isModal)
    }

    private var sheetDragDismissGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                let dy = value.translation.height
                let dx = value.translation.width
                if !isDraggingSheet {
                    guard abs(dy) > abs(dx) else { return }
                    isDraggingSheet = true
                    velocityTracker.reset()
                }
                velocityTracker.addSample(value.location)
                if dy >= 0 {
                    dragOffsetY = dy
                } else {
                    dragOffsetY = CuvenSprings.rubberBand(
                        overshoot: dy,
                        dimension: max(measuredSheetHeight, 240),
                        resistance: 0.55
                    )
                }
            }
            .onEnded { value in
                guard isDraggingSheet else { return }
                isDraggingSheet = false
                let trackedVelocityY = velocityTracker.velocity().y
                let predictedVelocityY = abs(trackedVelocityY) > 10
                    ? trackedVelocityY
                    : value.velocity.height

                let projectedY = max(0, dragOffsetY) + VelocityProjector.project(
                    velocity: predictedVelocityY,
                    decelerationRate: VelocityProjector.normalDecelerationRate
                )
                let dismissThreshold = max(measuredSheetHeight, 220) * 0.36

                if projectedY > dismissThreshold || predictedVelocityY > 950 {
                    CuvenHaptics.lightTap()
                    withAnimation(CuvenSprings.adaptive(CuvenSprings.sheetPresent, reduceMotion: reduceMotion)) {
                        isPresented = false
                        dragOffsetY = 0
                    }
                } else {
                    withAnimation(CuvenSprings.adaptive(CuvenSprings.sheetPresent, reduceMotion: reduceMotion)) {
                        dragOffsetY = 0
                    }
                }
                velocityTracker.reset()
            }
    }

    // MARK: - 2. Split / Duo Open Physical-Center (`475.5pt`) & Half-Book Originating-Half Card (`28pt` Radius)

    private func splitFloatingCard(canvasWidth: CGFloat, canvasHeight: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        let effectiveSafeRight: CGFloat = metrics.hasRightSystemColumn
            ? max(metrics.safeAreaRight, 84.0)
            : metrics.safeAreaRight
        let maxCardHeight = min(640.0, max(240.0, canvasHeight - metrics.safeAreaTop - 48.0))
        let isTrailingOrigin = originatesOnTrailingHalf(canvasWidth: canvasWidth)

        let geometry = computeSplitCardPlacement(
            canvasWidth: canvasWidth,
            safeLeft: metrics.safeAreaLeft,
            safeRight: effectiveSafeRight,
            originatesOnTrailingHalf: isTrailingOrigin
        )

        return modalContent()
            .frame(width: geometry.width)
            .frame(height: tall ? maxCardHeight : nil)
            .frame(maxHeight: maxCardHeight)
            .background(CuvenColors.cardSurface, in: shape)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(CuvenColors.cardLine, lineWidth: 1.0)
            }
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.70 : 0.20),
                radius: 30,
                x: 0,
                y: 16
            )
            .onGeometryChange(for: CGFloat.self) { cardGeo in
                cardGeo.size.height
            } action: { newHeight in
                if newHeight > 40 {
                    measuredSheetHeight = newHeight
                }
            }
            .offset(y: dragOffsetY)
            .gesture(sheetDragDismissGesture)
            .position(x: geometry.centerX, y: canvasHeight * 0.50)
            .accessibilityAddTraits(.isModal)
    }

    /// Computes exact horizontal card width & physical-screen midpoint X (`overlays.css:75-78`, `fold.css:11-14`, `design-qa.md:970-973`).
    private func computeSplitCardPlacement(
        canvasWidth: CGFloat,
        safeLeft: CGFloat,
        safeRight: CGFloat,
        originatesOnTrailingHalf: Bool
    ) -> (width: CGFloat, centerX: CGFloat) {
        // In `duoHalfBook`, keep the card strictly inside its originating half so it never crosses the hinge (`fold.css:11-14`).
        if metrics.posture == .duoHalfBook {
            let hingeMinX = metrics.hingeDivisionRect?.minX
                ?? (metrics.leadingColumnWidth > 0 ? metrics.leadingColumnWidth : canvasWidth * 0.485)
            let hingeMaxX = metrics.hingeDivisionRect?.maxX
                ?? min(canvasWidth, hingeMinX + 28.0)

            if originatesOnTrailingHalf {
                let regionLeft = hingeMaxX
                let regionRight = max(regionLeft + 240.0, canvasWidth - safeRight)
                let regionWidth = regionRight - regionLeft
                let cardWidth = min(480.0, max(240.0, regionWidth - 24.0))
                let centerX = regionLeft + regionWidth * 0.5
                return (cardWidth, centerX)
            } else {
                let regionLeft = safeLeft
                let regionWidth = max(260.0, hingeMinX - regionLeft)
                let cardWidth = min(480.0, max(240.0, regionWidth - 32.0))
                let centerX = regionLeft + regionWidth * 0.5
                return (cardWidth, centerX)
            }
        }

        // In `duoOpen` (`951×669pt` -> `475.5pt` midpoint) & `iPhoneSplit`, center on the physical screen midpoint
        // (`canvasWidth * 0.5`), clamped `8pt` clear of `safeLeft` and Duo's `84pt` `safeRight` column (`design-qa.md:971-973`).
        let usableWidth = max(260.0, canvasWidth - safeLeft - safeRight - 64.0)
        let maxTargetWidth: CGFloat = tall ? 520.0 : 480.0
        let cardWidth = min(maxTargetWidth, usableWidth)
        let minCenterX = safeLeft + 8.0 + cardWidth * 0.5
        let maxCenterX = max(minCenterX, canvasWidth - safeRight - 8.0 - cardWidth * 0.5)
        let physicalMidpoint = canvasWidth * 0.5
        let clampedCenterX = min(max(physicalMidpoint, minCenterX), maxCenterX)
        return (cardWidth, clampedCenterX)
    }

    private func dismissModal() {
        CuvenHaptics.lightTap()
        withAnimation(CuvenSprings.adaptive(CuvenSprings.sheetPresent, reduceMotion: reduceMotion)) {
            isPresented = false
        }
    }
}

// MARK: - Reusable Cuven Card Confirmation Dialog (`overlay.js` `openPrompt` Parity)

/// Blurred-backdrop confirmation & destructive guard card matching Web's `openPrompt` (`spec_miner_survey_2 §4.1`).
public struct CuvenCardDialogView: View {
    public let title: String
    public let message: String?
    public let primaryActionTitle: String
    public let isDestructive: Bool
    public let cancelTitle: String
    public let onConfirm: () -> Void
    public let onCancel: () -> Void

    public init(
        title: String,
        message: String? = nil,
        primaryActionTitle: String,
        isDestructive: Bool = false,
        cancelTitle: String = "Cancel",
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.primaryActionTitle = primaryActionTitle
        self.isDestructive = isDestructive
        self.cancelTitle = cancelTitle
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text(title)
                    .font(CuvenFonts.cappedTitle(weight: .bold))
                    .foregroundStyle(CuvenColors.inkPrimary)
                    .multilineTextAlignment(.center)

                if let message, !message.isEmpty {
                    Text(message)
                        .font(CuvenFonts.cappedSubheadline())
                        .foregroundStyle(CuvenColors.inkSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.top, 8)

            VStack(spacing: 10) {
                Button {
                    if isDestructive {
                        CuvenHaptics.rigidImpact()
                    } else {
                        CuvenHaptics.lightTap()
                    }
                    onConfirm()
                } label: {
                    Text(primaryActionTitle)
                        .font(CuvenFonts.cappedHeadline(weight: .semibold))
                        .foregroundStyle(isDestructive ? Color.white : CuvenColors.onCtaInk)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(
                            isDestructive ? CuvenColors.dangerRed : CuvenColors.ctaInk,
                            in: Capsule(style: .continuous)
                        )
                }
                .buttonStyle(.plain)

                Button {
                    CuvenHaptics.lightTap()
                    onCancel()
                } label: {
                    Text(cancelTitle)
                        .font(CuvenFonts.cappedBody(weight: .medium))
                        .foregroundStyle(CuvenColors.inkSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(22)
    }
}

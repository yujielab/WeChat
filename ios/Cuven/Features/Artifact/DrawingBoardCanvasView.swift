import SwiftUI
import UIKit
import CuvenCore

// MARK: - Native Velocity-Smoothed Drawing Board View (M10 — `PROJECT.md § 4, § 5.4, § 5.5`)
//
// Apple HIG & Developer Documentation Grounding:
// - Apple HIG › Direct Manipulation & Pencil/Touch Input: Zero-latency 1:1 stroke rendering,
//   standing brush nibs whose active tip reflects the selected ink color (`draw.js:41-47`),
//   full Undo/Redo/Clear stack, and non-nagging Discard Guard (`draw-guard.js:1-58`: empty board
//   closes immediately; inked board asks before discarding).
// - Apple HIG › Designing for iPhone Duo:
//   * Respects asymmetric right safe-area column (`safeRight >= 64pt` / `84pt` Open / `91pt` Closed)
//     so palette & dock controls never collide with `DuoRail` or `PagesCapsuleView`.
//   * Adapts into `duoHalfLaptop` tabletop split by keeping the paper canvas on the upper display
//     pane above `hingeDivisionRect` and placing brush/color/action controls on the lower deck.

public struct DrawingBoardCanvasView: View {
    private let store: AppStore
    private let roomID: String
    private let metrics: DuoLayoutMetrics
    @Binding private var hasUnsavedInk: Bool
    private let onClose: () -> Void

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @State private var document = DrawingDocumentState()
    @State private var activeStroke: DrawingStroke?
    @State private var selectedTool: DrawingBrushTool = .pen
    @State private var selectedColor: DrawingRGBAColor = .inkBlack
    @State private var customWheelColor: Color = Color(red: 0.345, green: 0.337, blue: 0.839)
    @State private var isCustomColorActive: Bool = false
    @State private var selectedStrokeSize: CGFloat = 6.0
    @State private var selectedPaperStyle: DrawingPaperStyle = .plain
    @State private var measuredCanvasSize: CGSize = CGSize(width: 360, height: 420)
    @State private var isSendingDrawing: Bool = false
    @State private var showDiscardAlert: Bool = false

    public init(
        store: AppStore,
        roomID: String,
        metrics: DuoLayoutMetrics,
        hasUnsavedInk: Binding<Bool> = .constant(false),
        onClose: @escaping () -> Void
    ) {
        self.store = store
        self.roomID = roomID
        self.metrics = metrics
        self._hasUnsavedInk = hasUnsavedInk
        self.onClose = onClose
    }

    // MARK: - Spatial Clearances

    private var trailingRailClearance: CGFloat {
        if metrics.hasRightSystemColumn {
            return max(metrics.safeAreaRight, metrics.railWidth + 24)
        }
        return max(12, metrics.safeAreaRight + 12)
    }

    private var leadingInset: CGFloat {
        max(12, metrics.safeAreaLeft + 12)
    }

    private var roomTitle: String {
        store.rooms.first(where: { $0.id == roomID })?.title ?? "Conversation"
    }

    public var body: some View {
        Group {
            if metrics.posture == .duoHalfLaptop, let hinge = metrics.hingeDivisionRect {
                laptopTabletopLayout(hingeRect: hinge)
            } else {
                standardColumnLayout
            }
        }
        .background(CuvenColors.elevatedSurface.ignoresSafeArea())
        .onChange(of: document.hasInk) { _, newValue in
            hasUnsavedInk = newValue
        }
        .onChange(of: roomID) { _, _ in
            // Switching rooms resets completed session if already clean
            if !document.hasInk {
                document.markSentAndReset()
            }
        }
        .alert("Discard drawing?", isPresented: $showDiscardAlert) {
            Button("Discard", role: .destructive) {
                CuvenHaptics.rigidImpact()
                document.markSentAndReset()
                hasUnsavedInk = false
                onClose()
            }
            Button("Cancel", role: .cancel) {
                CuvenHaptics.lightTap()
            }
        } message: {
            Text("Your unsent sketch on the drawing board will be lost.")
        }
    }

    // MARK: - Standard / Split / Folded Column Layout

    private var standardColumnLayout: some View {
        VStack(spacing: 10) {
            headerAndStationeryBar
                .padding(.top, max(10, metrics.safeAreaTop + 4))
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingRailClearance)

            if metrics.posture == .duoOpen {
                // On `duoOpen` (`426pt` Column 3), mount standing brushes vertically alongside the canvas
                HStack(spacing: 10) {
                    paperStageCard
                    verticalDuoOpenToolRail
                }
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingRailClearance)

                bottomActionDock
                    .padding(.leading, leadingInset)
                    .padding(.trailing, trailingRailClearance)
                    .padding(.bottom, max(12, metrics.safeAreaBottom + 6))
            } else {
                paperStageCard
                    .padding(.leading, leadingInset)
                    .padding(.trailing, trailingRailClearance)

                VStack(spacing: 10) {
                    brushAndColorPalette
                    bottomActionDock
                }
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingRailClearance)
                .padding(.bottom, max(12, metrics.safeAreaBottom + 6))
            }
        }
    }

    private var verticalDuoOpenToolRail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 6) {
                ForEach(DrawingBrushTool.allCases) { brush in
                    let isActive = selectedTool == brush
                    Button {
                        guard selectedTool != brush else { return }
                        CuvenHaptics.selectionChanged()
                        withAnimation(CuvenSprings.adaptive(CuvenSprings.pressBounce, reduceMotion: reduceMotion)) {
                            selectedTool = brush
                        }
                    } label: {
                        Image(systemName: brush.symbolName)
                            .font(.system(size: 16, weight: isActive ? .bold : .medium))
                            .foregroundStyle(
                                brush == .eraser
                                    ? Color(red: 0.94, green: 0.45, blue: 0.52)
                                    : (isActive ? selectedColor.swiftUIColor : CuvenColors.inkSecondary)
                            )
                            .frame(width: 44, height: 44)
                            .background(
                                isActive ? CuvenColors.paperBackground : Color.clear,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                            .overlay {
                                if isActive {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(selectedColor.swiftUIColor.opacity(0.45), lineWidth: 1.2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(brush.displayName)
                    .accessibilityAddTraits(isActive ? .isSelected : [])
                    .accessibilityIdentifier("drawing.tool.\(brush.rawValue)")
                }

                Divider()
                    .frame(width: 28)
                    .padding(.vertical, 2)

                ForEach(DrawingColorSwatch.presets) { swatch in
                    let isSelectedColor = !isCustomColorActive && selectedColor == swatch.color
                    Button {
                        CuvenHaptics.selectionChanged()
                        isCustomColorActive = false
                        selectedColor = swatch.color
                        if selectedTool == .eraser {
                            selectedTool = .pen
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(swatch.color.swiftUIColor)
                                .frame(width: 22, height: 22)
                            if isSelectedColor {
                                Circle()
                                    .strokeBorder(CuvenColors.inkPrimary, lineWidth: 2.0)
                                    .frame(width: 30, height: 30)
                            }
                        }
                        .frame(width: 44, height: 38)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(swatch.name)
                    .accessibilityAddTraits(isSelectedColor ? .isSelected : [])
                    .accessibilityIdentifier("drawing.color.\(swatch.id)")
                }

                ColorPicker(selection: $customWheelColor, supportsOpacity: false) {
                    EmptyView()
                }
                .labelsHidden()
                .frame(width: 44, height: 40)
                .onChange(of: customWheelColor) { _, picked in
                    isCustomColorActive = true
                    selectedColor = DrawingRGBAColor(swiftUIColor: picked)
                    if selectedTool == .eraser {
                        selectedTool = .pen
                    }
                }
                .accessibilityLabel("Custom ink color")
                .accessibilityIdentifier("drawing.color.wheel")
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
        }
        .frame(width: 54)
        .cuvenLiquidGlass(mode: store.prefs.glassMode, cornerRadius: 24)
    }

    // MARK: - Duo Half-Laptop Tabletop Split Layout (`metrics.hingeDivisionRect`)

    private func laptopTabletopLayout(hingeRect: CGRect) -> some View {
        GeometryReader { proxy in
            let upperHeight = max(180, min(hingeRect.minY, proxy.size.height * 0.56))
            let foldHeight = max(20, hingeRect.height)

            VStack(spacing: 0) {
                // Upper display pane above horizontal fold: pure uncluttered paper stage
                VStack(spacing: 6) {
                    HStack {
                        Text("Drawing board · \(roomTitle)")
                            .font(CuvenFonts.cappedSubheadline(weight: .semibold))
                            .foregroundStyle(CuvenColors.inkSecondary)
                        Spacer()
                    }
                    paperStageCard
                }
                .padding(.top, max(8, metrics.safeAreaTop + 2))
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingRailClearance)
                .padding(.bottom, 8)
                .frame(height: upperHeight)

                // Physical hinge crease spacer
                Color.clear
                    .frame(height: foldHeight)

                // Lower tabletop deck: stationery selector, standing pens, colors, Undo/Redo/Send
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 10) {
                        stationeryAndSizeStrip
                        brushAndColorPalette
                        bottomActionDock
                    }
                    .padding(.leading, leadingInset)
                    .padding(.trailing, trailingRailClearance)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: - Header & Stationery Strip (`Plain`, `Lines`, `Grid` + Stroke Sizes + Width Slider + `Clear`)

    private var headerAndStationeryBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Drawing board")
                        .font(CuvenFonts.cappedHeadline(weight: .bold))
                        .foregroundStyle(CuvenColors.inkPrimary)
                    Text("Sketch for \(roomTitle)")
                        .font(CuvenFonts.cappedCaption())
                        .foregroundStyle(CuvenColors.inkSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Button {
                    CuvenHaptics.rigidImpact()
                    document.clearAll()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Clear")
                            .font(CuvenFonts.cappedCaption(weight: .semibold))
                    }
                    .foregroundStyle(document.hasInk ? CuvenColors.dangerRedText : CuvenColors.inkTertiary)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 36)
                    .background(CuvenColors.paperBackground, in: Capsule())
                    .overlay(Capsule().strokeBorder(CuvenColors.cardLine, lineWidth: 0.8))
                }
                .buttonStyle(.plain)
                .disabled(!document.hasInk)
                .accessibilityLabel("Clear")
                .accessibilityIdentifier("drawing.clear")
            }

            stationeryAndSizeStrip
        }
        .cuvenCappedDynamicType()
    }

    private var stationeryAndSizeStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // 3 Paper styles directly accessible (`Plain`, `Lines`, `Grid` per `draw.js:30` & `testF7_03`)
                HStack(spacing: 4) {
                    ForEach(DrawingPaperStyle.allCases) { paper in
                        let isSelected = selectedPaperStyle == paper
                        Button {
                            guard selectedPaperStyle != paper else { return }
                            CuvenHaptics.selectionChanged()
                            withAnimation(CuvenSprings.adaptive(CuvenSprings.pressBounce, reduceMotion: reduceMotion)) {
                                selectedPaperStyle = paper
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: paper.symbolName)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(paper.shortLabel)
                                    .font(CuvenFonts.cappedCaption(weight: isSelected ? .semibold : .medium))
                            }
                            .foregroundStyle(isSelected ? CuvenColors.onCtaInk : CuvenColors.inkPrimary)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 36)
                            .background(
                                isSelected ? CuvenColors.ctaInk : CuvenColors.paperBackground,
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(paper.shortLabel)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .accessibilityIdentifier("drawing.paper.\(paper.rawValue)")
                    }
                }
                .padding(3)
                .background(CuvenColors.fieldBackground, in: Capsule())

                // 4 Stroke size presets (`3, 6, 12, 22` — `draw.js:20-21`) + continuous width slider
                HStack(spacing: 6) {
                    ForEach(DrawingCanvasRenderer.sizePresets, id: \.size) { preset in
                        let active = abs(selectedStrokeSize - preset.size) < 0.5
                        Button {
                            CuvenHaptics.selectionChanged()
                            selectedStrokeSize = preset.size
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(active ? CuvenColors.sidebarBlue.opacity(0.16) : Color.clear)
                                    .frame(width: 34, height: 34)
                                Circle()
                                    .fill(active ? CuvenColors.sidebarBlue : CuvenColors.inkPrimary)
                                    .frame(
                                        width: min(18, max(4, preset.size * 0.85)),
                                        height: min(18, max(4, preset.size * 0.85))
                                    )
                            }
                            .frame(width: 36, height: 36)
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(preset.label) stroke")
                        .accessibilityAddTraits(active ? .isSelected : [])
                        .accessibilityIdentifier("drawing.size.\(Int(preset.size))")
                    }

                    Slider(value: $selectedStrokeSize, in: 2...28, step: 1)
                        .frame(width: 84)
                        .tint(CuvenColors.sidebarBlue)
                        .accessibilityLabel("Brush width")
                        .accessibilityValue("\(Int(selectedStrokeSize)) points")
                        .accessibilityIdentifier("drawing.widthSlider")
                }
                .padding(.horizontal, 8)
                .background(CuvenColors.fieldBackground, in: Capsule())
            }
        }
    }

    // MARK: - Interactive Paper Stage (`artifact.drawingCanvas`)

    private var paperStageCard: some View {
        let stageShape = RoundedRectangle(cornerRadius: 22, style: .continuous)

        return GeometryReader { geo in
            let currentSize = CGSize(
                width: max(120, geo.size.width),
                height: max(120, geo.size.height)
            )

            Canvas(rendersAsynchronously: false) { context, size in
                DrawingCanvasRenderer.drawPaperBackground(
                    in: &context,
                    size: size,
                    paperStyle: selectedPaperStyle
                )
                DrawingCanvasRenderer.drawInkLayer(
                    strokes: document.strokes,
                    activeStroke: activeStroke,
                    in: &context
                )
            }
            .frame(width: currentSize.width, height: currentSize.height)
            .clipShape(stageShape)
            .overlay {
                stageShape.strokeBorder(
                    colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.08),
                    lineWidth: 1.0
                )
                .allowsHitTesting(false)
            }
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.36 : 0.07),
                radius: 10,
                x: 0,
                y: 4
            )
            .contentShape(stageShape)
            .gesture(drawingGesture(stageSize: currentSize))
            .onAppear {
                measuredCanvasSize = currentSize
            }
            .onChange(of: geo.size) { _, nextSize in
                if nextSize.width > 40 && nextSize.height > 40 {
                    measuredCanvasSize = nextSize
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.allowsDirectInteraction)
            .accessibilityLabel("Drawing canvas")
            .accessibilityValue(document.hasInk ? "\(document.strokes.count) strokes" : "Blank \(selectedPaperStyle.displayName) paper")
            .accessibilityIdentifier("artifact.drawingCanvas")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func drawingGesture(stageSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let clampedLocation = CGPoint(
                    x: min(max(0, value.location.x), stageSize.width),
                    y: min(max(0, value.location.y), stageSize.height)
                )
                let nowMs = Date().timeIntervalSinceReferenceDate * 1000.0

                if var existing = activeStroke {
                    existing.appendSample(location: clampedLocation, timestampMs: nowMs)
                    activeStroke = existing
                } else {
                    var started = DrawingStroke(
                        tool: selectedTool,
                        color: selectedColor,
                        baseSize: selectedStrokeSize,
                        points: []
                    )
                    started.appendSample(location: clampedLocation, timestampMs: nowMs)
                    activeStroke = started
                }
            }
            .onEnded { value in
                let clampedLocation = CGPoint(
                    x: min(max(0, value.location.x), stageSize.width),
                    y: min(max(0, value.location.y), stageSize.height)
                )
                let nowMs = Date().timeIntervalSinceReferenceDate * 1000.0

                if var finishing = activeStroke {
                    finishing.appendSample(location: clampedLocation, timestampMs: nowMs)
                    document.commitStroke(finishing)
                }
                activeStroke = nil
                hasUnsavedInk = document.hasInk
            }
    }

    // MARK: - Standing Pens & Color Wheel Capsule (`draw.js:40-68`)

    private var brushAndColorPalette: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                // 5 Standing Brush Nibs (`Pen`, `Marker`, `Highlighter`, `Pencil`, `Eraser`)
                HStack(spacing: 4) {
                    ForEach(DrawingBrushTool.allCases) { brush in
                        let isActive = selectedTool == brush
                        let effectiveWidth = Int(round(selectedStrokeSize * brush.widthMultiplier))
                        Button {
                            guard selectedTool != brush else { return }
                            CuvenHaptics.selectionChanged()
                            withAnimation(CuvenSprings.adaptive(CuvenSprings.pressBounce, reduceMotion: reduceMotion)) {
                                selectedTool = brush
                            }
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: brush.symbolName)
                                    .font(.system(size: 16, weight: isActive ? .bold : .medium))
                                    .foregroundStyle(
                                        brush == .eraser
                                            ? Color(red: 0.94, green: 0.45, blue: 0.52)
                                            : (isActive ? selectedColor.swiftUIColor : CuvenColors.inkSecondary)
                                    )
                                Text("\(effectiveWidth)")
                                    .font(CuvenFonts.cappedCaption2(weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(isActive ? CuvenColors.inkPrimary : CuvenColors.inkTertiary)
                            }
                            .frame(minWidth: 44, minHeight: 46)
                            .background(
                                isActive
                                    ? CuvenColors.paperBackground
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                            .overlay {
                                if isActive {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(selectedColor.swiftUIColor.opacity(0.45), lineWidth: 1.2)
                                }
                            }
                            .offset(y: isActive && !reduceMotion ? -3 : 0)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(brush.displayName)
                        .accessibilityAddTraits(isActive ? .isSelected : [])
                        .accessibilityIdentifier("drawing.tool.\(brush.rawValue)")
                    }
                }

                Rectangle()
                    .fill(CuvenColors.hairlineSeparator)
                    .frame(width: 1, height: 28)

                // Preset Color Swatches + System ColorPicker Wheel
                HStack(spacing: 6) {
                    ForEach(DrawingColorSwatch.presets) { swatch in
                        let isSelectedColor = !isCustomColorActive && selectedColor == swatch.color
                        Button {
                            CuvenHaptics.selectionChanged()
                            isCustomColorActive = false
                            selectedColor = swatch.color
                            // Picking a color while Eraser is held switches back to Pen (`draw.js:243`)
                            if selectedTool == .eraser {
                                selectedTool = .pen
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(swatch.color.swiftUIColor)
                                    .frame(width: 24, height: 24)
                                if isSelectedColor {
                                    Circle()
                                        .strokeBorder(CuvenColors.inkPrimary, lineWidth: 2.0)
                                        .frame(width: 32, height: 32)
                                }
                            }
                            .frame(width: 38, height: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(swatch.name)
                        .accessibilityAddTraits(isSelectedColor ? .isSelected : [])
                        .accessibilityIdentifier("drawing.color.\(swatch.id)")
                    }

                    ColorPicker(selection: $customWheelColor, supportsOpacity: false) {
                        EmptyView()
                    }
                    .labelsHidden()
                    .frame(width: 36, height: 44)
                    .onChange(of: customWheelColor) { _, picked in
                        isCustomColorActive = true
                        selectedColor = DrawingRGBAColor(swiftUIColor: picked)
                        if selectedTool == .eraser {
                            selectedTool = .pen
                        }
                    }
                    .accessibilityLabel("Custom ink color")
                    .accessibilityIdentifier("drawing.color.wheel")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .cuvenLiquidGlass(mode: store.prefs.glassMode, cornerRadius: 24)
        .cuvenCappedDynamicType()
    }

    // MARK: - Bottom Action Dock (`Close` | `Undo / Redo` | `Send`)

    private var bottomActionDock: some View {
        HStack(spacing: 10) {
            // Leading Close / Back button (with Discard Guard when board has ink)
            Button {
                requestCloseBoard()
            } label: {
                Image(systemName: metrics.visibleColumnCount == 1 ? "chevron.left" : "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CuvenColors.inkPrimary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.cuvenGlassPill(mode: store.prefs.glassMode, cornerRadius: 22, triggersHaptic: true))
            .accessibilityLabel(metrics.visibleColumnCount == 1 ? "Back" : "Close")
            .accessibilityIdentifier("drawing.close")

            Spacer(minLength: 4)

            // Center Undo / Redo Liquid Glass capsule (`draw.js:69-75`)
            HStack(spacing: 2) {
                Button {
                    CuvenHaptics.lightTap()
                    document.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(document.canUndo ? CuvenColors.inkPrimary : CuvenColors.inkTertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!document.canUndo)
                .accessibilityLabel("Undo")
                .accessibilityIdentifier("drawing.undo")

                Rectangle()
                    .fill(CuvenColors.hairlineSeparator)
                    .frame(width: 0.6, height: 20)

                Button {
                    CuvenHaptics.lightTap()
                    document.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(document.canRedo ? CuvenColors.inkPrimary : CuvenColors.inkTertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!document.canRedo)
                .accessibilityLabel("Redo")
                .accessibilityIdentifier("drawing.redo")
            }
            .padding(.horizontal, 4)
            .cuvenLiquidGlass(mode: store.prefs.glassMode, cornerRadius: 22)

            Spacer(minLength: 4)

            // Trailing solid Ink `Send` CTA (`draw.js:72, 265-273`)
            Button {
                Task {
                    await exportAndSendDrawing()
                }
            } label: {
                HStack(spacing: 6) {
                    if isSendingDrawing {
                        ProgressView()
                            .tint(CuvenColors.onCtaInk)
                            .scaleEffect(0.85)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                    }
                    Text("Send")
                        .font(CuvenFonts.cappedSubheadline(weight: .semibold))
                }
                .foregroundStyle(document.hasInk ? CuvenColors.onCtaInk : CuvenColors.inkTertiary)
                .padding(.horizontal, 18)
                .frame(minWidth: 88, minHeight: 44)
                .background(
                    document.hasInk ? CuvenColors.ctaInk : CuvenColors.fieldBackground,
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
            .disabled(!document.hasInk || isSendingDrawing)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("drawing.send")
        }
        .cuvenCappedDynamicType()
    }

    // MARK: - Actions

    private func requestCloseBoard() {
        if document.hasInk {
            CuvenHaptics.warning()
            showDiscardAlert = true
        } else {
            CuvenHaptics.lightTap()
            onClose()
        }
    }

    @MainActor
    private func exportAndSendDrawing() async {
        guard document.hasInk, !isSendingDrawing else { return }
        isSendingDrawing = true
        defer { isSendingDrawing = false }

        guard let exported = DrawingCanvasRenderer.exportPNGData(
            strokes: document.strokes,
            canvasSize: measuredCanvasSize,
            displayScale: displayScale
        ) else {
            CuvenHaptics.error()
            return
        }

        await store.sendDrawing(
            roomID: roomID,
            pngData: exported.data,
            size: exported.pixelSize
        )
        document.markSentAndReset()
        hasUnsavedInk = false
        CuvenHaptics.success()
        onClose()
    }
}

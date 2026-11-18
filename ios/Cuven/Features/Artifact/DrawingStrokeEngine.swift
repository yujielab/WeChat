import SwiftUI
import UIKit
import CuvenCore

// MARK: - Velocity-Smoothed Drawing Board Engine (M10)
//
// Apple HIG & Developer Documentation Grounding:
// - Apple HIG › Gestures & Apple Pencil / Direct Manipulation: Immediate 1:1 stroke tracking
//   with zero artificial latency, coalesced velocity modulation, and clear undo/redo affordance.
// - Apple Developer Documentation › SwiftUI `Canvas`, `GraphicsContext`, `ImageRenderer` (iOS 27.1 SDK):
//   Isolated ink layer (`drawLayer`) enables true `.destinationOut` erasing over decorative paper
//   guides without painting opaque white, and uniform `.multiply` alpha compositing for Highlighter
//   bands (`public/js/views/draw.js:23-29, 125-186`, `public/css/draw.css:148-208`).

/// Five authentic Cuven drawing brushes matching `public/js/views/draw.js:23-29`.
public enum DrawingBrushTool: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case pen
    case marker
    case highlighter
    case pencil
    case eraser

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pen: return "Pen"
        case .marker: return "Marker"
        case .highlighter: return "Highlighter"
        case .pencil: return "Pencil"
        case .eraser: return "Eraser"
        }
    }

    public var symbolName: String {
        switch self {
        case .pen: return "pencil.tip"
        case .marker: return "paintbrush.pointed.fill"
        case .highlighter: return "highlighter"
        case .pencil: return "pencil"
        case .eraser: return "eraser.fill"
        }
    }

    /// Width multiplier relative to base stroke size (`draw.js:23-29`).
    public var widthMultiplier: CGFloat {
        switch self {
        case .pen: return 1.0
        case .marker: return 2.2
        case .highlighter: return 4.0
        case .pencil: return 0.72
        case .eraser: return 3.5
        }
    }

    /// Intrinsic stroke opacity (`draw.js:23-29`).
    public var intrinsicOpacity: Double {
        switch self {
        case .pen: return 1.0
        case .marker: return 1.0
        case .highlighter: return 0.35
        case .pencil: return 0.82
        case .eraser: return 1.0
        }
    }

    public var usesVelocityModulation: Bool {
        switch self {
        case .pen, .pencil: return true
        case .marker, .highlighter, .eraser: return false
        }
    }
}

/// Three stationery paper backgrounds matching `public/js/views/draw.js:30` & `public/css/draw.css:150-154`.
public enum DrawingPaperStyle: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case plain
    case ruledLines
    case grid

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .plain: return "Plain"
        case .ruledLines: return "Ruled Lines"
        case .grid: return "Dot/Square Grid"
        }
    }

    public var shortLabel: String {
        switch self {
        case .plain: return "Plain"
        case .ruledLines: return "Lines"
        case .grid: return "Grid"
        }
    }

    public var symbolName: String {
        switch self {
        case .plain: return "doc"
        case .ruledLines: return "text.justify"
        case .grid: return "squareshape.split.3x3"
        }
    }
}

/// Pure value-type sRGB color representation for `Sendable` / `Codable` stroke storage.
public struct DrawingRGBAColor: Codable, Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = min(1, max(0, red))
        self.green = min(1, max(0, green))
        self.blue = min(1, max(0, blue))
        self.alpha = min(1, max(0, alpha))
    }

    public init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: alpha)
    }

    public init(swiftUIColor: Color) {
        let uiColor = UIColor(swiftUIColor)
        var r: CGFloat = 0.094
        var g: CGFloat = 0.094
        var b: CGFloat = 0.106
        var a: CGFloat = 1.0
        if uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) {
            self.init(red: Double(r), green: Double(g), blue: Double(b), alpha: Double(a))
        } else {
            self.init(hex: 0x18181B)
        }
    }

    public var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    public var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    public static let inkBlack = DrawingRGBAColor(hex: 0x18181B)
    public static let cuvenBlue = DrawingRGBAColor(hex: 0x007AFF)
    public static let emeraldGreen = DrawingRGBAColor(hex: 0x34C759)
    public static let sunYellow = DrawingRGBAColor(hex: 0xFFCC00)
    public static let vermilionRed = DrawingRGBAColor(hex: 0xFF3B30)
    public static let electricPurple = DrawingRGBAColor(hex: 0x5856D6)
}

/// Curated palette swatches matching `public/js/views/draw.js:16-19` plus Violet accent.
public struct DrawingColorSwatch: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let color: DrawingRGBAColor

    public static let presets: [DrawingColorSwatch] = [
        DrawingColorSwatch(id: "black", name: "Ink Black", color: .inkBlack),
        DrawingColorSwatch(id: "blue", name: "Blue", color: .cuvenBlue),
        DrawingColorSwatch(id: "green", name: "Green", color: .emeraldGreen),
        DrawingColorSwatch(id: "yellow", name: "Yellow", color: .sunYellow),
        DrawingColorSwatch(id: "red", name: "Red", color: .vermilionRed),
        DrawingColorSwatch(id: "purple", name: "Indigo", color: .electricPurple)
    ]
}

/// Single timestamped sample along a drawing gesture with velocity-modulated stroke width.
public struct DrawingSamplePoint: Codable, Equatable, Hashable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    /// Milliseconds since reference epoch.
    public var timestampMs: Double
    /// Exponentially smoothed stroke width at this sample (`draw.js:160-164`).
    public var width: CGFloat

    public init(x: CGFloat, y: CGFloat, timestampMs: Double, width: CGFloat) {
        self.x = x
        self.y = y
        self.timestampMs = timestampMs
        self.width = width
    }

    public var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

/// Immutable vector stroke supporting Catmull-Rom / quadratic Bezier midpoint rendering.
public struct DrawingStroke: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var seed: UInt64
    public var tool: DrawingBrushTool
    public var color: DrawingRGBAColor
    public var baseSize: CGFloat
    public var points: [DrawingSamplePoint]

    public init(
        id: UUID = UUID(),
        seed: UInt64 = UInt64.random(in: 1...UInt64.max),
        tool: DrawingBrushTool,
        color: DrawingRGBAColor,
        baseSize: CGFloat,
        points: [DrawingSamplePoint]
    ) {
        self.id = id
        self.seed = seed
        self.tool = tool
        self.color = color
        self.baseSize = baseSize
        self.points = points
    }

    public var nominalWidth: CGFloat {
        max(1.0, baseSize * tool.widthMultiplier)
    }

    /// Appends a raw touch/pencil coordinate and computes velocity-smoothed width (`draw.js:157-164`).
    public mutating func appendSample(location: CGPoint, timestampMs: Double) {
        let base = nominalWidth
        guard let previous = points.last else {
            points.append(DrawingSamplePoint(x: location.x, y: location.y, timestampMs: timestampMs, width: base))
            return
        }

        let dx = location.x - previous.x
        let dy = location.y - previous.y
        let distance = hypot(dx, dy)
        // Coalesce sub-half-pixel jitter while preserving initial tap dab
        if distance < 0.35 && points.count > 1 {
            return
        }

        let dt = max(1.0, timestampMs - previous.timestampMs)
        let nextWidth: CGFloat
        if tool.usesVelocityModulation {
            let speedPtPerMs = CGFloat(Double(distance) / dt)
            let minRatio: CGFloat = tool == .pen ? 0.45 : 0.62
            let maxRatio: CGFloat = tool == .pen ? 1.30 : 1.12
            let target = max(base * minRatio, base * (maxRatio - min(1.0, speedPtPerMs * 0.60)))
            nextWidth = previous.width + (target - previous.width) * 0.30
        } else {
            nextWidth = base
        }

        points.append(DrawingSamplePoint(
            x: location.x,
            y: location.y,
            timestampMs: timestampMs,
            width: nextWidth
        ))
    }
}

/// Undoable canvas state machine preserving ink history across strokes AND `Clear` operations (`draw.js:192-234`).
public struct DrawingDocumentState: Equatable, Sendable {
    private struct HistorySnapshot: Equatable, Sendable {
        let strokes: [DrawingStroke]
    }

    public private(set) var strokes: [DrawingStroke] = []
    private var undoSnapshots: [HistorySnapshot] = []
    private var redoSnapshots: [HistorySnapshot] = []
    private let maxHistoryDepth: Int = 36

    public init() {}

    /// True when at least one non-eraser stroke currently exists on the board.
    public var hasInk: Bool {
        strokes.contains { $0.tool != .eraser && !$0.points.isEmpty }
    }

    public var canUndo: Bool {
        !undoSnapshots.isEmpty
    }

    public var canRedo: Bool {
        !redoSnapshots.isEmpty
    }

    public mutating func commitStroke(_ stroke: DrawingStroke) {
        guard !stroke.points.isEmpty else { return }
        // Erasing an already blank board is a no-op so it doesn't falsely mark dirty.
        if stroke.tool == .eraser && !hasInk {
            return
        }
        pushUndoSnapshot()
        redoSnapshots.removeAll()
        strokes.append(stroke)
    }

    public mutating func undo() {
        guard let previous = undoSnapshots.popLast() else { return }
        redoSnapshots.append(HistorySnapshot(strokes: strokes))
        strokes = previous.strokes
    }

    public mutating func redo() {
        guard let next = redoSnapshots.popLast() else { return }
        undoSnapshots.append(HistorySnapshot(strokes: strokes))
        strokes = next.strokes
    }

    public mutating func clearAll() {
        guard !strokes.isEmpty else { return }
        pushUndoSnapshot()
        redoSnapshots.removeAll()
        strokes.removeAll()
    }

    public mutating func markSentAndReset() {
        strokes.removeAll()
        undoSnapshots.removeAll()
        redoSnapshots.removeAll()
    }

    private mutating func pushUndoSnapshot() {
        undoSnapshots.append(HistorySnapshot(strokes: strokes))
        if undoSnapshots.count > maxHistoryDepth {
            undoSnapshots.removeFirst(undoSnapshots.count - maxHistoryDepth)
        }
    }
}

// MARK: - High-Frame-Rate Canvas & CoreGraphics Export Renderer

public enum DrawingCanvasRenderer {
    /// Preset quick stroke sizes matching `public/js/views/draw.js:20-21`.
    public static let sizePresets: [(size: CGFloat, label: String)] = [
        (3, "Thin"),
        (6, "Medium"),
        (12, "Thick"),
        (22, "Extra thick")
    ]

    /// Draws paper background (`Plain`, `Ruled Lines`, `Dot/Square Grid`) onto a SwiftUI `GraphicsContext`.
    public static func drawPaperBackground(
        in context: inout GraphicsContext,
        size: CGSize,
        paperStyle: DrawingPaperStyle
    ) {
        let fullRect = CGRect(origin: .zero, size: size)
        context.fill(Path(fullRect), with: .color(.white))

        switch paperStyle {
        case .plain:
            break

        case .ruledLines:
            var ruledPath = Path()
            let lineSpacing: CGFloat = 38
            var y: CGFloat = lineSpacing
            while y < size.height {
                ruledPath.move(to: CGPoint(x: 0, y: y))
                ruledPath.addLine(to: CGPoint(x: size.width, y: y))
                y += lineSpacing
            }
            context.stroke(
                ruledPath,
                with: .color(Color(.sRGB, red: 90 / 255, green: 110 / 255, blue: 150 / 255, opacity: 0.18)),
                lineWidth: 1
            )

            // Subtle stationery margin guide
            var marginPath = Path()
            let marginX = min(44, size.width * 0.12)
            marginPath.move(to: CGPoint(x: marginX, y: 0))
            marginPath.addLine(to: CGPoint(x: marginX, y: size.height))
            context.stroke(
                marginPath,
                with: .color(Color(.sRGB, red: 220 / 255, green: 110 / 255, blue: 120 / 255, opacity: 0.16)),
                lineWidth: 1
            )

        case .grid:
            let step: CGFloat = 28
            var gridPath = Path()
            var dotPath = Path()
            var x: CGFloat = step
            while x < size.width {
                gridPath.move(to: CGPoint(x: x, y: 0))
                gridPath.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y: CGFloat = step
            while y < size.height {
                gridPath.move(to: CGPoint(x: 0, y: y))
                gridPath.addLine(to: CGPoint(x: size.width, y: y))
                var ix: CGFloat = step
                while ix < size.width {
                    dotPath.addEllipse(in: CGRect(x: ix - 1.1, y: y - 1.1, width: 2.2, height: 2.2))
                    ix += step
                }
                y += step
            }
            context.stroke(
                gridPath,
                with: .color(Color(.sRGB, red: 90 / 255, green: 110 / 255, blue: 150 / 255, opacity: 0.12)),
                lineWidth: 0.85
            )
            context.fill(
                dotPath,
                with: .color(Color(.sRGB, red: 75 / 255, green: 95 / 255, blue: 138 / 255, opacity: 0.24))
            )
        }
    }

    /// Renders committed strokes plus an in-flight active stroke inside an isolated ink compositing layer.
    public static func drawInkLayer(
        strokes: [DrawingStroke],
        activeStroke: DrawingStroke?,
        in context: inout GraphicsContext
    ) {
        context.drawLayer { inkLayer in
            for stroke in strokes {
                renderSingleStroke(stroke, in: &inkLayer)
            }
            if let activeStroke {
                renderSingleStroke(activeStroke, in: &inkLayer)
            }
        }
    }

    private static func renderSingleStroke(
        _ stroke: DrawingStroke,
        in context: inout GraphicsContext
    ) {
        guard let first = stroke.points.first else { return }

        switch stroke.tool {
        case .eraser:
            var eraserCtx = context
            eraserCtx.blendMode = .destinationOut
            let path = smoothMidpointBezierPath(for: stroke.points)
            if stroke.points.count == 1 {
                let r = stroke.nominalWidth * 0.5
                let dab = Path(ellipseIn: CGRect(x: first.x - r, y: first.y - r, width: r * 2, height: r * 2))
                eraserCtx.fill(dab, with: .color(.black))
            } else {
                eraserCtx.stroke(
                    path,
                    with: .color(.black),
                    style: StrokeStyle(lineWidth: stroke.nominalWidth, lineCap: .round, lineJoin: .round)
                )
            }

        case .highlighter:
            // Uniform single-pass translucent chisel band with multiply blend (`draw.js:126-154, 176-183`).
            var bandOuter = context
            bandOuter.blendMode = .multiply
            bandOuter.opacity = stroke.tool.intrinsicOpacity * stroke.color.alpha
            bandOuter.drawLayer { bandLayer in
                let opaqueTint = Color(.sRGB, red: stroke.color.red, green: stroke.color.green, blue: stroke.color.blue, opacity: 1.0)
                if stroke.points.count == 1 {
                    let w = stroke.nominalWidth
                    let h = max(4, w * 0.45)
                    let chisel = Path(roundedRect: CGRect(x: first.x - w * 0.5, y: first.y - h * 0.5, width: w, height: h), cornerRadius: 2)
                    bandLayer.fill(chisel, with: .color(opaqueTint))
                } else {
                    let path = smoothMidpointBezierPath(for: stroke.points)
                    bandLayer.stroke(
                        path,
                        with: .color(opaqueTint),
                        style: StrokeStyle(lineWidth: stroke.nominalWidth, lineCap: .butt, lineJoin: .round)
                    )
                }
            }

        case .marker:
            let tint = stroke.color.swiftUIColor
            if stroke.points.count == 1 {
                let r = stroke.nominalWidth * 0.5
                let dab = Path(ellipseIn: CGRect(x: first.x - r, y: first.y - r, width: r * 2, height: r * 2))
                context.fill(dab, with: .color(tint))
            } else {
                let path = smoothMidpointBezierPath(for: stroke.points)
                context.stroke(
                    path,
                    with: .color(tint),
                    style: StrokeStyle(lineWidth: stroke.nominalWidth, lineCap: .round, lineJoin: .round)
                )
            }

        case .pen:
            renderVelocityModulatedPen(stroke, in: &context)

        case .pencil:
            renderTexturedPencil(stroke, in: &context)
        }
    }

    /// Catmull-Rom / quadratic Bezier midpoint variable-width fountain/gel pen renderer.
    private static func renderVelocityModulatedPen(
        _ stroke: DrawingStroke,
        in context: inout GraphicsContext
    ) {
        let pts = stroke.points
        guard let first = pts.first else { return }
        let tint = stroke.color.swiftUIColor

        if pts.count == 1 {
            let r = first.width * 0.5
            context.fill(
                Path(ellipseIn: CGRect(x: first.x - r, y: first.y - r, width: r * 2, height: r * 2)),
                with: .color(tint)
            )
            return
        }

        if pts.count == 2 {
            var seg = Path()
            seg.move(to: pts[0].cgPoint)
            seg.addLine(to: pts[1].cgPoint)
            context.stroke(
                seg,
                with: .color(tint),
                style: StrokeStyle(lineWidth: (pts[0].width + pts[1].width) * 0.5, lineCap: .round, lineJoin: .round)
            )
            return
        }

        // Subdivide each quadratic midpoint curve so width transitions seamlessly with pointer speed.
        var prevMid = CGPoint(
            x: (pts[0].x + pts[1].x) * 0.5,
            y: (pts[0].y + pts[1].y) * 0.5
        )
        // Leading segment from start point to first midpoint
        var leadPath = Path()
        leadPath.move(to: pts[0].cgPoint)
        leadPath.addLine(to: prevMid)
        context.stroke(
            leadPath,
            with: .color(tint),
            style: StrokeStyle(lineWidth: (pts[0].width + pts[1].width) * 0.5, lineCap: .round, lineJoin: .round)
        )

        for idx in 1..<(pts.count - 1) {
            let control = pts[idx].cgPoint
            let next = pts[idx + 1].cgPoint
            let nextMid = CGPoint(x: (control.x + next.x) * 0.5, y: (control.y + next.y) * 0.5)
            let wStart = (pts[idx - 1].width + pts[idx].width) * 0.5
            let wEnd = (pts[idx].width + pts[idx + 1].width) * 0.5

            let chord = hypot(nextMid.x - prevMid.x, nextMid.y - prevMid.y)
            let subdivisions = max(1, min(6, Int(ceil(chord / 6.0))))
            var lastSubPoint = prevMid

            for step in 1...subdivisions {
                let t = CGFloat(step) / CGFloat(subdivisions)
                let omt = 1.0 - t
                let qx = omt * omt * prevMid.x + 2.0 * omt * t * control.x + t * t * nextMid.x
                let qy = omt * omt * prevMid.y + 2.0 * omt * t * control.y + t * t * nextMid.y
                let subPoint = CGPoint(x: qx, y: qy)
                let subWidth = wStart + (wEnd - wStart) * t

                var subPath = Path()
                subPath.move(to: lastSubPoint)
                subPath.addLine(to: subPoint)
                context.stroke(
                    subPath,
                    with: .color(tint),
                    style: StrokeStyle(lineWidth: subWidth, lineCap: .round, lineJoin: .round)
                )
                lastSubPoint = subPoint
            }
            prevMid = nextMid
        }

        // Trailing segment to final touch sample
        if let last = pts.last {
            var tailPath = Path()
            tailPath.move(to: prevMid)
            tailPath.addLine(to: last.cgPoint)
            context.stroke(
                tailPath,
                with: .color(tint),
                style: StrokeStyle(lineWidth: last.width, lineCap: .round, lineJoin: .round)
            )
        }
    }

    /// Deterministic toothy graphite pencil renderer combining a soft core spline with arc-length seeded paper grain.
    private static func renderTexturedPencil(
        _ stroke: DrawingStroke,
        in context: inout GraphicsContext
    ) {
        let pts = stroke.points
        guard let first = pts.first else { return }

        let coreColor = Color(
            .sRGB,
            red: stroke.color.red,
            green: stroke.color.green,
            blue: stroke.color.blue,
            opacity: stroke.color.alpha * 0.46
        )
        let grainColor = Color(
            .sRGB,
            red: stroke.color.red,
            green: stroke.color.green,
            blue: stroke.color.blue,
            opacity: stroke.color.alpha * 0.68
        )

        if pts.count == 1 {
            let r = max(1.2, first.width * 0.55)
            context.fill(
                Path(ellipseIn: CGRect(x: first.x - r, y: first.y - r, width: r * 2, height: r * 2)),
                with: .color(grainColor)
            )
            return
        }

        let corePath = smoothMidpointBezierPath(for: pts)
        context.stroke(
            corePath,
            with: .color(coreColor),
            style: StrokeStyle(lineWidth: max(1.0, stroke.nominalWidth * 0.78), lineCap: .round, lineJoin: .round)
        )

        // Deterministic micro-grain stipple along stroke arc length (zero temporal flicker).
        var grainPath = Path()
        var grainIndex: UInt64 = 0
        let maxGrainDots = 1_400

        outerLoop: for i in 1..<pts.count {
            let a = pts[i - 1]
            let b = pts[i]
            let dx = b.x - a.x
            let dy = b.y - a.y
            let segLen = hypot(dx, dy)
            guard segLen > 0.1 else { continue }

            let steps = max(1, Int(ceil(segLen / 1.8)))
            for s in 0..<steps {
                if grainIndex >= maxGrainDots { break outerLoop }
                let t = CGFloat(s) / CGFloat(steps)
                let cx = a.x + dx * t
                let cy = a.y + dy * t
                let localRadius = max(1.0, (a.width + (b.width - a.width) * t) * 0.65)

                for fleck in 0..<2 {
                    let h1 = splitMix64(stroke.seed &+ grainIndex &* 31 &+ UInt64(fleck) &* 131)
                    let h2 = splitMix64(h1 ^ 0x9E37_79B9_7F4A_7C15)
                    let angle = Double(h1 & 0xFFFF) / 65535.0 * (.pi * 2.0)
                    let radial = sqrt(Double((h1 >> 16) & 0xFFFF) / 65535.0) * Double(localRadius)
                    let dotSize = CGFloat(0.75 + (Double(h2 & 0xFF) / 255.0) * Double(min(2.2, localRadius * 0.55)))
                    let gx = cx + CGFloat(cos(angle) * radial)
                    let gy = cy + CGFloat(sin(angle) * radial)
                    grainPath.addEllipse(in: CGRect(
                        x: gx - dotSize * 0.5,
                        y: gy - dotSize * 0.5,
                        width: dotSize,
                        height: dotSize
                    ))
                }
                grainIndex &+= 1
            }
        }

        context.fill(grainPath, with: .color(grainColor))
    }

    /// Quadratic Bezier curve through consecutive midpoints (`draw.js:165-171`).
    public static func smoothMidpointBezierPath(for points: [DrawingSamplePoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first.cgPoint)
        guard points.count > 1 else { return path }

        if points.count == 2 {
            path.addLine(to: points[1].cgPoint)
            return path
        }

        let firstMid = CGPoint(
            x: (points[0].x + points[1].x) * 0.5,
            y: (points[0].y + points[1].y) * 0.5
        )
        path.addLine(to: firstMid)

        for idx in 1..<(points.count - 1) {
            let control = points[idx].cgPoint
            let next = points[idx + 1].cgPoint
            let mid = CGPoint(x: (control.x + next.x) * 0.5, y: (control.y + next.y) * 0.5)
            path.addQuadCurve(to: mid, control: control)
        }

        if let last = points.last {
            path.addLine(to: last.cgPoint)
        }
        return path
    }

    private static func splitMix64(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Exports crisp `#FFFFFF` white-paper PNG via SwiftUI `ImageRenderer` (with CoreGraphics fallback).
    /// Paper lines/grid are intentionally excluded from the exported image, matching `public/css/draw.css:149`.
    @MainActor
    public static func exportPNGData(
        strokes: [DrawingStroke],
        canvasSize: CGSize,
        displayScale: CGFloat = 3.0
    ) -> (data: Data, pixelSize: CGSize)? {
        let width = max(240, round(canvasSize.width))
        let height = max(240, round(canvasSize.height))
        let targetSize = CGSize(width: width, height: height)
        let scale = min(3.0, max(2.0, displayScale))

        let exportView = Canvas(rendersAsynchronously: false) { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            drawInkLayer(strokes: strokes, activeStroke: nil, in: &context)
        }
        .frame(width: targetSize.width, height: targetSize.height)

        let renderer = ImageRenderer(content: exportView)
        renderer.scale = scale
        renderer.isOpaque = true

        if let uiImage = renderer.uiImage, let png = uiImage.pngData(), !png.isEmpty {
            return (png, CGSize(width: targetSize.width * scale, height: targetSize.height * scale))
        }

        // Deterministic CoreGraphics fallback for headless Simulator / offscreen contexts
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let fallbackRenderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let fallbackPNG = fallbackRenderer.pngData { cgRendererContext in
            let cg = cgRendererContext.cgContext
            cg.setFillColor(UIColor.white.cgColor)
            cg.fill(CGRect(origin: .zero, size: targetSize))

            cg.saveGState()
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            for stroke in strokes {
                guard !stroke.points.isEmpty else { continue }
                let bezierPath = smoothMidpointBezierPath(for: stroke.points).cgPath
                cg.saveGState()
                if stroke.tool == .eraser {
                    cg.setBlendMode(.clear)
                    cg.setStrokeColor(UIColor.black.cgColor)
                } else if stroke.tool == .highlighter {
                    cg.setBlendMode(.multiply)
                    cg.setAlpha(stroke.tool.intrinsicOpacity * stroke.color.alpha)
                    cg.setStrokeColor(stroke.color.uiColor.withAlphaComponent(1.0).cgColor)
                } else {
                    cg.setBlendMode(.normal)
                    cg.setAlpha(stroke.tool.intrinsicOpacity * stroke.color.alpha)
                    cg.setStrokeColor(stroke.color.uiColor.cgColor)
                }
                cg.setLineWidth(stroke.nominalWidth)
                cg.setLineCap(stroke.tool == .highlighter ? .butt : .round)
                cg.setLineJoin(.round)
                if stroke.points.count == 1, let pt = stroke.points.first {
                    let r = stroke.nominalWidth * 0.5
                    cg.setFillColor(stroke.tool == .eraser ? UIColor.black.cgColor : stroke.color.uiColor.cgColor)
                    cg.fillEllipse(in: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2))
                } else {
                    cg.addPath(bezierPath)
                    cg.strokePath()
                }
                cg.restoreGState()
            }
            cg.endTransparencyLayer()
            cg.restoreGState()
        }

        guard !fallbackPNG.isEmpty else { return nil }
        return (fallbackPNG, CGSize(width: targetSize.width * scale, height: targetSize.height * scale))
    }
}

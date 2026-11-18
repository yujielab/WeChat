import SwiftUI

// MARK: - Native Lottie Subset JSON Decoder & Vector Evaluator (M10)
//
// Parses unzipped Telegram `.tgs` / Lottie JSON served by `/api/stickers/anim/:id?set=`
// (`src/stickers.js:298-303`, `public/js/views/stickers.js:152-164`) and evaluates keyframed
// vector shape hierarchies (`gr`, `sh`, `el`, `rc`, `fl`, `st`, `tr`) directly into a SwiftUI
// `GraphicsContext` at 60–120Hz via `TimelineView` — zero WebView, zero third-party SDK!

public struct LottieAnimationDocument: Decodable, Sendable {
    public let frameRate: Double
    public let inPoint: Double
    public let outPoint: Double
    public let width: Double
    public let height: Double
    public let layers: [LottieShapeLayer]

    private enum CodingKeys: String, CodingKey {
        case frameRate = "fr"
        case inPoint = "ip"
        case outPoint = "op"
        case width = "w"
        case height = "h"
        case layers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.frameRate = max(1, (try? c.decode(Double.self, forKey: .frameRate)) ?? 60)
        self.inPoint = (try? c.decode(Double.self, forKey: .inPoint)) ?? 0
        self.outPoint = max(inPoint + 1, (try? c.decode(Double.self, forKey: .outPoint)) ?? 180)
        self.width = max(1, (try? c.decode(Double.self, forKey: .width)) ?? 512)
        self.height = max(1, (try? c.decode(Double.self, forKey: .height)) ?? 512)
        self.layers = (try? c.decode([LottieShapeLayer].self, forKey: .layers)) ?? []
    }

    public var durationSeconds: Double {
        max(0.25, (outPoint - inPoint) / frameRate)
    }

    public var hasRenderableShapes: Bool {
        layers.contains { !$0.shapes.isEmpty }
    }
}

public struct LottieShapeLayer: Decodable, Sendable {
    public let index: Int?
    public let parentIndex: Int?
    public let inFrame: Double
    public let outFrame: Double
    public let transform: LottieTransform
    public let shapes: [LottieShapeItem]

    private enum CodingKeys: String, CodingKey {
        case index = "ind"
        case parentIndex = "parent"
        case inFrame = "ip"
        case outFrame = "op"
        case transform = "ks"
        case shapes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.index = try? c.decode(Int.self, forKey: .index)
        self.parentIndex = try? c.decode(Int.self, forKey: .parentIndex)
        self.inFrame = (try? c.decode(Double.self, forKey: .inFrame)) ?? 0
        self.outFrame = (try? c.decode(Double.self, forKey: .outFrame)) ?? 9_999
        self.transform = (try? c.decode(LottieTransform.self, forKey: .transform)) ?? .identity
        self.shapes = (try? c.decode([LottieShapeItem].self, forKey: .shapes)) ?? []
    }
}

public struct LottieTransform: Decodable, Sendable {
    public let anchor: LottieAnimatableVector
    public let position: LottieAnimatableVector
    public let scale: LottieAnimatableVector
    public let rotation: LottieAnimatableScalar
    public let opacity: LottieAnimatableScalar

    public static let identity = LottieTransform(
        anchor: .constant([0, 0]),
        position: .constant([0, 0]),
        scale: .constant([100, 100]),
        rotation: .constant(0),
        opacity: .constant(100)
    )

    public init(
        anchor: LottieAnimatableVector,
        position: LottieAnimatableVector,
        scale: LottieAnimatableVector,
        rotation: LottieAnimatableScalar,
        opacity: LottieAnimatableScalar
    ) {
        self.anchor = anchor
        self.position = position
        self.scale = scale
        self.rotation = rotation
        self.opacity = opacity
    }

    private enum CodingKeys: String, CodingKey {
        case anchor = "a"
        case position = "p"
        case scale = "s"
        case rotation = "r"
        case opacity = "o"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.anchor = (try? c.decode(LottieAnimatableVector.self, forKey: .anchor)) ?? .constant([0, 0])
        self.position = (try? c.decode(LottieAnimatableVector.self, forKey: .position)) ?? .constant([0, 0])
        self.scale = (try? c.decode(LottieAnimatableVector.self, forKey: .scale)) ?? .constant([100, 100])
        self.rotation = (try? c.decode(LottieAnimatableScalar.self, forKey: .rotation)) ?? .constant(0)
        self.opacity = (try? c.decode(LottieAnimatableScalar.self, forKey: .opacity)) ?? .constant(100)
    }

    public func matrix(atFrame frame: Double) -> CGAffineTransform {
        let a = anchor.value(atFrame: frame)
        let p = position.value(atFrame: frame)
        let s = scale.value(atFrame: frame)
        let rDegrees = rotation.value(atFrame: frame)

        let ax = a.first ?? 0
        let ay = a.count > 1 ? a[1] : 0
        let px = p.first ?? 0
        let py = p.count > 1 ? p[1] : 0
        let sx = (s.first ?? 100) / 100.0
        let sy = (s.count > 1 ? s[1] : sx * 100.0) / 100.0
        let radians = rDegrees * .pi / 180.0

        var mtx = CGAffineTransform.identity
        mtx = mtx.translatedBy(x: px, y: py)
        mtx = mtx.rotated(by: radians)
        mtx = mtx.scaledBy(x: sx, y: sy)
        mtx = mtx.translatedBy(x: -ax, y: -ay)
        return mtx
    }
}

public struct LottieAnimatableScalar: Decodable, Sendable {
    public struct Keyframe: Sendable {
        public let time: Double
        public let startValue: Double
        public let endValue: Double?
    }

    private let staticValue: Double
    private let keyframes: [Keyframe]

    public static func constant(_ value: Double) -> LottieAnimatableScalar {
        LottieAnimatableScalar(staticValue: value, keyframes: [])
    }

    private init(staticValue: Double, keyframes: [Keyframe]) {
        self.staticValue = staticValue
        self.keyframes = keyframes
    }

    private enum CodingKeys: String, CodingKey {
        case animated = "a"
        case value = "k"
    }

    private struct RawKeyframe: Decodable {
        let t: Double?
        let s: [Double]?
        let e: [Double]?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let isAnimated = ((try? c.decode(Int.self, forKey: .animated)) ?? 0) == 1
        if !isAnimated {
            if let scalar = try? c.decode(Double.self, forKey: .value) {
                self.staticValue = scalar
                self.keyframes = []
                return
            }
            if let arr = try? c.decode([Double].self, forKey: .value), let first = arr.first {
                self.staticValue = first
                self.keyframes = []
                return
            }
        }
        if let rawFrames = try? c.decode([RawKeyframe].self, forKey: .value), !rawFrames.isEmpty {
            let parsed = rawFrames.compactMap { rf -> Keyframe? in
                guard let t = rf.t else { return nil }
                let sv = rf.s?.first ?? 0
                return Keyframe(time: t, startValue: sv, endValue: rf.e?.first)
            }
            self.staticValue = parsed.first?.startValue ?? 0
            self.keyframes = parsed
        } else {
            self.staticValue = 0
            self.keyframes = []
        }
    }

    public func value(atFrame frame: Double) -> Double {
        guard !keyframes.isEmpty else { return staticValue }
        if frame <= keyframes[0].time { return keyframes[0].startValue }
        for i in 0..<(keyframes.count - 1) {
            let current = keyframes[i]
            let next = keyframes[i + 1]
            if frame >= current.time && frame <= next.time {
                let span = max(0.0001, next.time - current.time)
                let t = (frame - current.time) / span
                let target = current.endValue ?? next.startValue
                return current.startValue + (target - current.startValue) * t
            }
        }
        return keyframes.last?.startValue ?? staticValue
    }
}

public struct LottieAnimatableVector: Decodable, Sendable {
    public struct Keyframe: Sendable {
        public let time: Double
        public let startValue: [Double]
        public let endValue: [Double]?
    }

    private let staticValue: [Double]
    private let keyframes: [Keyframe]

    public static func constant(_ value: [Double]) -> LottieAnimatableVector {
        LottieAnimatableVector(staticValue: value, keyframes: [])
    }

    private init(staticValue: [Double], keyframes: [Keyframe]) {
        self.staticValue = staticValue
        self.keyframes = keyframes
    }

    private enum CodingKeys: String, CodingKey {
        case animated = "a"
        case value = "k"
    }

    private struct RawKeyframe: Decodable {
        let t: Double?
        let s: [Double]?
        let e: [Double]?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let isAnimated = ((try? c.decode(Int.self, forKey: .animated)) ?? 0) == 1
        if !isAnimated, let vec = try? c.decode([Double].self, forKey: .value) {
            self.staticValue = vec
            self.keyframes = []
            return
        }
        if let rawFrames = try? c.decode([RawKeyframe].self, forKey: .value), !rawFrames.isEmpty {
            let parsed = rawFrames.compactMap { rf -> Keyframe? in
                guard let t = rf.t else { return nil }
                return Keyframe(time: t, startValue: rf.s ?? [], endValue: rf.e)
            }
            self.staticValue = parsed.first?.startValue ?? [0, 0]
            self.keyframes = parsed
        } else {
            self.staticValue = [0, 0]
            self.keyframes = []
        }
    }

    public func value(atFrame frame: Double) -> [Double] {
        guard !keyframes.isEmpty else { return staticValue }
        if frame <= keyframes[0].time { return keyframes[0].startValue }
        for i in 0..<(keyframes.count - 1) {
            let current = keyframes[i]
            let next = keyframes[i + 1]
            if frame >= current.time && frame <= next.time {
                let span = max(0.0001, next.time - current.time)
                let t = (frame - current.time) / span
                let target = current.endValue ?? next.startValue
                let count = min(current.startValue.count, target.count)
                guard count > 0 else { return current.startValue }
                return (0..<count).map { idx in
                    current.startValue[idx] + (target[idx] - current.startValue[idx]) * t
                }
            }
        }
        return keyframes.last?.startValue ?? staticValue
    }
}

public struct LottieBezierPathData: Decodable, Sendable {
    public let closed: Bool
    public let vertices: [[Double]]
    public let inTangents: [[Double]]
    public let outTangents: [[Double]]

    private enum CodingKeys: String, CodingKey {
        case closed = "c"
        case vertices = "v"
        case inTangents = "i"
        case outTangents = "o"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.closed = (try? c.decode(Bool.self, forKey: .closed)) ?? false
        self.vertices = (try? c.decode([[Double]].self, forKey: .vertices)) ?? []
        self.inTangents = (try? c.decode([[Double]].self, forKey: .inTangents)) ?? []
        self.outTangents = (try? c.decode([[Double]].self, forKey: .outTangents)) ?? []
    }

    public func toPath() -> Path {
        var path = Path()
        guard !vertices.isEmpty else { return path }
        let pt = { (arr: [Double]) -> CGPoint in
            CGPoint(x: arr.first ?? 0, y: arr.count > 1 ? arr[1] : 0)
        }
        path.move(to: pt(vertices[0]))
        for idx in 1..<vertices.count {
            let prev = pt(vertices[idx - 1])
            let curr = pt(vertices[idx])
            let outRel = idx - 1 < outTangents.count ? pt(outTangents[idx - 1]) : .zero
            let inRel = idx < inTangents.count ? pt(inTangents[idx]) : .zero
            path.addCurve(
                to: curr,
                control1: CGPoint(x: prev.x + outRel.x, y: prev.y + outRel.y),
                control2: CGPoint(x: curr.x + inRel.x, y: curr.y + inRel.y)
            )
        }
        if closed && vertices.count > 1 {
            let lastIdx = vertices.count - 1
            let prev = pt(vertices[lastIdx])
            let first = pt(vertices[0])
            let outRel = lastIdx < outTangents.count ? pt(outTangents[lastIdx]) : .zero
            let inRel = !inTangents.isEmpty ? pt(inTangents[0]) : .zero
            path.addCurve(
                to: first,
                control1: CGPoint(x: prev.x + outRel.x, y: prev.y + outRel.y),
                control2: CGPoint(x: first.x + inRel.x, y: first.y + inRel.y)
            )
            path.closeSubpath()
        }
        return path
    }
}

public struct LottieAnimatableShape: Decodable, Sendable {
    private let staticShape: LottieBezierPathData?

    private enum CodingKeys: String, CodingKey {
        case animated = "a"
        case value = "k"
    }

    private struct KeyframeWrapper: Decodable {
        let s: [LottieBezierPathData]?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let direct = try? c.decode(LottieBezierPathData.self, forKey: .value) {
            self.staticShape = direct
        } else if let keyframes = try? c.decode([KeyframeWrapper].self, forKey: .value) {
            self.staticShape = keyframes.first?.s?.first
        } else {
            self.staticShape = nil
        }
    }

    public func path() -> Path? {
        staticShape?.toPath()
    }
}

public indirect enum LottieShapeItem: Decodable, Sendable {
    case group(items: [LottieShapeItem], transform: LottieTransform)
    case shape(LottieAnimatableShape)
    case ellipse(position: LottieAnimatableVector, size: LottieAnimatableVector)
    case rect(position: LottieAnimatableVector, size: LottieAnimatableVector, cornerRadius: LottieAnimatableScalar)
    case fill(color: LottieAnimatableVector, opacity: LottieAnimatableScalar)
    case stroke(color: LottieAnimatableVector, opacity: LottieAnimatableScalar, width: LottieAnimatableScalar)
    case transform(LottieTransform)
    case unsupported

    private enum CodingKeys: String, CodingKey {
        case type = "ty"
        case items = "it"
        case ks
        case position = "p"
        case size = "s"
        case cornerRadius = "r"
        case color = "c"
        case opacity = "o"
        case width = "w"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = (try? c.decode(String.self, forKey: .type)) ?? ""
        switch type {
        case "gr":
            let rawItems = (try? c.decode([LottieShapeItem].self, forKey: .items)) ?? []
            var groupTransform: LottieTransform = .identity
            for item in rawItems {
                if case .transform(let tr) = item {
                    groupTransform = tr
                }
            }
            self = .group(items: rawItems, transform: groupTransform)

        case "sh":
            if let shape = try? c.decode(LottieAnimatableShape.self, forKey: .ks) {
                self = .shape(shape)
            } else {
                self = .unsupported
            }

        case "el":
            let p = (try? c.decode(LottieAnimatableVector.self, forKey: .position)) ?? .constant([0, 0])
            let s = (try? c.decode(LottieAnimatableVector.self, forKey: .size)) ?? .constant([0, 0])
            self = .ellipse(position: p, size: s)

        case "rc":
            let p = (try? c.decode(LottieAnimatableVector.self, forKey: .position)) ?? .constant([0, 0])
            let s = (try? c.decode(LottieAnimatableVector.self, forKey: .size)) ?? .constant([0, 0])
            let r = (try? c.decode(LottieAnimatableScalar.self, forKey: .cornerRadius)) ?? .constant(0)
            self = .rect(position: p, size: s, cornerRadius: r)

        case "fl":
            let col = (try? c.decode(LottieAnimatableVector.self, forKey: .color)) ?? .constant([0, 0, 0])
            let op = (try? c.decode(LottieAnimatableScalar.self, forKey: .opacity)) ?? .constant(100)
            self = .fill(color: col, opacity: op)

        case "st":
            let col = (try? c.decode(LottieAnimatableVector.self, forKey: .color)) ?? .constant([0, 0, 0])
            let op = (try? c.decode(LottieAnimatableScalar.self, forKey: .opacity)) ?? .constant(100)
            let w = (try? c.decode(LottieAnimatableScalar.self, forKey: .width)) ?? .constant(2)
            self = .stroke(color: col, opacity: op, width: w)

        case "tr":
            let tr = try LottieTransform(from: decoder)
            self = .transform(tr)

        default:
            self = .unsupported
        }
    }
}

public enum LottieCanvasEvaluator {
    public static func render(
        document: LottieAnimationDocument,
        elapsedSeconds: Double,
        in context: inout GraphicsContext,
        canvasSize: CGSize
    ) {
        let totalFrames = max(1, document.outPoint - document.inPoint)
        let rawFrameOffset = (elapsedSeconds * document.frameRate).truncatingRemainder(dividingBy: totalFrames)
        let frame = document.inPoint + (rawFrameOffset >= 0 ? rawFrameOffset : rawFrameOffset + totalFrames)

        let scale = min(canvasSize.width / document.width, canvasSize.height / document.height)
        let offsetX = (canvasSize.width - document.width * scale) * 0.5
        let offsetY = (canvasSize.height - document.height * scale) * 0.5

        var rootCtx = context
        rootCtx.translateBy(x: offsetX, y: offsetY)
        rootCtx.scaleBy(x: scale, y: scale)

        let layerMap = Dictionary(
            document.layers.compactMap { layer in layer.index.map { ($0, layer) } },
            uniquingKeysWith: { first, _ in first }
        )

        // Lottie layers render back-to-front (reversed order)
        for layer in document.layers.reversed() {
            guard frame >= layer.inFrame && frame <= layer.outFrame else { continue }
            var layerCtx = rootCtx
            let combinedMatrix = resolvedLayerMatrix(layer, in: layerMap, atFrame: frame, depth: 0)
            layerCtx.concatenate(combinedMatrix)
            layerCtx.opacity *= max(0, min(1, layer.transform.opacity.value(atFrame: frame) / 100.0))
            renderShapeItems(layer.shapes, atFrame: frame, in: &layerCtx)
        }
    }

    private static func resolvedLayerMatrix(
        _ layer: LottieShapeLayer,
        in map: [Int: LottieShapeLayer],
        atFrame frame: Double,
        depth: Int
    ) -> CGAffineTransform {
        let local = layer.transform.matrix(atFrame: frame)
        guard depth < 8, let parentIdx = layer.parentIndex, let parent = map[parentIdx] else {
            return local
        }
        let parentMtx = resolvedLayerMatrix(parent, in: map, atFrame: frame, depth: depth + 1)
        return local.concatenating(parentMtx)
    }

    private static func renderShapeItems(
        _ items: [LottieShapeItem],
        atFrame frame: Double,
        in context: inout GraphicsContext
    ) {
        var accumulatedPath = Path()
        for item in items {
            switch item {
            case .group(let subItems, let transform):
                var groupCtx = context
                groupCtx.concatenate(transform.matrix(atFrame: frame))
                groupCtx.opacity *= max(0, min(1, transform.opacity.value(atFrame: frame) / 100.0))
                renderShapeItems(subItems, atFrame: frame, in: &groupCtx)

            case .shape(let animShape):
                if let p = animShape.path() {
                    accumulatedPath.addPath(p)
                }

            case .ellipse(let pos, let size):
                let p = pos.value(atFrame: frame)
                let s = size.value(atFrame: frame)
                let w = s.first ?? 0
                let h = s.count > 1 ? s[1] : w
                let cx = p.first ?? 0
                let cy = p.count > 1 ? p[1] : 0
                accumulatedPath.addEllipse(in: CGRect(x: cx - w * 0.5, y: cy - h * 0.5, width: w, height: h))

            case .rect(let pos, let size, let radius):
                let p = pos.value(atFrame: frame)
                let s = size.value(atFrame: frame)
                let r = radius.value(atFrame: frame)
                let w = s.first ?? 0
                let h = s.count > 1 ? s[1] : w
                let cx = p.first ?? 0
                let cy = p.count > 1 ? p[1] : 0
                accumulatedPath.addRoundedRect(
                    in: CGRect(x: cx - w * 0.5, y: cy - h * 0.5, width: w, height: h),
                    cornerSize: CGSize(width: r, height: r)
                )

            case .fill(let colorVec, let opScalar):
                let c = colorVec.value(atFrame: frame)
                let opacity = max(0, min(1, opScalar.value(atFrame: frame) / 100.0))
                if !accumulatedPath.isEmpty {
                    let swiftColor = Color(
                        .sRGB,
                        red: c.first ?? 0,
                        green: c.count > 1 ? c[1] : 0,
                        blue: c.count > 2 ? c[2] : 0,
                        opacity: opacity
                    )
                    context.fill(accumulatedPath, with: .color(swiftColor))
                }

            case .stroke(let colorVec, let opScalar, let widthScalar):
                let c = colorVec.value(atFrame: frame)
                let opacity = max(0, min(1, opScalar.value(atFrame: frame) / 100.0))
                let lineW = max(0.5, widthScalar.value(atFrame: frame))
                if !accumulatedPath.isEmpty {
                    let swiftColor = Color(
                        .sRGB,
                        red: c.first ?? 0,
                        green: c.count > 1 ? c[1] : 0,
                        blue: c.count > 2 ? c[2] : 0,
                        opacity: opacity
                    )
                    context.stroke(
                        accumulatedPath,
                        with: .color(swiftColor),
                        style: StrokeStyle(lineWidth: lineW, lineCap: .round, lineJoin: .round)
                    )
                }

            case .transform, .unsupported:
                break
            }
        }
    }
}

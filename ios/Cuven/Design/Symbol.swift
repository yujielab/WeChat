import SwiftUI

// The web's glyphs (public/index.html sprite), drawn natively: a 24-unit
// grid, strokes with round caps and joins at one weight, fills, secondary
// layers that can step back, and knock-outs cut from what's under them.

enum PathOp {
    case m(CGFloat, CGFloat)
    case l(CGFloat, CGFloat)
    case c(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
    case q(CGFloat, CGFloat, CGFloat, CGFloat)
    case z
}

struct SymLayer {
    enum Kind { case stroke, fill }
    let kind: Kind
    let tier: Int
    let knock: Bool
    let path: Path

    init(_ kind: Kind, tier: Int, knock: Bool, ops: [PathOp]) {
        self.kind = kind
        self.tier = tier
        self.knock = knock
        var p = Path()
        for op in ops {
            switch op {
            case let .m(x, y): p.move(to: CGPoint(x: x, y: y))
            case let .l(x, y): p.addLine(to: CGPoint(x: x, y: y))
            case let .c(a, b, c, d, x, y): p.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: a, y: b), control2: CGPoint(x: c, y: d))
            case let .q(a, b, x, y): p.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: a, y: b))
            case .z: p.closeSubpath()
            }
        }
        self.path = p
    }
}

struct SymDef {
    let sf: String
    /// The stroke weight a lone glyph draws at (symbols.css --sym-glyph).
    let glyph: CGFloat
    let slashable: Bool
    let layers: [SymLayer]
}

/// One glyph. `weight` overrides the stroke width (in grid units, like
/// --sym-w); `secondary` steps l2 / l3 layers back (hierarchical mode, as
/// in bars and the sidebar).
struct SymbolView: View {
    let sym: Sym
    var size: CGFloat = 22
    var weight: CGFloat? = nil
    var secondary: Double = 1
    var slashed = false

    init(_ sym: Sym, size: CGFloat = 22, weight: CGFloat? = nil, secondary: Double = 1, slashed: Bool = false) {
        self.sym = sym
        self.size = size
        self.weight = weight
        self.secondary = secondary
        self.slashed = slashed
    }

    var body: some View {
        let def = sym.cached
        let w = weight ?? def.glyph
        Canvas { ctx, sz in
            let k = sz.width / 24
            ctx.scaleBy(x: k, y: k)
            let style = StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round)
            for layer in def.layers where !layer.knock {
                var c = ctx
                if layer.tier == 2 { c.opacity = secondary }
                if layer.tier == 3 { c.opacity = secondary * 0.6 }
                switch layer.kind {
                case .stroke: c.stroke(layer.path, with: .foreground, style: style)
                case .fill: c.fill(layer.path, with: .foreground)
                }
            }
            for layer in def.layers where layer.knock {
                var c = ctx
                c.blendMode = .destinationOut
                switch layer.kind {
                case .stroke: c.stroke(layer.path, with: .color(.black), style: StrokeStyle(lineWidth: w + 0.5, lineCap: .round, lineJoin: .round))
                case .fill: c.fill(layer.path, with: .color(.black))
                }
            }
            if slashed {
                var slash = Path()
                slash.move(to: CGPoint(x: 4, y: 4))
                slash.addLine(to: CGPoint(x: 20, y: 20))
                var cut = ctx
                cut.blendMode = .destinationOut
                cut.stroke(slash, with: .color(.black), style: StrokeStyle(lineWidth: w + 3.4, lineCap: .round))
                ctx.stroke(slash, with: .foreground, style: style)
            }
        }
        .compositingGroup()
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Glyph paths are built once.
enum SymCache {
    nonisolated(unsafe) static var store: [Sym: SymDef] = [:]
}

extension Sym {
    var cached: SymDef {
        if let d = SymCache.store[self] { return d }
        let d = def
        SymCache.store[self] = d
        return d
    }
}

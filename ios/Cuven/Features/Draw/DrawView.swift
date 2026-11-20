import SwiftUI
import PencilKit

/// The drawing board beside the conversation: paper, a floating row of
/// tools (the one in hand stands taller, its tip in the current colour),
/// five colours and a wheel, and close / undo / send below.
struct DrawView: View {
    let roomId: String
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    @Environment(\.column) private var ctx

    @State private var board = Board()
    @State private var tool: Tool = .pen
    @State private var color: Color = .black
    @State private var width: CGFloat = 6
    @State private var paper: Paper = .blank
    @State private var confirmDiscard = false

    enum Tool: String, CaseIterable, Identifiable {
        case pen, marker, highlighter, pencil, eraser
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .pen: return "Pen"
            case .marker: return "Marker"
            case .highlighter: return "Highlighter"
            case .pencil: return "Pencil"
            case .eraser: return "Eraser"
            }
        }
    }

    enum Paper: String, CaseIterable { case blank, lined, grid }

    private let swatches: [Color] = [Color(hex: 0x1c1c1e), Color(hex: 0x007aff), Color(hex: 0x34c759), Color(hex: 0xffcc00), Color(hex: 0xff3b30)]

    var body: some View {
        ZStack(alignment: .top) {
            Color.white
            PaperPattern(paper: paper)
            CanvasRepresentable(board: board)

            Text("Drawing board")
                .font(AppFont.make(20, .bold))
                .foregroundStyle(Color(hex: 0x0b0b0d))
                .padding(.top, ctx.insets.top + 10)
                .padding(.trailing, ctx.insets.trailing)
                .allowsHitTesting(false)

            toolTray
                .padding(.leading, max(ctx.insets.leading, 20))
                .padding(.trailing, ctx.usesRail ? railContent : max(ctx.insets.trailing, 20))
                .padding(.bottom, ctx.usesRail ? max(ctx.insets.bottom, 14) : ctx.barClearance)
                .frame(maxHeight: .infinity, alignment: .bottom)

            if ctx.usesRail {
                ColumnBar(back: BarItem(id: "close", sym: .xmark, title: "Close") { close() },
                          actions: [BarItem(id: "send", sym: .arrowUp, title: "Send", tint: board.isEmpty ? nil : Color(hex: 0x000000),
                                            foreground: board.isEmpty ? Color(hex: 0x8e8e93) : .white) { send() }],
                          footActions: [BarItem(id: "undo", sym: .undo, title: "Undo") { board.undo() },
                                        BarItem(id: "redo", sym: .redo, title: "Redo") { board.redo() }])
            } else {
                ColumnBar(back: BarItem(id: "close", sym: .xmark, title: "Close") { close() },
                          actions: [BarItem(id: "undo", sym: .undo, title: "Undo") { board.undo() },
                                    BarItem(id: "redo", sym: .redo, title: "Redo") { board.redo() },
                                    BarItem(id: "send", sym: .arrowUp, title: "Send", tint: board.isEmpty ? nil : Color(hex: 0x000000),
                                            foreground: board.isEmpty ? Color(hex: 0x8e8e93) : .white) { send() }],
                          groupActions: false)
            }
        }
        .environment(\.colorScheme, .light)
        .onChange(of: tool) { _, _ in applyTool() }
        .onChange(of: color) { _, _ in applyTool() }
        .onChange(of: width) { _, _ in applyTool() }
        .onAppear { applyTool() }
        .confirmationDialog("Discard this drawing?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                board.clear()
                nav.closeDetail()
            }
        }
    }

    private var railContent: CGFloat {
        guard let rail = ctx.rail else { return ctx.insets.trailing }
        return max(ctx.insets.trailing, rail.centerFromEdge + Bar.railWidth / 2 + 12)
    }

    /// The tools stand in a glass tray: the one in hand taller; a hairline;
    /// six colours in two rows (the last a wheel); "…" for width and paper.
    private var toolTray: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Tool.allCases.filter { $0 != .eraser || true }) { t in
                    Button {
                        Haptics.selection()
                        withAnimation(Motion.bouncy) { tool = t }
                    } label: {
                        ToolGlyph(tool: t, color: t == .eraser ? .gray : color, width: width, selected: tool == t)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(t.title))
                    .accessibilityAddTraits(tool == t ? .isSelected : [])
                }
            }
            .frame(height: 74, alignment: .bottom)
            .clipped()

            Rectangle().fill(Color.black.opacity(0.12)).frame(width: 1, height: 64)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 8), count: 3), spacing: 8) {
                ForEach(Array(swatches.enumerated()), id: \.offset) { _, c in
                    Button {
                        Haptics.selection()
                        color = c
                        if tool == .eraser { tool = .pen }
                    } label: {
                        Circle().fill(c)
                            .frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(Color.black, lineWidth: color == c ? 2 : 0).padding(-3))
                            .overlay(Circle().strokeBorder(.white, lineWidth: color == c ? 2 : 0))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.press(0.88))
                }
                ColorPicker("", selection: $color, supportsOpacity: false).labelsHidden().frame(width: 28, height: 28)
            }
            .frame(width: 100)

            Menu {
                Picker("Width", selection: $width) {
                    Text("Fine").tag(CGFloat(3))
                    Text("Medium").tag(CGFloat(6))
                    Text("Bold").tag(CGFloat(12))
                    Text("Heavy").tag(CGFloat(22))
                }
                Picker("Paper", selection: $paper) {
                    Text("Blank").tag(Paper.blank)
                    Text("Lined").tag(Paper.lined)
                    Text("Grid").tag(Paper.grid)
                }
                Button("Clear", role: .destructive) { board.clear() }
            } label: {
                SymbolView(.ellipsis, size: 20).foregroundStyle(Color(hex: 0x0b0b0d))
                    .frame(width: 44, height: 44).glassCircle()
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .glass(RoundedRectangle(cornerRadius: 34, style: .continuous), interactive: false)
        .frame(maxWidth: 560)
    }

    private func applyTool() {
        let ui = UIColor(color)
        switch tool {
        case .pen: board.canvas.tool = PKInkingTool(.pen, color: ui, width: width)
        case .marker: board.canvas.tool = PKInkingTool(.marker, color: ui, width: width * 2.2)
        case .highlighter: board.canvas.tool = PKInkingTool(.marker, color: ui.withAlphaComponent(0.35), width: width * 4)
        case .pencil: board.canvas.tool = PKInkingTool(.pencil, color: ui, width: width * 1.4)
        case .eraser: board.canvas.tool = PKEraserTool(.vector)
        }
    }

    private func close() {
        if board.isEmpty { nav.closeDetail() } else { confirmDiscard = true }
    }

    private func send() {
        guard let image = board.render() else {
            Haptics.warning()
            return
        }
        model.sendPicture(image, room: roomId, drawing: true)
        board.clear()
        Haptics.success()
        nav.closeDetail()
    }
}

/// The canvas and its own history (undo / redo that don't depend on the responder chain).
@MainActor
@Observable
final class Board: NSObject, PKCanvasViewDelegate {
    @ObservationIgnored let canvas = PKCanvasView()
    @ObservationIgnored private var history: [PKDrawing] = []
    @ObservationIgnored private var future: [PKDrawing] = []
    @ObservationIgnored private var last = PKDrawing()
    @ObservationIgnored private var applying = false
    /// Whether anything is drawn (the send button fills with ink once it is).
    private(set) var empty = true

    override init() {
        super.init()
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.delegate = self
    }

    var isEmpty: Bool { empty }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        let now = canvasView.drawing.strokes.isEmpty
        if now != empty { empty = now }
        guard !applying else { return }
        history.append(last)
        if history.count > 60 { history.removeFirst() }
        future.removeAll()
        last = canvasView.drawing
    }

    func undo() {
        guard let prev = history.popLast() else { return }
        future.append(canvas.drawing)
        set(prev)
        Haptics.tap()
    }

    func redo() {
        guard let next = future.popLast() else { return }
        history.append(canvas.drawing)
        set(next)
        Haptics.tap()
    }

    func clear() {
        guard !isEmpty else { return }
        history.append(canvas.drawing)
        future.removeAll()
        set(PKDrawing())
    }

    private func set(_ d: PKDrawing) {
        applying = true
        canvas.drawing = d
        last = d
        empty = d.strokes.isEmpty
        applying = false
    }

    func render() -> UIImage? {
        guard !isEmpty else { return nil }
        let bounds = canvas.bounds
        let scale = min(2, 1600 / max(bounds.width, bounds.height, 1))
        let ink = canvas.drawing.image(from: bounds, scale: scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: bounds.size))
            ink.draw(in: CGRect(origin: .zero, size: bounds.size))
        }
    }
}

struct CanvasRepresentable: UIViewRepresentable {
    let board: Board
    func makeUIView(context: Context) -> PKCanvasView { board.canvas }
    func updateUIView(_ uiView: PKCanvasView, context: Context) {}
}

struct PaperPattern: View {
    let paper: DrawView.Paper

    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 28
            let line = Color(hex: 0x1877f2).opacity(0.12)
            switch paper {
            case .blank: break
            case .lined:
                var y = step
                while y < size.height {
                    ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(line))
                    y += step
                }
            case .grid:
                var y = step
                while y < size.height {
                    ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(line))
                    y += step
                }
                var x = step
                while x < size.width {
                    ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(line))
                    x += step
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// A drawing tool standing in the tray: the body, a band and the tip in the
/// current colour; the one in hand rises.
struct ToolGlyph: View {
    let tool: DrawView.Tool
    let color: Color
    let width: CGFloat
    let selected: Bool

    var body: some View {
        VStack(spacing: 0) {
            tip
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(bodyColor)
                if tool != .eraser {
                    Rectangle().fill(color).frame(height: 4).offset(y: -14)
                    Text("\(Int(width))").font(.system(size: 8, weight: .bold).monospacedDigit()).foregroundStyle(.black.opacity(0.4))
                }
            }
            .frame(width: 22, height: 44)
        }
        .offset(y: selected ? 0 : 18)
        .shadow(color: .black.opacity(selected ? 0.18 : 0.06), radius: selected ? 4 : 1, y: 1)
    }

    private var bodyColor: Color {
        switch tool {
        case .pen: return Color(hex: 0xf4f4f6)
        case .marker: return Color(hex: 0xe9e9ee)
        case .highlighter: return Color(hex: 0xfdf6c6)
        case .pencil: return Color(hex: 0xf6d67a)
        case .eraser: return Color(hex: 0xffc0cb)
        }
    }

    @ViewBuilder
    private var tip: some View {
        switch tool {
        case .eraser:
            RoundedRectangle(cornerRadius: 4).fill(Color(hex: 0xf7a6b5)).frame(width: 22, height: 10)
        case .highlighter:
            Rectangle().fill(color.opacity(0.6)).frame(width: 14, height: 12)
        default:
            Triangle().fill(tool == .pencil ? Color(hex: 0xe8c9a0) : Color(hex: 0xdcdce2))
                .frame(width: 22, height: 14)
                .overlay(alignment: .top) { Triangle().fill(color).frame(width: 7, height: 5) }
        }
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

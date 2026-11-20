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

    private let swatches: [Color] = [.black, Color(hex: 0x1877f2), Color(hex: 0xff3b30), Color(hex: 0x34c759), Color(hex: 0xff9f0a)]

    var body: some View {
        ZStack {
            Color(hex: 0xf2f2f5)
            VStack(spacing: 0) {
                paperView
                    .padding(.top, ctx.insets.top + 12)
                    .padding(.leading, ctx.insets.leading + 12)
                    .padding(.trailing, ctx.insets.trailing + 12)
                Spacer(minLength: 0)
            }
            .padding(.bottom, ctx.usesRail ? ctx.insets.bottom + 12 + 96 : ctx.barClearance + 96)

            toolTray
                .padding(.leading, ctx.insets.leading)
                .padding(.trailing, ctx.insets.trailing)
                .padding(.bottom, ctx.usesRail ? ctx.insets.bottom + 12 : ctx.barClearance)
                .frame(maxHeight: .infinity, alignment: .bottom)

            ColumnBar(back: BarItem(id: "close", symbol: "xmark", title: "Close") { close() },
                      actions: [
                        BarItem(id: "undo", symbol: "arrow.uturn.backward", title: "Undo") { board.undo() },
                        BarItem(id: "redo", symbol: "arrow.uturn.forward", title: "Redo") { board.redo() },
                        BarItem(id: "send", symbol: "arrow.up", title: "Send", tint: Theme.blue, foreground: .white) { send() }
                      ])
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

    private var paperView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white)
            PaperPattern(paper: paper)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            CanvasRepresentable(board: board)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
    }

    private var toolTray: some View {
        VStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: 14) {
                ForEach(Tool.allCases) { t in
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
            .frame(height: 58, alignment: .bottom)
            .clipped()

            HStack(spacing: 10) {
                ForEach(Array(swatches.enumerated()), id: \.offset) { _, c in
                    Button {
                        Haptics.selection()
                        color = c
                        if tool == .eraser { tool = .pen }
                    } label: {
                        Circle().fill(c)
                            .frame(width: 26, height: 26)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .overlay(Circle().stroke(color == c ? Theme.blue : .clear, lineWidth: 2).padding(-3))
                    }
                    .buttonStyle(.press(0.88))
                }
                ColorPicker("", selection: $color, supportsOpacity: false).labelsHidden().frame(width: 30)
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
                    Image(systemName: "ellipsis").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.label)
                        .frame(width: 34, height: 34).background(Theme.fillQuiet, in: Circle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 10)
        .glass(RoundedRectangle(cornerRadius: 26, style: .continuous), interactive: false)
        .padding(.horizontal, 12)
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
final class Board: NSObject, PKCanvasViewDelegate {
    let canvas = PKCanvasView()
    private var history: [PKDrawing] = []
    private var future: [PKDrawing] = []
    private var last = PKDrawing()
    private var applying = false

    override init() {
        super.init()
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.delegate = self
    }

    var isEmpty: Bool { canvas.drawing.strokes.isEmpty }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
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

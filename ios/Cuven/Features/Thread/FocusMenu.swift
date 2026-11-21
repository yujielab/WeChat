import SwiftUI
import Photos

/// Long-press on a message (views/thread.js, css/overlays.css): the
/// conversation blurs away, the message lifts out exactly as it was, when
/// it was sent stands at the top, its reactions in a capsule above it and
/// its actions in a card below — all on screen, on the message's side, a
/// message near the foot moving up just as far as it must.
struct FocusMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.column) private var ctx
    let target: FocusTarget
    let origin: CGPoint
    let width: CGFloat
    let onClose: () -> Void
    let onReply: (Message) -> Void
    let onEdit: (Message) -> Void

    @State private var shown = false
    @State private var selecting = false
    private let reactions = ["❤️", "😂", "👍", "😮", "😢", "🙏"]

    private var m: Message { target.message }
    private var mine: Bool { m.sender == model.me?.id }
    private var reactable: Bool { !m.isRevoked && !m.isLocal }

    private struct Action: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let sym: Sym
        var destructive = false
        var keepsOpen = false
        let run: () -> Void
    }

    /// Two groups: what you can do with it, then the ones that take it away.
    private var groups: [[Action]] {
        var main: [Action] = []
        if reactable { main.append(Action(id: "reply", title: "Reply", sym: .reply) { onReply(m) }) }
        if m.local == .failed { main.append(Action(id: "retry", title: "Resend", sym: .refresh) { model.retry(m) }) }
        if m.type == "text" && !m.body.isEmpty && !m.isRevoked {
            main.append(Action(id: "copy", title: "Copy", sym: .copy) {
                UIPasteboard.general.string = m.body
                model.show(String(localized: "Copied"))
            })
            main.append(Action(id: "select", title: "Select text", sym: .doc, keepsOpen: true) { selecting = true })
        }
        if model.canEdit(m) { main.append(Action(id: "edit", title: "Edit", sym: .compose) { onEdit(m) }) }
        if m.isVisual, let url = m.meta?.url {
            main.append(Action(id: "save", title: "Save to Photos", sym: .download) { save(url) })
        }
        if m.type == "file" { main.append(Action(id: "file", title: "Download file", sym: .download) { FileOpener.open(m) }) }
        var danger: [Action] = []
        if model.canUnsend(m) {
            danger.append(Action(id: "unsend", title: "Unsend", sym: .undo) { Task { await model.revoke(m) } })
        }
        // Undoable, so no question first (HIG: no alerts for undoable actions).
        danger.append(Action(id: "delete", title: "Delete for me", sym: .trash, destructive: true) { model.deleteLocally(m) })
        return [main, danger].filter { !$0.isEmpty }
    }

    var body: some View {
        GeometryReader { geo in
            let H = geo.size.height
            let local = target.frame.offsetBy(dx: -origin.x, dy: -origin.y)
            let timeH: CGFloat = 26
            let capsuleH: CGFloat = reactable ? 54 + 8 : 0
            let cardH = CGFloat(groups.reduce(0) { $0 + $1.count }) * 44 + CGFloat(max(0, groups.count - 1)) * 8
            let bubbleH = min(local.height, H * 0.42)
            let y = fittedTop(local: local, height: H, bubbleH: bubbleH, above: timeH + capsuleH, cardH: cardH)
            let dy = shown ? y - local.minY : 0
            let sideX = mine ? local.maxX : local.minX

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(Theme.bg.opacity(0.38))
                    .opacity(shown ? 1 : 0)
                    .ignoresSafeArea()
                    .onTapGesture { close() }

                // When it was sent, in full, at the top.
                Text(when)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.label2)
                    .frame(width: width, height: 18)
                    .offset(y: y - capsuleH - timeH + 2)
                    .opacity(shown ? 1 : 0)

                // The message itself, lifted.
                BubbleContent(message: m, style: BubbleStyle(mine: mine, tail: ["text", "voice", "file"].contains(m.type) && !Fmt.isJumboEmoji(m.body)),
                              maxWidth: local.width)
                    .frame(width: local.width, height: local.height, alignment: .top)
                    .frame(height: bubbleH, alignment: .top)
                    .mask(alignment: .top) {
                        LinearGradient(stops: [.init(color: .black, location: 0),
                                               .init(color: .black, location: local.height > bubbleH ? max(0, 1 - 36 / bubbleH) : 1),
                                               .init(color: .clear, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                    .shadow(color: Color(red: 15 / 255, green: 15 / 255, blue: 25 / 255).opacity(shown ? 0.24 : 0), radius: 17, y: 14)
                    .offset(x: local.minX, y: local.minY + dy)
                    .allowsHitTesting(false)

                // The reactions: a capsule of their own above the message.
                if reactable {
                    let current = m.reactions.first { $0.users.contains(model.me?.id ?? "") }?.emoji
                    HStack(spacing: 2) {
                        ForEach(Array(reactions.enumerated()), id: \.offset) { i, e in
                            Button {
                                Haptics.selection()
                                Task { await model.react(m, e) }
                                close()
                            } label: {
                                Text(e)
                                    .font(.system(size: 26))
                                    .frame(width: 44, height: 44)
                                    .background(current == e ? Theme.fill3 : .clear, in: Circle())
                                    .overlay(Circle().strokeBorder(current == e ? Theme.line : .clear, lineWidth: 1))
                                    .scaleEffect(shown ? 1 : 0.4)
                                    .opacity(shown ? 1 : 0)
                                    .animation(Motion.ui.delay(Double(i) * 0.024), value: shown)
                            }
                            .buttonStyle(.press(0.85))
                            .accessibilityLabel(Text(e))
                            .accessibilityAddTraits(current == e ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .glass(Capsule(), interactive: false)
                    .shadow(color: Color(red: 15 / 255, green: 15 / 255, blue: 25 / 255).opacity(0.16), radius: 16, y: 12)
                    .modifier(SideAnchor(x: sideX, mine: mine, width: width))
                    .offset(y: y - capsuleH + (shown ? 0 : 6))
                    .opacity(shown ? 1 : 0)
                    .scaleEffect(shown ? 1 : 0.92, anchor: mine ? .bottomTrailing : .bottomLeading)
                }

                // The actions: a card of rows, hairlines between, a band between groups.
                VStack(spacing: 0) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { gi, group in
                        if gi > 0 { Theme.label.opacity(0.07).frame(height: 8) }
                        ForEach(Array(group.enumerated()), id: \.element.id) { i, a in
                            if i > 0 { Rectangle().fill(Theme.line).frame(height: 0.5) }
                            Button {
                                Haptics.tap()
                                if a.keepsOpen { a.run() } else { close(); a.run() }
                            } label: {
                                HStack(spacing: 14) {
                                    Text(a.title).font(.bodyC).lineLimit(1)
                                    Spacer(minLength: 0)
                                    SymbolView(a.sym, size: 21)
                                }
                                .foregroundStyle(a.destructive ? Theme.redText : Theme.label)
                                .padding(.horizontal, 20)
                                .frame(height: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(MenuRowStyle())
                        }
                    }
                }
                .frame(width: min(254, width - 20))
                .background(Theme.elevated.opacity(0.86))
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
                .shadow(color: Color(red: 15 / 255, green: 15 / 255, blue: 25 / 255).opacity(0.18), radius: 22, y: 18)
                .modifier(SideAnchor(x: sideX, mine: mine, width: width))
                .offset(y: y + bubbleH + 13 + (shown ? 0 : -8))
                .opacity(shown ? 1 : 0)
                .scaleEffect(shown ? 1 : 0.9, anchor: mine ? .topTrailing : .topLeading)
            }
        }
        .onAppear { withAnimation(Motion.ui) { shown = true } }
        .sheet(isPresented: $selecting, onDismiss: { close() }) {
            SelectTextSheet(text: m.body)
        }
    }

    private var when: String {
        if m.isLocal { return m.local == .failed ? String(localized: "Not sent") : String(localized: "Sending…") }
        var s = Fmt.fullTime(m.date)
        if m.edited > 0, let at = m.meta?.editedAt, at > 0 {
            s += " · " + String(localized: "Edited \(Fmt.briefly(Date(timeIntervalSince1970: TimeInterval(at) / 1000)))")
        }
        return s
    }

    /// Where the message's top goes so what stands above and the card below both fit on screen.
    private func fittedTop(local: CGRect, height H: CGFloat, bubbleH: CGFloat, above: CGFloat, cardH: CGFloat) -> CGFloat {
        let top = ctx.insets.top + 12
        let bottom = H - max(ctx.insets.bottom, 12) - 12
        var y = local.minY
        if y - above < top { y = top + above }
        if y + bubbleH + 13 + cardH > bottom { y = bottom - cardH - 13 - bubbleH }
        return y
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.16)) { shown = false }
        Task {
            try? await Task.sleep(for: .milliseconds(160))
            onClose()
        }
    }

    private func save(_ url: String) {
        Task {
            guard let data = await ImageStore.shared.data(url), let img = UIImage(data: data) else { return }
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else { return }
                UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                Task { @MainActor in model.show(String(localized: "Saved to Photos")) }
            }
        }
    }
}

/// Select text: the bubble's words with the system's own handles.
private struct SelectTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Select text", centered: true) {
                GlassIconButton(sym: .xmark, title: "Close") { dismiss() }
            }
            ScrollView {
                Text(text)
                    .font(.bodyC)
                    .lineSpacing(BodyMetrics.extra)
                    .foregroundStyle(Theme.label)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(30)
        .presentationBackground(Theme.grouped)
    }
}

/// Lines a menu part up with the message's own edge, kept on screen.
private struct SideAnchor: ViewModifier {
    let x: CGFloat
    let mine: Bool
    let width: CGFloat

    func body(content: Content) -> some View {
        content
            .fixedSize()
            .padding(mine ? .trailing : .leading, max(10, mine ? width - x : x))
            .frame(width: width, alignment: mine ? .trailing : .leading)
    }
}

struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
            .background(configuration.isPressed ? Theme.fill4 : .clear)
    }
}

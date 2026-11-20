import SwiftUI
import Photos

/// Long-press on a message: the conversation blurs away, the message lifts
/// exactly as it was (size, wrapping, type), reactions sit in a capsule
/// above it and actions in a card below — all on screen, on the message's
/// side, a message near the bottom moving up just enough.
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
    private let reactions = ["❤️", "😂", "👍", "😮", "😢", "🙏"]

    private var m: Message { target.message }
    private var mine: Bool { m.sender == model.me?.id }

    private struct Action: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let symbol: String
        var destructive = false
        let run: () -> Void
    }

    private var actions: [Action] {
        var a: [Action] = []
        if m.local == .failed {
            a.append(Action(id: "retry", title: "Send again", symbol: "arrow.clockwise") { model.retry(m) })
            a.append(Action(id: "discard", title: "Delete", symbol: "trash", destructive: true) { model.discardFailed(m) })
            return a
        }
        if !m.isRevoked {
            a.append(Action(id: "reply", title: "Reply", symbol: "arrowshape.turn.up.left") { onReply(m) })
        }
        if m.type == "text" && !m.isRevoked {
            a.append(Action(id: "copy", title: "Copy", symbol: "doc.on.doc") {
                UIPasteboard.general.string = m.body
                model.show(String(localized: "Copied"))
            })
        }
        if m.isVisual, let url = m.meta?.url {
            a.append(Action(id: "save", title: "Save to Photos", symbol: "square.and.arrow.down") { save(url) })
        }
        if model.canEdit(m) {
            a.append(Action(id: "edit", title: "Edit", symbol: "pencil") { onEdit(m) })
        }
        if model.canUnsend(m) {
            a.append(Action(id: "unsend", title: "Unsend", symbol: "arrow.uturn.backward", destructive: true) {
                Task { await model.revoke(m) }
            })
        }
        return a
    }

    var body: some View {
        GeometryReader { geo in
            let H = geo.size.height
            let local = target.frame.offsetBy(dx: -origin.x, dy: -origin.y)
            let capsuleH: CGFloat = m.isRevoked || m.local == .failed ? 0 : 52
            let cardH = CGFloat(actions.count) * 46 + 36
            let top = ctx.insets.top + 12
            let bottom = H - max(ctx.insets.bottom, 12) - 12
            // How far the message must move so everything fits.
            let bubbleH = min(local.height, H * 0.42)
            var y = local.minY
            if y - capsuleH - 8 < top { y = top + capsuleH + 8 }
            if y + bubbleH + 10 + cardH > bottom { y = bottom - cardH - 10 - bubbleH }
            let dy = shown ? y - local.minY : 0
            let sideX = mine ? local.maxX : local.minX

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(Theme.bg.opacity(0.25))
                    .opacity(shown ? 1 : 0)
                    .ignoresSafeArea()
                    .onTapGesture { close() }

                // The message itself, lifted
                BubbleContent(message: m, style: BubbleStyle(mine: mine, tail: true), maxWidth: local.width)
                    .frame(width: local.width, height: local.height, alignment: .top)
                    .frame(height: bubbleH, alignment: .top)
                    .mask(alignment: .top) {
                        LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: local.height > bubbleH ? 0.85 : 1), .init(color: .clear, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                    .scaleEffect(shown ? 1.03 : 1, anchor: mine ? .trailing : .leading)
                    .shadow(color: .black.opacity(shown ? 0.16 : 0), radius: 18, y: 8)
                    .offset(x: local.minX, y: local.minY + dy)
                    .allowsHitTesting(false)

                // Reactions above
                if capsuleH > 0 {
                    let current = m.reactions.first { $0.users.contains(model.me?.id ?? "") }?.emoji
                    HStack(spacing: 4) {
                        ForEach(Array(reactions.enumerated()), id: \.offset) { i, e in
                            Button {
                                Haptics.selection()
                                Task { await model.react(m, e) }
                                close()
                            } label: {
                                Text(e)
                                    .font(.system(size: 26))
                                    .frame(width: 42, height: 42)
                                    .background(current == e ? Theme.blue.opacity(0.18) : .clear, in: Circle())
                                    .scaleEffect(shown ? 1 : 0.3)
                                    .animation(Motion.bouncy.delay(Double(i) * 0.025), value: shown)
                            }
                            .buttonStyle(.press(0.85))
                        }
                    }
                    .padding(.horizontal, 6)
                    .frame(height: capsuleH - 6)
                    .glass(Capsule(), interactive: false)
                    .modifier(SideAnchor(x: sideX, mine: mine, width: width))
                    .offset(y: y - capsuleH - 2 + (shown ? 0 : 12))
                    .opacity(shown ? 1 : 0)
                    .scaleEffect(shown ? 1 : 0.8, anchor: mine ? .bottomTrailing : .bottomLeading)
                }

                // Actions below
                VStack(spacing: 0) {
                    Text(m.isLocal ? String(localized: "Not sent") : Fmt.dayStamp(m.date))
                        .font(.caption2C)
                        .foregroundStyle(Theme.label3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                    ForEach(Array(actions.enumerated()), id: \.element.id) { i, a in
                        if i > 0 { Hairline().padding(.leading, 16) }
                        Button {
                            Haptics.tap()
                            close()
                            a.run()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: a.symbol).font(.system(size: 16, weight: .medium)).frame(width: 22)
                                Text(a.title).font(.bodyC)
                                Spacer()
                            }
                            .foregroundStyle(a.destructive ? Theme.redText : Theme.label)
                            .padding(.horizontal, 16)
                            .frame(height: 46)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(MenuRowStyle())
                    }
                }
                .frame(width: 250)
                .glass(RoundedRectangle(cornerRadius: 22, style: .continuous), interactive: false)
                .modifier(SideAnchor(x: sideX, mine: mine, width: width))
                .offset(y: y + bubbleH * (shown ? 1.03 : 1) + 10 + (shown ? 0 : -12))
                .opacity(shown ? 1 : 0)
                .scaleEffect(shown ? 1 : 0.8, anchor: mine ? .topTrailing : .topLeading)
            }
        }
        .onAppear { withAnimation(Motion.morph) { shown = true } }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.18)) { shown = false }
        Task {
            try? await Task.sleep(for: .milliseconds(170))
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

/// Lines a menu part up with the message's own edge, kept on screen.
private struct SideAnchor: ViewModifier {
    let x: CGFloat
    let mine: Bool
    let width: CGFloat

    func body(content: Content) -> some View {
        content
            .fixedSize()
            .padding(mine ? .trailing : .leading, max(12, mine ? width - x : x))
            .frame(width: width, alignment: mine ? .trailing : .leading)
    }
}

struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.fill : .clear)
    }
}

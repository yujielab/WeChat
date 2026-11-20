import SwiftUI

// People in the Messages list (views/people.js, css/people.css): notes along
// the top — a bubble resting on the top of each photo, yours first — and,
// under the chats, Suggested and People you may know with a card to invite.

// MARK: - Notes

struct NotesRow: View {
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 4) {
                NoteItem(user: model.me, text: model.myNote?.text, mine: true) { nav.noteEditor = true }
                ForEach(model.notes) { n in
                    NoteItem(user: n.user, text: n.text, mine: false) { nav.openNote = n }
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .padding(.bottom, 4)
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollClipDisabled()
        .animation(Motion.ui, value: model.notes.map(\.id))
    }
}

private struct NoteItem: View {
    let user: User?
    let text: String?
    let mine: Bool
    let action: () -> Void
    @State private var pressed = false

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: 6) {
                Avatar(user: user, size: 60)
                    .overlay(alignment: .bottomTrailing) {
                        if mine && text == nil {
                            SymbolView(.plus, size: 12, weight: 2.6)
                                .foregroundStyle(Theme.onInk)
                                .frame(width: 22, height: 22)
                                .background(Theme.ink, in: Circle())
                                .background(Circle().fill(Theme.bg).padding(-3))
                                .offset(x: 3, y: 3)
                        }
                    }
                Text(mine ? String(localized: "Your note") : (user?.name ?? ""))
                    .font(.captionC)
                    .foregroundStyle(mine ? Theme.label3 : Theme.label2)
                    .lineLimit(1)
            }
            .frame(width: 92)
            .padding(.top, 50)
            .padding(.bottom, 4)
            .overlay(alignment: .top) {
                // The bubble: its lower edge 16pt over the photo, however many lines.
                NoteBubble(text: text ?? (mine ? String(localized: "Share a thought…") : ""), empty: text == nil)
                    .frame(height: 66, alignment: .bottom)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(NoteFaceStyle())
    }
}

private struct NoteFaceStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(configuration.isPressed ? Motion.pressIn : Motion.ui, value: configuration.isPressed)
    }
}

/// A note's bubble: elevated surface, a hairline rim, a soft drop.
struct NoteBubble: View {
    let text: String
    var empty = false
    var big = false

    var body: some View {
        Text(text)
            .font(big ? .bodyC : .captionC)
            .lineSpacing(big ? 2 : 1)
            .foregroundStyle(empty ? Theme.label3 : Theme.label)
            .lineLimit(big ? 3 : 2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, big ? 18 : 10)
            .padding(.vertical, big ? 12 : 7)
            .frame(minWidth: big ? 160 : 48)
            .frame(maxWidth: big ? 300 : 96)
            .fixedSize(horizontal: false, vertical: true)
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: big ? 22 : 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: big ? 22 : 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.14), radius: 8, y: 6)
    }
}

/// Writing yours: the bubble large on your photo, 60 characters, for a day.
struct NoteEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var sending = false
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Note").font(.headlineC).foregroundStyle(Theme.label)
                HStack {
                    GlassIconButton(sym: .xmark, title: "Cancel") { dismiss() }
                    Spacer()
                    Button {
                        sending = true
                        Task {
                            await model.setNote(trimmed)
                            Haptics.success()
                            dismiss()
                        }
                    } label: {
                        SymbolView(.arrowUp, size: 20, weight: 2.5)
                            .foregroundStyle(Theme.onInk)
                            .frame(width: 44, height: 44)
                            .background(Theme.ink, in: Circle())
                    }
                    .buttonStyle(.press(0.94))
                    .disabled(trimmed.isEmpty || sending)
                    .opacity(trimmed.isEmpty ? 0.35 : 1)
                    .accessibilityLabel("Share")
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)

            ZStack(alignment: .top) {
                Avatar(user: model.me, size: 96).padding(.top, 76)
                TextField("Share a thought…", text: $text, axis: .vertical)
                    .font(.bodyC)
                    .multilineTextAlignment(.center)
                    .lineLimit(1...3)
                    .focused($focused)
                    .submitLabel(.done)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .frame(minWidth: 160, maxWidth: 300)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                    .shadow(color: .black.opacity(0.14), radius: 8, y: 6)
                    .frame(height: 96, alignment: .bottom)
                    .onChange(of: text) { _, v in if v.count > 60 { text = String(v.prefix(60)) } }
            }
            .padding(.top, 40)

            Text("\(text.count)/60")
                .font(.captionC.monospacedDigit())
                .foregroundStyle(Theme.label3)
                .padding(.top, 12)
            Text("Friends see it on your photo for 24 hours.")
                .font(.footnoteC)
                .foregroundStyle(Theme.label2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
                .padding(.top, 6)

            if model.myNote != nil {
                Button(role: .destructive) {
                    Task {
                        await model.clearNote()
                        dismiss()
                    }
                } label: {
                    HStack(spacing: 6) {
                        SymbolView(.trash, size: 18)
                        Text("Delete note").font(.subheadBoldC)
                    }
                    .foregroundStyle(Theme.red)
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                }
                .buttonStyle(.press)
                .padding(.top, 18)
            }
            Spacer(minLength: 18)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.grouped)
        .onAppear {
            text = model.myNote?.text ?? ""
            focused = true
        }
        .presentationDetents([.height(model.myNote != nil ? 470 : 420), .large])
        .presentationCornerRadius(30)
        .presentationBackground(Theme.grouped)
    }
}

/// Reading a friend's note, with a reply that starts a chat.
struct NoteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    @Environment(\.dismiss) private var dismiss
    let note: FriendNote
    @State private var reply = ""
    @FocusState private var focused: Bool

    private var trimmed: String { reply.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                GlassIconButton(sym: .xmark, title: "Close") { dismiss() }
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)

            ZStack(alignment: .top) {
                Avatar(user: note.user, size: 96).padding(.top, 76)
                NoteBubble(text: note.text, big: true).frame(height: 96, alignment: .bottom)
            }
            .padding(.top, 34)

            (Text(note.user.name).font(.subheadBoldC).foregroundStyle(Theme.label)
             + Text(" · " + Fmt.relative(Date(timeIntervalSince1970: TimeInterval(note.created) / 1000)))
                .font(.subheadC).foregroundStyle(Theme.label2))
                .padding(.top, 14)

            HStack(spacing: 8) {
                TextField("Reply to \(note.user.name)…", text: $reply)
                    .font(.bodyC)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(Theme.elevated, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
                Button(action: send) {
                    SymbolView(.arrowUp, size: 18, weight: 2.5)
                        .foregroundStyle(Theme.onInk)
                        .frame(width: 44, height: 44)
                        .background(Theme.ink, in: Circle())
                }
                .buttonStyle(.press(0.94))
                .disabled(trimmed.isEmpty)
                .opacity(trimmed.isEmpty ? 0.35 : 1)
                .accessibilityLabel("Send")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            Spacer(minLength: 16)
        }
        .frame(maxWidth: .infinity)
        .presentationDetents([.height(440), .large])
        .presentationCornerRadius(30)
        .presentationBackground(Theme.grouped)
    }

    private func send() {
        let text = trimmed
        guard !text.isEmpty else { return }
        Task {
            if let room = await model.replyToNote(note, text: text) {
                Haptics.success()
                dismiss()
                nav.open(room: room)
            }
        }
    }
}

// MARK: - Suggested and People you may know

struct PeopleSections: View {
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    @State private var requested: Set<String> = []
    @State private var showAll = false
    @AppStorage("ui:inviteDismissed") private var inviteDismissed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.suggested.isEmpty {
                title("Suggested")
                ForEach(model.suggested) { u in
                    Button {
                        Task { if let id = await model.openDM(u) { nav.open(room: id) } }
                    } label: {
                        personMain(u, sub: u.reason ?? String(localized: "Tap to chat"))
                    }
                    .buttonStyle(.press)
                    .padding(.horizontal, 22)
                }
                .padding(.bottom, 14)
            }
            if !model.discover.isEmpty || !inviteDismissed {
                HStack {
                    title("People you may know")
                    Spacer()
                    if model.discover.count > 5 {
                        Button(showAll ? "Less" : "See all") { withAnimation(Motion.ui) { showAll.toggle() } }
                            .font(.subheadBoldC)
                            .foregroundStyle(Theme.blueText)
                            .padding(.horizontal, 12)
                            .frame(height: 44)
                            .padding(.trailing, 10)
                    }
                }
                if !inviteDismissed {
                    InviteCard { withAnimation(Motion.ui) { inviteDismissed = true } }
                        .padding(.horizontal, 10)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
                ForEach(showAll ? model.discover : Array(model.discover.prefix(5))) { u in
                    discoverRow(u)
                        .padding(.horizontal, 10)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
        }
        .animation(Motion.ui, value: model.discover.map(\.id))
    }

    private func title(_ t: LocalizedStringKey) -> some View {
        Text(t)
            .font(.headlineC.weight(.bold))
            .tracking(-0.17)
            .foregroundStyle(Theme.label)
            .padding(.horizontal, 22)
            .padding(.vertical, 6)
    }

    private func personMain(_ u: User, sub: String) -> some View {
        HStack(spacing: 14) {
            Avatar(user: u, size: 52)
            VStack(alignment: .leading, spacing: 1) {
                Text(u.name).font(.headlineC).foregroundStyle(Theme.label).lineLimit(1)
                Text(sub).font(.subheadC).foregroundStyle(Theme.label2).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func discoverRow(_ u: User) -> some View {
        HStack(spacing: 8) {
            Button { nav.profile = u.id } label: { personMain(u, sub: subtitle(u)) }
                .buttonStyle(.press)
            let done = requested.contains(u.id)
            Button {
                guard !done else { return }
                Task {
                    if await model.addContact(u) != nil {
                        Haptics.success()
                        withAnimation(Motion.ui) { _ = requested.insert(u.id) }
                    }
                }
            } label: {
                Text(done ? "Requested" : "Add")
                    .font(AppFont.make(13, .semibold))
                    .foregroundStyle(done ? Theme.label2 : Theme.onInk)
                    .padding(.horizontal, 16)
                    .frame(minWidth: 84, minHeight: 36)
                    .background(done ? Theme.fill2 : Theme.ink, in: Capsule())
                    .contentTransition(.opacity)
            }
            .buttonStyle(.press)
            .disabled(done)
            Button {
                Task { await model.dismissPerson(u) }
            } label: {
                SymbolView(.xmark, size: 16).foregroundStyle(Theme.label2)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle().inset(by: -4))
            }
            .buttonStyle(.press(0.9))
            .accessibilityLabel("Don't suggest")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(minHeight: 72)
    }

    private func subtitle(_ u: User) -> String {
        if let m = u.mutual, m > 0 { return m == 1 ? String(localized: "1 mutual friend") : String(localized: "\(m) mutual friends") }
        return u.reason ?? "@\(u.username)"
    }
}

/// Invite friends: Share is white, a black line just inside its edge, blue words.
struct InviteCard: View {
    @Environment(AppModel.self) private var model
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 14) {
            SymbolView(.personPlus, size: 24)
                .foregroundStyle(Theme.label)
                .frame(width: 52, height: 52)
                .background(Theme.fill2, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("Invite friends").font(.headlineC).foregroundStyle(Theme.label)
                Text("Send friends a link to Cuven.").font(.subheadC).foregroundStyle(Theme.label2).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            ShareLink(item: model.serverURL) {
                Text("Share")
                    .font(AppFont.make(13, .semibold))
                    .foregroundStyle(Color(hex: 0x0062cc))
                    .padding(.horizontal, 16)
                    .frame(minWidth: 84, minHeight: 36)
                    .background(Color.white, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.black, lineWidth: 1))
            }
            .buttonStyle(.press)
            if let dismiss {
                Button(action: dismiss) {
                    SymbolView(.xmark, size: 16).foregroundStyle(Theme.label2)
                        .frame(width: 36, height: 36)
                        .glassCircle()
                }
                .buttonStyle(.press(0.9))
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
    }
}

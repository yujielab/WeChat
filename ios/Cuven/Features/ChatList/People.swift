import SwiftUI

// People (views/people.js, css/people.css): notes along the top of the
// Messages list — a bubble resting on the top of each photo, yours first —
// and, on Friends, People you may know.

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
    @Environment(Nav.self) private var nav
    @State private var text = ""
    @State private var sending = false
    @FocusState private var focused: Bool
    /// The card's height: with the keyboard up it can be short of the
    /// whole layout, and the photo under the bubble shrinks to stay in view.
    @State private var room: CGFloat = 400

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var tight: Bool { room < 330 }
    private var avatarSize: CGFloat { room < 270 ? 52 : tight ? 68 : 96 }
    /// Above the photo, room for the bubble to grow to three lines.
    private var bubbleRoom: CGFloat { tight ? 64 : 96 }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Note").font(.headlineC).foregroundStyle(Theme.label)
                HStack {
                    GlassIconButton(sym: .xmark, title: "Cancel") { close() }
                    Spacer()
                    Button {
                        sending = true
                        Task {
                            await model.setNote(trimmed)
                            Haptics.success()
                            close()
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
            .frame(minHeight: 56)

            ScrollView {
                noteBody
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { room = $0 }
        .onAppear {
            text = model.myNote?.text ?? ""
            focused = true
        }
    }

    private var noteBody: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Avatar(user: model.me, size: avatarSize).padding(.top, bubbleRoom - avatarSize * 0.21)
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
                    .frame(height: bubbleRoom, alignment: .bottom)
                    .onChange(of: text) { _, v in if v.count > 60 { text = String(v.prefix(60)) } }
            }
            .padding(.top, tight ? 8 : 28)
            .animation(Motion.ui, value: avatarSize)

            Text("\(text.count)/60")
                .font(.captionC.monospacedDigit())
                .foregroundStyle(Theme.label3)
                .padding(.top, 12)
            if room >= 270 {
                Text("Friends see it on your photo for 24 hours.")
                    .font(.footnoteC)
                    .foregroundStyle(Theme.label2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                    .padding(.top, 6)
            }

            if model.myNote != nil {
                Button(role: .destructive) {
                    Task {
                        await model.clearNote()
                        close()
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
                .padding(.top, tight ? 8 : 18)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 18)
    }

    private func close() {
        focused = false
        withAnimation(Motion.move) { nav.noteEditor = false }
    }
}

/// Reading a friend's note, with a reply that starts a chat.
struct NoteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    let note: FriendNote
    @State private var reply = ""
    @FocusState private var focused: Bool

    private var trimmed: String { reply.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                GlassIconButton(sym: .xmark, title: "Close") { close() }
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 56)

            ZStack(alignment: .top) {
                Avatar(user: note.user, size: 96).padding(.top, 76)
                NoteBubble(text: note.text, big: true).frame(height: 96, alignment: .bottom)
            }
            .padding(.top, 20)

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
    }

    private func close() {
        focused = false
        withAnimation(Motion.move) { nav.openNote = nil }
    }

    private func send() {
        let text = trimmed
        guard !text.isEmpty else { return }
        Task {
            if let room = await model.replyToNote(note, text: text) {
                Haptics.success()
                close()
                nav.open(room: room)
            }
        }
    }
}

// MARK: - People you may know

/// People you may know, on Friends. (Friends you've not messaged yet are in
/// its Contacts list, so they aren't suggested again here.)
struct PeopleSections: View {
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    @State private var requested: Set<String> = []
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.discover.isEmpty {
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
                RowAction(title: done ? "Requested" : "Add", ink: !done, quiet: done)
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
        // The server's reasons, in the reader's language (only the known ones).
        switch u.reason {
        case "Shares moments"?: return String(localized: "Shares moments")
        case "New on Cuven"?: return String(localized: "New on Cuven")
        default: return "@\(u.username)"
        }
    }
}

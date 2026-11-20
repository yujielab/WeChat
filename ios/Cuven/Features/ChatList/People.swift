import SwiftUI

// MARK: - Notes row (a line for friends, above your photo, for a day)

struct NotesRow: View {
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                noteItem(user: model.me, text: model.myNote?.text, mine: true) {
                    nav.noteEditor = true
                }
                ForEach(model.notes) { n in
                    noteItem(user: n.user, text: n.text, mine: false) {
                        nav.openNote = n
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 2)
        }
        .scrollClipDisabled()
    }

    private func noteItem(user: User?, text: String?, mine: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .top) {
                    Avatar(user: user, size: 66)
                        .padding(.top, 34)
                        .overlay(alignment: .bottomTrailing) {
                            if mine && text == nil {
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .heavy))
                                    .foregroundStyle(.white)
                                    .frame(width: 22, height: 22)
                                    .background(Theme.blue, in: Circle())
                                    .overlay(Circle().stroke(Theme.bg, lineWidth: 2.5))
                            }
                        }
                    ThoughtBubble(text: text ?? (mine ? String(localized: "Share a thought…") : ""), placeholder: text == nil)
                }
                Text(mine ? String(localized: "Your note") : (user?.name ?? ""))
                    .font(.captionC)
                    .foregroundStyle(Theme.label2)
                    .lineLimit(1)
                    .frame(width: 76)
            }
        }
        .buttonStyle(.press(0.94))
    }
}

struct ThoughtBubble: View {
    let text: String
    var placeholder = false

    var body: some View {
        Text(text)
            .font(AppFont.make(12, placeholder ? .regular : .medium))
            .foregroundStyle(placeholder ? Theme.label3 : Theme.label)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: 96)
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
            .overlay(alignment: .bottomLeading) {
                Circle().fill(Theme.elevated).frame(width: 9, height: 9)
                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                    .offset(x: 18, y: 6)
            }
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct NoteEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Button("Cancel") { dismiss() }.foregroundStyle(Theme.label2)
                Spacer()
                Text("Your note").font(.headlineC)
                Spacer()
                Button("Share") {
                    Task {
                        await model.setNote(text)
                        dismiss()
                    }
                }
                .font(.headlineC)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ZStack(alignment: .top) {
                Avatar(user: model.me, size: 72).padding(.top, 44)
                TextField("Share a thought…", text: $text)
                    .font(AppFont.make(15, .medium))
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: 260)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .onChange(of: text) { _, v in if v.count > 60 { text = String(v.prefix(60)) } }
            }
            HStack {
                Text("Friends see it for 24 hours").font(.footnoteC).foregroundStyle(Theme.label3)
                Spacer()
                Text("\(60 - text.count)").font(.footnoteC.monospacedDigit()).foregroundStyle(text.count > 50 ? Theme.orange : Theme.label3)
            }
            if model.myNote != nil {
                Button("Delete note", role: .destructive) {
                    Task {
                        await model.clearNote()
                        dismiss()
                    }
                }
                .font(.subheadMediumC)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .onAppear {
            text = model.myNote?.text ?? ""
            focused = true
        }
    }
}

struct NoteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    @Environment(\.dismiss) private var dismiss
    let note: FriendNote
    @State private var reply = ""

    var body: some View {
        VStack(spacing: 16) {
            Capsule().fill(Theme.line).frame(width: 36, height: 5).padding(.top, 8)
            Avatar(user: note.user, size: 64)
            Text(note.user.name).font(.headlineC)
            Text(note.text)
                .font(AppFont.make(26, .bold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text(Fmt.relative(Date(timeIntervalSince1970: TimeInterval(note.created) / 1000)))
                .font(.footnoteC).foregroundStyle(Theme.label3)
            Spacer()
            HStack(spacing: 10) {
                TextField("Reply to \(note.user.name)…", text: $reply)
                    .font(.bodyC)
                    .padding(.horizontal, 16)
                    .frame(height: 46)
                    .background(Theme.field, in: Capsule())
                Button {
                    let text = reply
                    Task {
                        if let room = await model.replyToNote(note, text: text) {
                            dismiss()
                            nav.open(room: room)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 46, height: 46).background(Theme.blue, in: Circle())
                }
                .disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(reply.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
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
        VStack(alignment: .leading, spacing: 10) {
            if !model.suggested.isEmpty {
                sectionTitle("Suggested")
                ForEach(model.suggested) { u in
                    PersonRow(user: u, subtitle: u.reason ?? String(localized: "Tap to chat"))
                }
            }
            if !model.discover.isEmpty || !inviteDismissed {
                HStack {
                    sectionTitle("People you may know")
                    Spacer()
                    if model.discover.count > 5 {
                        Button(showAll ? "Less" : "See all") { withAnimation(Motion.ui) { showAll.toggle() } }
                            .font(.subheadMediumC)
                    }
                }
                if !inviteDismissed { inviteCard }
                ForEach(showAll ? model.discover : Array(model.discover.prefix(5))) { u in
                    discoverRow(u)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
        }
        .padding(.top, 18)
        .padding(.horizontal, 10)
    }

    private func sectionTitle(_ t: LocalizedStringKey) -> some View {
        Text(t).font(.headlineC).foregroundStyle(Theme.label).padding(.horizontal, 10)
    }

    private var inviteCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "envelope.open.fill")
                .font(.system(size: 20))
                .foregroundStyle(Theme.blue)
                .frame(width: 46, height: 46)
                .background(Theme.blue.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Invite friends").font(.headlineC)
                Text("Share a link to this server").font(.footnoteC).foregroundStyle(Theme.label2)
            }
            Spacer()
            ShareLink(item: model.serverURL) {
                Text("Share").font(.subheadMediumC).foregroundStyle(Theme.blue)
                    .padding(.horizontal, 14).frame(height: 32)
                    .overlay(Capsule().stroke(Theme.ink, lineWidth: 1))
            }
            Button { withAnimation(Motion.ui) { inviteDismissed = true } } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.label3)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func discoverRow(_ u: User) -> some View {
        HStack(spacing: 12) {
            Button { nav.profile = u.id } label: {
                HStack(spacing: 12) {
                    Avatar(user: u, size: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(u.name).font(.headlineC).foregroundStyle(Theme.label)
                        Text(subtitle(u)).font(.footnoteC).foregroundStyle(Theme.label2).lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            let done = requested.contains(u.id)
            Button {
                guard !done else { return }
                Task {
                    if await model.addContact(u) != nil { withAnimation(Motion.ui) { _ = requested.insert(u.id) } }
                }
            } label: {
                Text(done ? "Requested" : "Add")
                    .font(.subheadMediumC)
                    .foregroundStyle(done ? Theme.label2 : .white)
                    .padding(.horizontal, 16).frame(height: 32)
                    .background(done ? Theme.fillQuiet : Theme.blue, in: Capsule())
                    .contentTransition(.opacity)
            }
            .buttonStyle(.press)
            Button {
                Task { await model.dismissPerson(u) }
            } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.label3)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Don't suggest")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func subtitle(_ u: User) -> String {
        if let m = u.mutual, m > 0 { return m == 1 ? String(localized: "1 mutual friend") : String(localized: "\(m) mutual friends") }
        return u.reason ?? "@\(u.username)"
    }
}

// MARK: - Requests page

struct RequestsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    @Environment(\.column) private var ctx

    var body: some View {
        ZStack {
            Theme.bg
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Requests").font(.largeTitleC).foregroundStyle(Theme.blue)
                        .padding(.horizontal, 20)
                    if model.requests.isEmpty && model.sentRequests.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "person.crop.circle.badge.checkmark").font(.system(size: 40, weight: .light)).foregroundStyle(Theme.label3)
                            Text("No requests right now").font(.subheadC).foregroundStyle(Theme.label2)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 60)
                    }
                    if !model.requests.isEmpty {
                        Text("Want to add you").font(.footnoteC.weight(.semibold)).foregroundStyle(Theme.label2).padding(.horizontal, 20)
                        ForEach(model.requests) { u in
                            HStack(spacing: 12) {
                                Avatar(user: u, size: 50)
                                VStack(alignment: .leading) {
                                    Text(u.name).font(.headlineC)
                                    Text("@\(u.username)").font(.footnoteC).foregroundStyle(Theme.label2)
                                }
                                Spacer()
                                Button("Accept") { Task { await model.acceptContact(u) } }
                                    .font(.subheadMediumC).foregroundStyle(.white)
                                    .padding(.horizontal, 16).frame(height: 34).background(Theme.blue, in: Capsule())
                                    .buttonStyle(.press)
                                Button { Task { await model.removeContact(u) } } label: {
                                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.label2)
                                        .frame(width: 34, height: 34).background(Theme.fillQuiet, in: Circle())
                                }
                                .buttonStyle(.press)
                            }
                            .padding(.horizontal, 20)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                        }
                    }
                    if !model.sentRequests.isEmpty {
                        Text("Sent").font(.footnoteC.weight(.semibold)).foregroundStyle(Theme.label2).padding(.horizontal, 20).padding(.top, 8)
                        ForEach(model.sentRequests) { u in
                            HStack(spacing: 12) {
                                Avatar(user: u, size: 50)
                                VStack(alignment: .leading) {
                                    Text(u.name).font(.headlineC)
                                    Text("@\(u.username)").font(.footnoteC).foregroundStyle(Theme.label2)
                                }
                                Spacer()
                                Button("Cancel") { Task { await model.removeContact(u) } }
                                    .font(.subheadMediumC).foregroundStyle(Theme.label)
                                    .padding(.horizontal, 16).frame(height: 34).background(Theme.fillQuiet, in: Capsule())
                                    .buttonStyle(.press)
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                }
                .padding(.top, 12)
                .animation(Motion.ui, value: model.contacts)
            }
            .safeAreaPadding(EdgeInsets(top: ctx.insets.top, leading: ctx.insets.leading, bottom: ctx.insets.bottom + 80,
                                        trailing: ctx.insets.trailing))
            .refreshable { await model.refreshContacts() }

            if ctx.rail == nil {
                ColumnBar(back: BarItem(id: "close", symbol: "chevron.left", title: "Back") { nav.switchPage(.chats) })
                    .environment(\.column, ctx)
            }
        }
    }
}

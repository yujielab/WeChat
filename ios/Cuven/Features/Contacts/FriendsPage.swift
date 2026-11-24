import SwiftUI

/// Friends (views/people.js openRequests): find people by username, start a
/// group or invite someone, who wants to add you, what you've sent, and
/// everyone you're friends with.
struct FriendsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    @Environment(\.column) private var ctx
    @State private var query = ""
    @State private var results: [User] = []
    @State private var searching = false
    @State private var adding: Set<String> = []
    @FocusState private var searchFocused: Bool
    /// The friend about to be removed, asked first.
    @State private var removing: User?

    private var friends: [User] {
        model.contacts.filter { $0.state == "accepted" }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        PageScaffold(title: .large("Friends", Theme.label),
                     back: ctx.rail == nil ? BarItem(id: "back", sym: .chevronLeft, title: "Back") { nav.switchPage(.chats) } : nil,
                     actions: [BarItem(id: "group", sym: .people, title: "New group") { nav.newGroup = true }],
                     background: Theme.grouped) {
            HStack(spacing: 10) {
                SymbolView(.search, size: 18).foregroundStyle(Theme.label2)
                TextField("Find people by username", text: $query)
                    .font(.bodyC)
                    .focused($searchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        SymbolView(.xmark, size: 13, weight: 2.2).foregroundStyle(Theme.label2)
                            .frame(width: 26, height: 26).background(Theme.fill3, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 48)
            .glassCapsule(interactive: false)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        } content: {
            VStack(spacing: 0) {
                if !query.isEmpty {
                    searchResults
                } else {
                    content
                }
            }
            .animation(Motion.ui, value: model.contacts)
            .animation(Motion.ui, value: query.isEmpty)
        }
        .refreshable { await model.refreshContacts() }
        .confirmationDialog(Text("Remove \(removing?.name ?? "") from your friends?"),
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove friend", role: .destructive) {
                if let u = removing { Task { await model.removeContact(u) } }
                removing = nil
            }
        }
        .task(id: query) {
            guard !query.isEmpty else { results = []; return }
            searching = true
            try? await Task.sleep(for: .milliseconds(250))
            let r = await model.searchUsers(query)
            if !Task.isCancelled {
                withAnimation(Motion.ui) { results = r }
                searching = false
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        GroupCard {
            Button { nav.newGroup = true } label: { Cell(icon: .people, title: "New group", chevron: true) }
                .buttonStyle(CellButtonStyle())
            CellSeparator(leading: 58)
            ShareLink(item: model.serverURL, message: Text("Chat with me on Cuven")) {
                Cell(icon: .personPlus, title: "Invite friends", chevron: true)
            }
            .buttonStyle(CellButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)

        if !model.requests.isEmpty {
            eyebrow("Wants to add you")
            ForEach(model.requests) { u in
                personRow(u, sub: "@\(u.username)") {
                    Button {
                        Task { await model.acceptContact(u) }
                    } label: {
                        Text("Accept")
                            .font(AppFont.make(15, .semibold))
                            .foregroundStyle(Theme.onInk)
                            .padding(.horizontal, 20)
                            .frame(height: 40)
                            .glassEffect(.regular.tint(Theme.ink.opacity(0.85)).interactive(), in: Capsule())
                    }
                    .buttonStyle(.press)
                    Button {
                        Task { await model.removeContact(u) }
                    } label: {
                        SymbolView(.xmark, size: 16).foregroundStyle(Theme.label2)
                            .frame(width: 40, height: 40)
                            .glassCircle()
                    }
                    .buttonStyle(.press(0.9))
                    .accessibilityLabel("Decline")
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }

        if !model.sentRequests.isEmpty {
            eyebrow("Sent")
            ForEach(model.sentRequests) { u in
                personRow(u, sub: String(localized: "Request sent")) {
                    Button {
                        Task { await model.removeContact(u) }
                    } label: {
                        Text("Cancel")
                            .font(AppFont.make(15, .semibold))
                            .foregroundStyle(Theme.label)
                            .padding(.horizontal, 20)
                            .frame(height: 40)
                            .glassCapsule()
                    }
                    .buttonStyle(.press)
                }
                .transition(.opacity)
            }
        }

        if friends.isEmpty && model.requests.isEmpty && model.sentRequests.isEmpty {
            VStack(spacing: 6) {
                SymbolView(.people, size: 34).foregroundStyle(Theme.label3).padding(.bottom, 6)
                Text("No friends yet").font(.headlineC).foregroundStyle(Theme.label)
                Text("Find people by their username, or invite them.")
                    .font(.subheadC).lineSpacing(3).foregroundStyle(Theme.label2).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, 48)
        }

        if !friends.isEmpty {
            GroupTitle(text: "Contacts").padding(.horizontal, 20).padding(.top, 6)
            GroupCard {
                ForEach(Array(friends.enumerated()), id: \.element.id) { i, u in
                    if i > 0 { CellSeparator(leading: 72) }
                    // A row with a chevron opens their page (which has Message);
                    // messaging straight away is in the row's menu.
                    Button { nav.profile = u.id } label: {
                        HStack(spacing: 16) {
                            Avatar(user: u, size: 40, online: model.isOnline(u.id))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(u.name).font(.bodyC).foregroundStyle(Theme.label).lineLimit(1)
                                Text("@\(u.username)").font(.footnoteC).foregroundStyle(Theme.label2).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            SymbolView(.chevronRight, size: 14).foregroundStyle(Theme.label3)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(CellButtonStyle())
                    .contextMenu {
                        Button {
                            Task { if let id = await model.openDM(u) { nav.open(room: id) } }
                        } label: { Label("Message", systemImage: "bubble.left") }
                        Button { nav.profile = u.id } label: { Label("View profile", systemImage: "person.crop.circle") }
                        Divider()
                        Button(role: .destructive) { removing = u } label: { Label("Remove friend", systemImage: "person.badge.minus") }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        eyebrow("On Cuven")
        if searching && results.isEmpty {
            ProgressView().padding(.vertical, 24)
        } else if results.isEmpty {
            Text("No one called “\(query)”")
                .font(.subheadC).foregroundStyle(Theme.label2)
                .padding(.vertical, 24)
        }
        ForEach(results) { u in
            personRow(u, sub: "@\(u.username)") { resultAction(u) }
        }
    }

    @ViewBuilder
    private func resultAction(_ u: User) -> some View {
        switch u.state {
        case "accepted":
            Button {
                Task { if let id = await model.openDM(u) { nav.open(room: id) } }
            } label: {
                pill("Message", ink: false)
            }
            .buttonStyle(.press)
        case "pending_out":
            pill("Requested", ink: false, quiet: true)
        case "pending_in":
            Button { Task { await model.acceptContact(u); await refreshResults() } } label: { pill("Accept", ink: true) }
                .buttonStyle(.press)
        default:
            if u.id != model.me?.id {
                Button {
                    adding.insert(u.id)
                    Task {
                        await model.addContact(u)
                        await refreshResults()
                        adding.remove(u.id)
                    }
                } label: {
                    pill("Add", ink: true).opacity(adding.contains(u.id) ? 0.5 : 1)
                }
                .buttonStyle(.press)
                .disabled(adding.contains(u.id))
            }
        }
    }

    /// The web's .person-action: 36pt, at least 84 wide, fill-2 or ink.
    private func pill(_ t: LocalizedStringKey, ink: Bool, quiet: Bool = false) -> some View {
        Text(t)
            .font(AppFont.make(13, .semibold))
            .foregroundStyle(ink ? Theme.onInk : (quiet ? Theme.label2 : Theme.label))
            .padding(.horizontal, 16)
            .frame(minWidth: 84, minHeight: 36)
            .background(ink ? Theme.ink : Theme.fill2, in: Capsule())
    }

    private func refreshResults() async {
        let r = await model.searchUsers(query)
        withAnimation(Motion.ui) { results = r }
    }

    /// The people sheet's eyebrows sit close over their rows.
    private func eyebrow(_ t: LocalizedStringKey) -> some View {
        Text(t)
            .textCase(.uppercase)
            .font(AppFont.make(13, .semibold))
            .tracking(0.52)
            .foregroundStyle(Theme.label2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 2)
    }

    private func personRow<Actions: View>(_ u: User, sub: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 8) {
            Button { nav.profile = u.id } label: {
                HStack(spacing: 14) {
                    Avatar(user: u, size: 52, online: model.isOnline(u.id))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(u.name).font(.headlineC).foregroundStyle(Theme.label).lineLimit(1)
                        Text(sub).font(.subheadC).foregroundStyle(Theme.label2).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.press)
            actions()
        }
        .padding(.leading, 22)
        .padding(.trailing, 20)
    }
}

/// A new group: a name, and the friends to start it with.
struct NewGroupView: View {
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    @State private var name = ""
    @State private var picked: Set<String> = []
    @State private var creating = false

    private var friends: [User] {
        model.contacts.filter { $0.state == "accepted" }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        PageScaffold(title: .inline("New group"),
                     back: BarItem(id: "cancel", sym: .xmark, title: "Cancel") { close() },
                     actions: [BarItem(id: "create", sym: .check, title: "Create", tint: picked.isEmpty ? nil : Theme.ink.opacity(0.9),
                                       foreground: picked.isEmpty ? Theme.label3 : Theme.onInk) { create() }],
                     background: Theme.grouped) {
            VStack(spacing: 0) {
                GroupCard {
                    TextField("Group name", text: $name)
                        .font(.bodyC)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 58)
                }
                GroupFoot(text: "\(picked.count) selected")
                GroupTitle(text: "Friends")
                if friends.isEmpty {
                    Text("Add friends first, then start a group with them.")
                        .font(.subheadC).foregroundStyle(Theme.label2)
                        .padding(.vertical, 24)
                } else {
                    GroupCard {
                        ForEach(Array(friends.enumerated()), id: \.element.id) { i, u in
                            if i > 0 { CellSeparator(leading: 66) }
                            friendRow(u)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
    }

    private func close() {
        withAnimation(Motion.move) { nav.newGroup = false }
    }

    private func friendRow(_ u: User) -> some View {
        let on = picked.contains(u.id)
        return Button {
            if on { picked.remove(u.id) } else { picked.insert(u.id) }
            Haptics.selection()
        } label: {
            HStack(spacing: 12) {
                Avatar(user: u, size: 40)
                Text(u.name).font(.bodyC).foregroundStyle(Theme.label)
                Spacer(minLength: 0)
                SymbolView(.check, size: 15, weight: 2.4)
                    .foregroundStyle(Theme.onInk)
                    .opacity(on ? 1 : 0)
                    .frame(width: 26, height: 26)
                    .background(on ? Theme.ink : .clear, in: Circle())
                    .overlay(Circle().strokeBorder(on ? .clear : Theme.label3, lineWidth: 1.5))
                    .animation(.easeOut(duration: 0.14), value: on)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(CellButtonStyle())
    }

    private func create() {
        guard !picked.isEmpty, !creating else {
            if picked.isEmpty { model.show(String(localized: "Pick at least one friend")) }
            return
        }
        creating = true
        Task {
            if let id = await model.createGroup(name: name.trimmingCharacters(in: .whitespaces), members: Array(picked)) {
                Haptics.success()
                withAnimation(Motion.move) {
                    nav.newGroup = false
                    nav.page = .chats
                }
                nav.open(room: id)
            }
            creating = false
        }
    }
}

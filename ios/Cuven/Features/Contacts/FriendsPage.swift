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

    private var friends: [User] {
        model.contacts.filter { $0.state == "accepted" }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                SheetHeader(title: "Friends", large: true) { SheetClose() }
                    .padding(.top, 10)

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
                .padding(.top, 6)

                if !query.isEmpty {
                    searchResults
                } else {
                    content
                }
            }
            .padding(.bottom, max(ctx.insets.bottom, 16) + 24)
            .animation(Motion.ui, value: model.contacts)
            .animation(Motion.ui, value: query.isEmpty)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.grouped)
        .refreshable { await model.refreshContacts() }
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
            GroupTitle(text: "Contacts").padding(.horizontal, 20).padding(.top, 14)
            GroupCard {
                ForEach(Array(friends.enumerated()), id: \.element.id) { i, u in
                    if i > 0 { CellSeparator(leading: 72) }
                    Button {
                        Task { if let id = await model.openDM(u) { nav.open(room: id) } }
                    } label: {
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
                        Button { nav.profile = u.id } label: { Label("View profile", systemImage: "person.crop.circle") }
                        Button(role: .destructive) { Task { await model.removeContact(u) } } label: { Label("Remove friend", systemImage: "person.badge.minus") }
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

    private func eyebrow(_ t: LocalizedStringKey) -> some View {
        GroupTitle(text: t).padding(.horizontal, 8)
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
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var picked: Set<String> = []
    @State private var creating = false

    private var friends: [User] {
        model.contacts.filter { $0.state == "accepted" }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "New group", centered: true) {
                GlassIconButton(sym: .xmark, title: "Cancel") { dismiss() }
            } trailing: {
                Button(action: create) {
                    SymbolView(.check, size: 20, weight: 2.4)
                        .foregroundStyle(Theme.onInk)
                        .frame(width: 44, height: 44)
                        .background(Theme.ink, in: Circle())
                }
                .buttonStyle(.press(0.94))
                .disabled(picked.isEmpty || creating)
                .opacity(picked.isEmpty ? 0.35 : 1)
                .accessibilityLabel("Create")
            }
            ScrollView {
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
                .padding(.bottom, 24)
            }
        }
        .background(Theme.grouped)
        .presentationDetents([.large])
        .presentationCornerRadius(30)
        .presentationBackground(Theme.grouped)
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
        creating = true
        Task {
            if let id = await model.createGroup(name: name.trimmingCharacters(in: .whitespaces), members: Array(picked)) {
                Haptics.success()
                dismiss()
                nav.page = .chats
                nav.open(room: id)
            }
            creating = false
        }
    }
}

import SwiftUI

/// New chat, folded into Friends: your contacts (and who wants to add you),
/// a search for anyone on the server, a new group, and inviting friends.
struct NewChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [User] = []
    @State private var searching = false
    @State private var groupMode = false
    @State private var picked: Set<String> = []
    @State private var groupName = ""
    @State private var pendingAdds: Set<String> = []

    private var contacts: [User] {
        let order = ["pending_in": 0, "accepted": 1, "pending_out": 2]
        return model.contacts.sorted {
            let a = order[$0.state ?? ""] ?? 3, b = order[$1.state ?? ""] ?? 3
            return a == b ? $0.name.localizedCompare($1.name) == .orderedAscending : a < b
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !groupMode {
                    Section {
                        Button {
                            withAnimation(Motion.ui) { groupMode = true }
                        } label: {
                            Label {
                                Text("New group").font(.bodyC).foregroundStyle(Theme.label)
                            } icon: {
                                Image(systemName: "person.3.fill").foregroundStyle(.white)
                                    .frame(width: 36, height: 36).background(Theme.blue, in: Circle())
                            }
                        }
                        ShareLink(item: model.serverURL, message: Text("Chat with me on Cuven")) {
                            Label {
                                Text("Invite friends").font(.bodyC).foregroundStyle(Theme.label)
                            } icon: {
                                Image(systemName: "square.and.arrow.up").foregroundStyle(Theme.blue)
                                    .frame(width: 36, height: 36).background(Theme.blue.opacity(0.12), in: Circle())
                            }
                        }
                    }
                } else {
                    Section {
                        TextField("Group name", text: $groupName).font(.bodyC)
                    } footer: {
                        Text("\(picked.count) selected")
                    }
                }

                if !query.isEmpty {
                    Section("On this server") {
                        if searching && results.isEmpty { ProgressView() }
                        ForEach(results) { u in userRow(u) }
                        if !searching && results.isEmpty {
                            Text("No one called “\(query)”").foregroundStyle(Theme.label2)
                        }
                    }
                }

                Section(model.contacts.isEmpty ? "" : String(localized: "Contacts")) {
                    ForEach(contacts.filter { query.isEmpty || $0.name.lowercased().contains(query.lowercased()) || $0.username.lowercased().contains(query.lowercased()) }) { u in
                        userRow(u)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search by username")
            .navigationTitle(groupMode ? "New group" : "New chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(groupMode ? "Back" : "Cancel") {
                        if groupMode { withAnimation(Motion.ui) { groupMode = false; picked = [] } } else { dismiss() }
                    }
                }
                if groupMode {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") {
                            Task {
                                if let id = await model.createGroup(name: groupName.trimmingCharacters(in: .whitespaces), members: Array(picked)) {
                                    dismiss()
                                    nav.open(room: id)
                                }
                            }
                        }
                        .disabled(picked.isEmpty)
                    }
                }
            }
            .task(id: query) {
                guard !query.isEmpty else { results = []; return }
                searching = true
                try? await Task.sleep(for: .milliseconds(250))
                let r = await model.searchUsers(query)
                if !Task.isCancelled {
                    results = r
                    searching = false
                }
            }
        }
    }

    @ViewBuilder
    private func userRow(_ u: User) -> some View {
        HStack(spacing: 12) {
            Avatar(user: u, size: 42, online: model.isOnline(u.id))
            VStack(alignment: .leading, spacing: 1) {
                Text(u.name).font(.bodyC).foregroundStyle(Theme.label)
                Text(stateText(u)).font(.captionC).foregroundStyle(u.state == "pending_in" ? Theme.blue : Theme.label2)
            }
            Spacer()
            if groupMode {
                Image(systemName: picked.contains(u.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(picked.contains(u.id) ? Theme.blue : Theme.label3)
            } else {
                trailing(u)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if groupMode {
                if picked.contains(u.id) { picked.remove(u.id) } else { picked.insert(u.id) }
                Haptics.selection()
            } else {
                Task {
                    if let id = await model.openDM(u) {
                        dismiss()
                        nav.open(room: id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func trailing(_ u: User) -> some View {
        let state = model.contacts.first(where: { $0.id == u.id })?.state ?? u.state
        if state == "pending_in" {
            Button("Accept") { Task { await model.acceptContact(u) } }
                .font(.subheadMediumC).foregroundStyle(.white)
                .padding(.horizontal, 14).frame(height: 30).background(Theme.blue, in: Capsule())
                .buttonStyle(.borderless)
        } else if state == nil && !pendingAdds.contains(u.id) {
            Button("Add") {
                pendingAdds.insert(u.id)
                Task { await model.addContact(u) }
            }
            .font(.subheadMediumC).foregroundStyle(Theme.blue)
            .padding(.horizontal, 14).frame(height: 30).background(Theme.blue.opacity(0.12), in: Capsule())
            .buttonStyle(.borderless)
        } else if state == "pending_out" || pendingAdds.contains(u.id) {
            Text("Requested").font(.captionC).foregroundStyle(Theme.label3)
        }
    }

    private func stateText(_ u: User) -> String {
        switch model.contacts.first(where: { $0.id == u.id })?.state ?? u.state {
        case "pending_in": return String(localized: "Wants to add you")
        case "pending_out": return String(localized: "Requested · @\(u.username)")
        default: return "@\(u.username)"
        }
    }
}

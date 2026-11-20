import SwiftUI

/// The details column beside a conversation: who it is, quick actions,
/// mute and pin, members for a group, and the photos shared here.
struct ChatInfoView: View {
    let roomId: String
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    @Environment(\.column) private var ctx
    @State private var inviting = false
    @State private var confirmLeave = false
    @State private var confirmDelete = false

    private var room: Room? { model.room(roomId) }

    var body: some View {
        ZStack {
            Theme.grouped
            if let room {
                ScrollView {
                    VStack(spacing: 22) {
                        hero(room)
                        quickActions(room)
                        settings(room)
                        if room.isGroup { members(room) }
                        sharedMedia
                        dangerZone(room)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 24)
                }
                .safeAreaPadding(EdgeInsets(top: ctx.insets.top, leading: ctx.insets.leading,
                                            bottom: ctx.usesRail ? ctx.insets.bottom + 12 : ctx.barClearance,
                                            trailing: ctx.insets.trailing))
            }
            ColumnBar(back: BarItem(id: "close", symbol: nav.columns == 1 ? "chevron.left" : "xmark",
                                    title: nav.columns == 1 ? "Back" : "Close") { nav.closeDetail() })
        }
        .task(id: roomId) {
            if room?.isGroup == true { await model.loadMembers(roomId) }
        }
        .sheet(isPresented: $inviting) {
            PeoplePicker(title: "Add people", exclude: Set((model.members[roomId] ?? []).map(\.id))) { ids in
                Task { await model.invite(ids, to: roomId) }
            }
        }
        .confirmationDialog("Leave this group?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave group", role: .destructive) {
                Task {
                    await model.leaveGroup(roomId)
                    nav.closeDetail()
                    nav.backFromChat()
                }
            }
        }
        .confirmationDialog("Delete this chat?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete chat", role: .destructive) {
                Task {
                    await model.deleteChat(roomId)
                    nav.closeDetail()
                    nav.backFromChat()
                }
            }
        } message: {
            Text("It comes back if someone sends a new message.")
        }
    }

    private func hero(_ room: Room) -> some View {
        VStack(spacing: 8) {
            Avatar(path: room.avatar, name: room.title, id: room.peer?.id ?? room.id, size: 96,
                   online: !room.isGroup && model.isOnline(room.peer?.id))
            Text(room.title).font(.title2C).foregroundStyle(Theme.label).multilineTextAlignment(.center)
            if let peer = room.peer, !room.isGroup {
                Text("@\(peer.username)").font(.subheadC).foregroundStyle(Theme.label2)
                if !peer.bio.isEmpty {
                    Text(peer.bio).font(.subheadC).foregroundStyle(Theme.label).multilineTextAlignment(.center).padding(.top, 2)
                }
            } else {
                Text("\(room.count) members").font(.subheadC).foregroundStyle(Theme.label2)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func quickActions(_ room: Room) -> some View {
        HStack(spacing: 10) {
            if model.callsEnabled {
                quick("phone.fill", "Call") { model.calls.start(room: room, video: false) }
                quick("video.fill", "Video") { model.calls.start(room: room, video: true) }
            }
            quick(room.muted ? "bell.slash.fill" : "bell.fill", room.muted ? "Unmute" : "Mute") {
                Task { await model.setFlag(room.id, muted: !room.muted) }
            }
            if let peer = room.peer, !room.isGroup {
                quick("photo.on.rectangle.angled", "Moments") { nav.profile = peer.id }
            } else {
                quick("person.badge.plus", "Add") { inviting = true }
            }
        }
    }

    private func quick(_ symbol: String, _ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.blue)
                    .contentTransition(.symbolEffect(.replace))
                Text(title).font(.caption2C).foregroundStyle(Theme.label)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.press)
    }

    private func settings(_ room: Room) -> some View {
        VStack(spacing: 0) {
            toggleRow("Mute notifications", symbol: "bell.slash", isOn: room.muted) { v in
                Task { await model.setFlag(room.id, muted: v) }
            }
            Hairline().padding(.leading, 52)
            toggleRow("Pin chat", symbol: "pin", isOn: room.pinned) { v in
                Task { await model.setFlag(room.id, pinned: v) }
            }
        }
        .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func toggleRow(_ title: LocalizedStringKey, symbol: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: set)) {
            HStack(spacing: 14) {
                Image(systemName: symbol).foregroundStyle(Theme.blue).frame(width: 22)
                Text(title).font(.bodyC)
            }
        }
        .tint(Theme.blue)
        .padding(.horizontal, 16)
        .frame(height: 50)
    }

    private func members(_ room: Room) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Members").font(.footnoteC.weight(.semibold)).foregroundStyle(Theme.label2).padding(.leading, 6)
            VStack(spacing: 0) {
                Button { inviting = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.blue)
                            .frame(width: 38, height: 38).background(Theme.blue.opacity(0.12), in: Circle())
                        Text("Add people").font(.bodyC).foregroundStyle(Theme.blue)
                        Spacer()
                    }
                    .padding(.horizontal, 14).frame(height: 56)
                }
                .buttonStyle(.press(0.99))
                ForEach(model.members[room.id] ?? []) { m in
                    Hairline().padding(.leading, 64)
                    Button { if m.id != model.me?.id { nav.profile = m.id } } label: {
                        HStack(spacing: 12) {
                            Avatar(user: m.user, size: 38, online: model.isOnline(m.id))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.id == model.me?.id ? String(localized: "You") : m.display).font(.bodyC).foregroundStyle(Theme.label)
                                Text("@\(m.username)").font(.captionC).foregroundStyle(Theme.label2)
                            }
                            Spacer()
                            if m.role == "owner" || m.role == "admin" {
                                Text(m.role == "owner" ? "Owner" : "Admin").font(.caption2C).foregroundStyle(Theme.label2)
                            }
                        }
                        .padding(.horizontal, 14).frame(height: 56)
                    }
                    .buttonStyle(.press(0.99))
                }
            }
            .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    @ViewBuilder
    private var sharedMedia: some View {
        let media = model.messages(roomId).filter { ($0.isVisual || $0.type == "video") && !$0.isRevoked && $0.meta?.url != nil && !$0.isLocal }.reversed()
        if !media.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Photos and videos").font(.footnoteC.weight(.semibold)).foregroundStyle(Theme.label2).padding(.leading, 6)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 4), spacing: 3) {
                    ForEach(Array(media.prefix(24))) { m in
                        FrameReporting { frame in
                            Group {
                                if m.type == "video" { VideoThumb(path: m.meta?.url ?? "", maxPixel: 300) }
                                else { RemoteImage(m.meta?.url ?? "", maxPixel: 300) }
                            }
                            .aspectRatio(1, contentMode: .fill)
                            .clipped()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(Motion.morph) {
                                    nav.viewer = ViewerItem(path: m.meta?.url ?? "", aspect: m.meta?.aspect ?? 1, source: frame(), isVideo: m.type == "video")
                                }
                            }
                        }
                        .aspectRatio(1, contentMode: .fit)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private func dangerZone(_ room: Room) -> some View {
        VStack(spacing: 0) {
            if room.isGroup {
                Button { confirmLeave = true } label: {
                    Text("Leave group").font(.bodyC).foregroundStyle(Theme.redText).frame(maxWidth: .infinity).frame(height: 50)
                }
                Hairline()
            }
            Button { confirmDelete = true } label: {
                Text("Delete chat").font(.bodyC).foregroundStyle(Theme.redText).frame(maxWidth: .infinity).frame(height: 50)
            }
        }
        .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Pick people from your contacts (new group, adding to a group, tagging).
struct PeoplePicker: View {
    let title: LocalizedStringKey
    var exclude: Set<String> = []
    var confirm: LocalizedStringKey = "Add"
    let done: ([String]) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<String> = []
    @State private var query = ""

    private var people: [User] {
        let list = model.contacts.filter { $0.state == "accepted" && !exclude.contains($0.id) }
        let q = query.lowercased()
        return q.isEmpty ? list : list.filter { $0.name.lowercased().contains(q) || $0.username.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List(people) { u in
                Button {
                    if picked.contains(u.id) { picked.remove(u.id) } else { picked.insert(u.id) }
                    Haptics.selection()
                } label: {
                    HStack(spacing: 12) {
                        Avatar(user: u, size: 40)
                        VStack(alignment: .leading) {
                            Text(u.name).font(.bodyC).foregroundStyle(Theme.label)
                            Text("@\(u.username)").font(.captionC).foregroundStyle(Theme.label2)
                        }
                        Spacer()
                        Image(systemName: picked.contains(u.id) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22))
                            .foregroundStyle(picked.contains(u.id) ? Theme.blue : Theme.label3)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query)
            .overlay {
                if people.isEmpty {
                    ContentUnavailableView("No contacts yet", systemImage: "person.2", description: Text("Add people from Messages › New chat."))
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirm) {
                        done(Array(picked))
                        dismiss()
                    }
                    .disabled(picked.isEmpty)
                }
            }
        }
    }
}

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
            Theme.bg
            if let room {
                ScrollView {
                    VStack(spacing: 0) {
                        profile(room)
                        if let peer = room.peer, !room.isGroup {
                            GroupCard {
                                Button { nav.profile = peer.id } label: {
                                    Cell(icon: .photo, iconTint: Theme.fbBlue, title: "Moments", chevron: true)
                                }
                                .buttonStyle(CellButtonStyle())
                            }
                            .padding(.top, 16)
                        }
                        GroupCard {
                            Toggle(isOn: Binding(get: { room.muted }, set: { v in Task { await model.setFlag(room.id, muted: v) } })) {
                                HStack(spacing: 12) {
                                    CellIcon(sym: .bell, tint: Theme.fbBlue, slashed: true)
                                    Text("Mute").font(.bodyC).foregroundStyle(Theme.label)
                                }
                            }
                            .toggleStyle(.switch)
                            .padding(.horizontal, 16).frame(minHeight: 58)
                            CellSeparator(leading: 56)
                            Toggle(isOn: Binding(get: { room.pinned }, set: { v in Task { await model.setFlag(room.id, pinned: v) } })) {
                                HStack(spacing: 12) {
                                    CellIcon(sym: .pin, tint: Theme.fbBlue)
                                    Text("Pin chat").font(.bodyC).foregroundStyle(Theme.label)
                                }
                            }
                            .toggleStyle(.switch)
                            .padding(.horizontal, 16).frame(minHeight: 58)
                        }
                        .padding(.top, 16)

                        if room.isGroup { members(room) }
                        sharedMedia

                        GroupCard {
                            if room.isGroup {
                                Button { confirmLeave = true } label: {
                                    Cell(title: "Leave group", color: Theme.redText)
                                }
                                .buttonStyle(CellButtonStyle())
                                CellSeparator()
                            }
                            Button { confirmDelete = true } label: {
                                Cell(title: "Delete chat", color: Theme.redText)
                            }
                            .buttonStyle(CellButtonStyle())
                        }
                        .padding(.top, 28)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 22)
                    .padding(.bottom, 24)
                }
                .safeAreaPadding(EdgeInsets(top: ctx.insets.top, leading: ctx.insets.leading,
                                            bottom: ctx.usesRail ? max(ctx.insets.bottom, 16) + 20 : ctx.barClearance,
                                            trailing: railContent))
            }
            ColumnBar(back: BarItem(id: "close", sym: nav.columns == 1 ? .chevronLeft : .xmark,
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

    private var railContent: CGFloat {
        guard ctx.usesRail, let rail = ctx.rail else { return ctx.insets.trailing }
        return max(ctx.insets.trailing, rail.centerFromEdge + Bar.railWidth / 2 + 12)
    }

    /// Who it is: a 64pt photo, the name in Title 2, how to reach them.
    private func profile(_ room: Room) -> some View {
        Button {
            if let peer = room.peer, !room.isGroup { nav.profile = peer.id }
        } label: {
            HStack(spacing: 16) {
                Avatar(path: room.avatar, name: room.title, id: room.peer?.id ?? room.id, size: 64, room: room.isGroup,
                       online: !room.isGroup && model.isOnline(room.peer?.id))
                VStack(alignment: .leading, spacing: 3) {
                    Text(room.title)
                        .font(AppFont.make(22, .semibold))
                        .tracking(-0.44)
                        .foregroundStyle(Theme.label)
                        .lineLimit(2)
                    if let peer = room.peer, !room.isGroup {
                        Text("@\(peer.username)").font(.footnoteC).foregroundStyle(Theme.label2).lineLimit(1)
                    } else {
                        Text("\(room.count) members").font(.footnoteC).foregroundStyle(Theme.label2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 23, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 23, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        }
        .buttonStyle(.press)
        .disabled(room.isGroup)
    }

    /// Members: photos in a grid, then a way to add more.
    private func members(_ room: Room) -> some View {
        VStack(spacing: 0) {
            GroupTitle(text: "Members")
            GroupCard {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)], spacing: 12) {
                    ForEach(model.members[room.id] ?? []) { m in
                        Button { if m.id != model.me?.id { nav.profile = m.id } } label: {
                            VStack(spacing: 5) {
                                Avatar(user: m.user, size: 48, online: model.isOnline(m.id))
                                Text(m.id == model.me?.id ? String(localized: "You") : m.display)
                                    .font(.captionC).foregroundStyle(Theme.label2).lineLimit(1)
                            }
                        }
                        .buttonStyle(.press(0.94))
                    }
                    Button { inviting = true } label: {
                        VStack(spacing: 5) {
                            SymbolView(.plus, size: 20, weight: 2.2).foregroundStyle(Theme.label)
                                .frame(width: 48, height: 48)
                                .background(Theme.field, in: Circle())
                                .overlay(Circle().strokeBorder(Theme.line, lineWidth: 1))
                            Text("Add").font(.captionC).foregroundStyle(Theme.label2)
                        }
                    }
                    .buttonStyle(.press(0.94))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }
        }
    }

    @ViewBuilder
    private var sharedMedia: some View {
        let media = model.messages(roomId).filter { ($0.isVisual || $0.type == "video") && !$0.isRevoked && $0.meta?.url != nil && !$0.isLocal }.reversed()
        if !media.isEmpty {
            VStack(spacing: 0) {
                GroupTitle(text: "Photos and videos")
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
                .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
            }
        }
    }
}

/// Pick people from your friends (a new group, adding to a group, tagging):
/// rows with a round check that fills with ink.
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
        VStack(spacing: 0) {
            SheetHeader(title: title, centered: true) {
                GlassIconButton(sym: .xmark, title: "Cancel") { dismiss() }
            } trailing: {
                Button {
                    done(Array(picked))
                    dismiss()
                } label: {
                    SymbolView(.check, size: 20, weight: 2.4)
                        .foregroundStyle(Theme.onInk)
                        .frame(width: 44, height: 44)
                        .background(Theme.ink, in: Circle())
                }
                .buttonStyle(.press(0.94))
                .disabled(picked.isEmpty)
                .opacity(picked.isEmpty ? 0.35 : 1)
                .accessibilityLabel(Text(confirm))
            }
            HStack(spacing: 8) {
                SymbolView(.search, size: 17).foregroundStyle(Theme.label3)
                TextField("Search", text: $query).font(.bodyC).autocorrectionDisabled()
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .glassCapsule(interactive: false)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            ScrollView {
                if people.isEmpty {
                    VStack(spacing: 6) {
                        SymbolView(.people, size: 34).foregroundStyle(Theme.label3).padding(.bottom, 6)
                        Text("No friends yet").font(.headlineC).foregroundStyle(Theme.label)
                        Text("Add people from Friends.").font(.subheadC).foregroundStyle(Theme.label2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                } else {
                    GroupCard {
                        ForEach(Array(people.enumerated()), id: \.element.id) { i, u in
                            if i > 0 { CellSeparator(leading: 66) }
                            Button {
                                if picked.contains(u.id) { picked.remove(u.id) } else { picked.insert(u.id) }
                                Haptics.selection()
                            } label: {
                                HStack(spacing: 12) {
                                    Avatar(user: u, size: 40)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(u.name).font(.bodyC).foregroundStyle(Theme.label)
                                        Text("@\(u.username)").font(.footnoteC).foregroundStyle(Theme.label2)
                                    }
                                    Spacer(minLength: 0)
                                    let on = picked.contains(u.id)
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
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
        .background(Theme.grouped)
        .presentationDetents([.large])
        .presentationCornerRadius(30)
        .presentationBackground(Theme.grouped)
    }
}

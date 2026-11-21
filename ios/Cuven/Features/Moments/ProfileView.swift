import SwiftUI

/// Someone's page: the cover to the top, their photo on its lower edge, who
/// they are, then Posts and Media.
struct ProfileView: View {
    let userId: String
    var asPage = false

    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    @Environment(\.column) private var ctx
    @State private var page: ProfilePage?
    @State private var moments: [Moment] = []
    @State private var tab = 0
    @State private var more = true
    @State private var failed = false
    @Namespace private var ns
    @State private var scrolled = false

    private var isMe: Bool { userId == model.me?.id }
    private var user: User? { page?.user ?? (isMe ? model.me : model.user(userId)) }

    var body: some View {
        GeometryReader { geo in
            let coverH = min(210, max(150, geo.size.width * 0.36))
            PageScaffold(title: .inline(LocalizedStringKey(user?.name ?? "")),
                         titleShown: scrolled,
                         back: backItem,
                         actions: actionItems,
                         background: Theme.paper,
                         underBar: true,
                         subtitle: page.map { String(localized: "\($0.count) posts") },
                         barBackdrop: AnyView(cover(height: coverH)),
                         onScroll: { y in
                             let past = y > coverH - 60
                             if past != scrolled { withAnimation(.easeOut(duration: 0.22)) { scrolled = past } }
                         }) {
                LazyVStack(spacing: 0) {
                    cover(height: coverH)
                        .bleedsUnderRail()
                    identity
                    tabs
                    if tab == 0 {
                        if moments.isEmpty && page != nil { emptyPosts }
                        ForEach($moments) { $m in
                            MomentCard(moment: $m) { moments.removeAll { $0.id == m.id } }
                        }
                        if more && !moments.isEmpty {
                            ProgressView().padding().onAppear { Task { await loadMore() } }
                        }
                    } else {
                        mediaWall(width: min(geo.size.width, 680))
                    }
                }
            }
        }
        .task(id: userId) { await load() }
        .onChange(of: model.momentsVersion) { _, _ in Task { await load() } }
    }

    /// The way out: back from someone's page; on your own (a capsule page)
    /// only where there's no capsule to leave by.
    private var backItem: BarItem? {
        if !asPage { return BarItem(id: "back", sym: .chevronLeft, title: "Back") { close() } }
        return ctx.rail == nil ? BarItem(id: "back", sym: .chevronLeft, title: "Back") { close() } : nil
    }

    private var actionItems: [BarItem] {
        if isMe {
            return [BarItem(id: "new", sym: .plus, title: "New moment") { nav.composeMoment = true },
                    BarItem(id: "settings", sym: .ellipsis, title: "Settings") { withAnimation(Motion.move) { nav.settingsOpen = true } }]
        }
        guard let user else { return [] }
        return [BarItem(id: "message", sym: .bubble, title: "Message") {
            Task {
                if let id = await model.openDM(user) {
                    close()
                    nav.switchPage(.chats)
                    nav.open(room: id)
                }
            }
        }]
    }

    /// The cover across the top: theirs, or a deep ribbon of light.
    private func cover(height: CGFloat) -> some View {
        Group {
            if let c = user?.cover, !c.isEmpty, !c.hasPrefix("preset:") {
                RemoteImage(c, maxPixel: 1600)
            } else {
                ZStack {
                    LinearGradient(stops: [.init(color: Color(hex: 0x0d1430), location: 0), .init(color: Color(hex: 0x1c2f6b), location: 0.45),
                                           .init(color: Color(hex: 0x0a0f24), location: 1)],
                                   startPoint: UnitPoint(x: 0.33, y: 0), endPoint: UnitPoint(x: 0.67, y: 1))
                    RadialGradient(colors: [Color(red: 120 / 255, green: 160 / 255, blue: 1).opacity(0.55), .clear],
                                   center: UnitPoint(x: 0.85, y: 0.4), startRadius: 0, endRadius: 260)
                    RadialGradient(colors: [Color(red: 70 / 255, green: 90 / 255, blue: 200 / 255).opacity(0.6), .clear],
                                   center: UnitPoint(x: 0.15, y: 0.8), startRadius: 0, endRadius: 220)
                }
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 0) {
            Avatar(user: user, size: 104)
                .background(Circle().fill(Theme.paper).padding(-4))
                .padding(.top, -54)
            Text(user?.name ?? "")
                .font(AppFont.make(28, .bold))
                .tracking(-0.56)
                .foregroundStyle(Theme.label)
                .padding(.top, 12)
            Text("@\(user?.username ?? "")").font(.bodyC).foregroundStyle(Theme.label2).padding(.top, 4)
            if let bio = user?.bio, !bio.isEmpty {
                Text(bio).font(.bodyC).lineSpacing(BodyMetrics.extra).foregroundStyle(Theme.label).padding(.top, 10)
            }
            if let joined = page?.user.joined, joined > 0 {
                HStack(spacing: 6) {
                    SymbolView(.calendar, size: 18)
                    Text("Joined \(Fmt.month(Date(timeIntervalSince1970: TimeInterval(joined) / 1000)))")
                }
                .font(.subheadC)
                .foregroundStyle(Theme.label2)
                .padding(.top, 12)
            }
            HStack(spacing: 18) {
                count(page?.count ?? 0, (page?.count ?? 0) == 1 ? "Post" : "Posts")
                if isMe, let f = page?.friends { count(f, f == 1 ? "Friend" : "Friends") }
                else if !isMe {
                    Text(page?.friend == true ? "You're friends" : "You've not talked yet").font(.subheadC).foregroundStyle(Theme.label2)
                }
            }
            .padding(.top, 10)

            HStack(spacing: 10) {
                if isMe {
                    ShareLink(item: "@\(user?.username ?? "")") { pill("Share profile") }
                    Button { withAnimation(Motion.move) { nav.editingProfile = true } } label: { pill("Edit profile") }
                } else if let user {
                    Button {
                        Task {
                            if let id = await model.openDM(user) {
                                close()
                                nav.switchPage(.chats)
                                nav.open(room: id)
                            }
                        }
                    } label: { pill("Message", solid: true) }
                    let state = model.contacts.first { $0.id == user.id }?.state
                    Button {
                        if state == nil { Task { await model.addContact(user) } }
                    } label: {
                        pill(state == "accepted" ? "Friends" : (state == "pending_out" ? "Requested" : (state == "pending_in" ? "Accept" : "Add friend")))
                    }
                    .disabled(state == "accepted" || state == "pending_out")
                }
            }
            .buttonStyle(.press)
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }

    private func count(_ n: Int, _ word: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Text("\(n)").font(AppFont.make(15, .semibold).monospacedDigit()).foregroundStyle(Theme.label)
            Text(word).font(.subheadC).foregroundStyle(Theme.label2)
        }
    }

    /// The web's .mo-pill: 44pt, a hairline just inside (glass here), or ink.
    private func pill(_ t: LocalizedStringKey, solid: Bool = false) -> some View {
        Text(t)
            .font(AppFont.make(15, .semibold))
            .foregroundStyle(solid ? Theme.onInk : Theme.label)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background { if solid { Capsule().fill(Theme.ink) } }
            .glassEffect(solid ? Glass.identity : Glass.regular.interactive(), in: Capsule())
    }

    /// Tabs: an icon each; the chosen one also says its name.
    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(0..<2, id: \.self) { i in
                let on = tab == i
                Button {
                    Haptics.selection()
                    withAnimation(.spring(duration: 0.34, bounce: 0.1)) { tab = i }
                } label: {
                    HStack(spacing: 8) {
                        SymbolView(i == 0 ? .doc : .photo, size: 24)
                        if on {
                            Text(i == 0 ? "Posts" : "Media").font(AppFont.make(17, .bold))
                                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        }
                    }
                    .foregroundStyle(on ? Theme.label : Theme.label2)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .overlay(alignment: .bottom) {
                        if on {
                            Capsule().fill(Theme.label).frame(height: 3).padding(.horizontal, 24)
                                .matchedGeometryEffect(id: "tab", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(i == 0 ? "Posts" : "Media")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .background(Theme.paper)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 0.5) }
        .padding(.top, 16)
    }

    private var emptyPosts: some View {
        VStack(spacing: 6) {
            if isMe {
                Text("Share your first moment").font(AppFont.make(17, .bold)).foregroundStyle(Theme.label)
                Text("Photos or a video, and a few words.").font(.subheadC).foregroundStyle(Theme.label2)
                Button { nav.composeMoment = true } label: {
                    Text("Share a moment").font(AppFont.make(15, .semibold)).foregroundStyle(Theme.onInk)
                        .padding(.horizontal, 18).frame(height: 44)
                        .glassEffect(.regular.tint(Theme.ink.opacity(0.85)).interactive(), in: Capsule())
                }
                .buttonStyle(.press)
                .padding(.top, 12)
            } else {
                Text(page?.visible == false ? "You've not talked yet — only posts for everyone show here." : "No posts yet")
                    .font(.subheadC).foregroundStyle(Theme.label2).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 40)
    }

    private func mediaWall(width: CGFloat) -> some View {
        let items = moments.filter { !$0.media.isEmpty }
        let colW = (min(width, 720) - 36) / 2
        let left = items.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let right = items.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        return HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 10) { ForEach(left) { tile($0, width: colW) } }
            VStack(spacing: 10) { ForEach(right) { tile($0, width: colW) } }
        }
        .padding(14)
    }

    private func tile(_ m: Moment, width: CGFloat) -> some View {
        let first = m.media[0]
        let a = max(0.6, min(1.6, first.aspect))
        return FrameReporting { frame in
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if first.isVideo { VideoThumb(path: first.url, maxPixel: 600) } else { RemoteImage(first.url, maxPixel: 600) }
                    }
                    .frame(width: width, height: width / a)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    if m.media.count > 1 {
                        HStack(spacing: 3) {
                            SymbolView(.photoStack, size: 13)
                            Text("\(m.media.count)")
                        }
                        .font(.caption2C).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(.black.opacity(0.45), in: Capsule()).padding(8)
                    }
                }
                if !m.text.isEmpty {
                    Text(m.text).font(.footnoteC).foregroundStyle(Theme.label).lineLimit(2)
                }
                HStack(spacing: 6) {
                    Avatar(user: m.user, size: 18)
                    Text(m.user.name).font(.caption2C).foregroundStyle(Theme.label2).lineLimit(1)
                    Spacer()
                    SymbolView(.heart, size: 12, filled: m.liked).foregroundStyle(m.liked ? Theme.red : Theme.label3)
                    Text("\(m.likes.count)").font(.caption2C).foregroundStyle(Theme.label3)
                }
            }
            .frame(width: width)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(Motion.morph) {
                    nav.viewer = ViewerItem(path: first.url, aspect: first.aspect, source: frame(), isVideo: first.isVideo)
                }
            }
        }
    }

    private func close() {
        if asPage { nav.switchPage(.chats) } else { withAnimation(Motion.move) { nav.profile = nil } }
    }

    private func load() async {
        guard !userId.isEmpty else { return }
        do {
            let p = try await model.profilePage(userId)
            withAnimation(Motion.ui) {
                page = p
                moments = p.moments
                more = p.moments.count >= 20
            }
        } catch {
            failed = true
        }
    }

    private func loadMore() async {
        guard let last = moments.last, let p = try? await model.profilePage(userId, before: last.created) else { return }
        let known = Set(moments.map(\.id))
        moments += p.moments.filter { !known.contains($0.id) }
        more = p.moments.count >= 20
    }
}

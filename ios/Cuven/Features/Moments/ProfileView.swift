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

    private var isMe: Bool { userId == model.me?.id }
    private var user: User? { page?.user ?? (isMe ? model.me : model.user(userId)) }

    var body: some View {
        GeometryReader { geo in
            let topInset = ctx.insets.top
            ZStack(alignment: .topLeading) {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        cover(height: 190 + topInset)
                        identity
                        tabs
                        if tab == 0 {
                            LazyVStack(spacing: 0) {
                                if moments.isEmpty && page != nil {
                                    Text(page?.visible == false && !isMe ? "You've not talked yet — only posts for everyone show here." : "No posts yet")
                                        .font(.subheadC).foregroundStyle(Theme.label2).multilineTextAlignment(.center)
                                        .padding(40)
                                }
                                ForEach($moments) { $m in
                                    MomentCard(moment: $m) { moments.removeAll { $0.id == m.id } }
                                    Hairline().padding(.horizontal, 16)
                                }
                                if more && !moments.isEmpty {
                                    ProgressView().padding().onAppear { Task { await loadMore() } }
                                }
                            }
                        } else {
                            mediaWall(width: geo.size.width)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .ignoresSafeArea(edges: .top)
                .safeAreaPadding(.bottom, ctx.insets.bottom + 90)

                // Back / close
                if !asPage || ctx.rail == nil {
                    Button {
                        Haptics.tap()
                        close()
                    } label: {
                        Image(systemName: asPage ? "chevron.left" : "xmark")
                            .font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.label)
                            .frame(width: 44, height: 44).glassCircle()
                    }
                    .buttonStyle(.press(0.9))
                    .padding(.leading, max(ctx.insets.leading, 16))
                    .padding(.top, topInset + 8)
                    .accessibilityLabel(asPage ? "Back" : "Close")
                }

                if isMe {
                    Button { nav.composeMoment = true } label: {
                        Image(systemName: "plus").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 58, height: 58).glassCircle(tint: Theme.sky)
                    }
                    .buttonStyle(.press(0.9))
                    .padding(.trailing, ctx.insets.trailing + 20)
                    .padding(.bottom, ctx.insets.bottom + 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .accessibilityLabel("New moment")
                }
            }
        }
        .task(id: userId) { await load() }
        .onChange(of: model.momentsVersion) { _, _ in Task { await load() } }
    }

    private func cover(height: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let c = user?.cover, !c.isEmpty, !c.hasPrefix("preset:") {
                    RemoteImage(c, maxPixel: 1600)
                } else {
                    let t = Theme.tint(for: userId)
                    LinearGradient(colors: [t.0, Theme.sky.opacity(0.35), t.0.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .clipped()

            Avatar(user: user, size: 96)
                .overlay(Circle().stroke(Theme.bg, lineWidth: 4))
                .offset(x: 20, y: 48)
        }
        .padding(.bottom, 48)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(user?.name ?? "").font(.title1C).foregroundStyle(Theme.label)
            Text("@\(user?.username ?? "")").font(.subheadC).foregroundStyle(Theme.label2)
            if let bio = user?.bio, !bio.isEmpty {
                Text(bio).font(.bodyC).foregroundStyle(Theme.label)
            }
            HStack(spacing: 16) {
                if let joined = page?.user.joined, joined > 0 {
                    Label("Joined \(Fmt.month(Date(timeIntervalSince1970: TimeInterval(joined) / 1000)))", systemImage: "calendar")
                }
                Text("\(page?.count ?? 0) posts").fontWeight(.semibold)
                if isMe, let f = page?.friends { Text("\(f) friends").fontWeight(.semibold) }
                else if !isMe { Text(page?.friend == true ? "Friends" : "You've not talked yet") }
            }
            .font(.footnoteC)
            .foregroundStyle(Theme.label2)

            HStack(spacing: 10) {
                if isMe {
                    Button { nav.settingsOpen = true } label: {
                        Text("Edit profile").font(.subheadMediumC).foregroundStyle(Theme.label)
                            .frame(maxWidth: .infinity).frame(height: 40).background(Theme.fillQuiet, in: Capsule())
                    }
                    ShareLink(item: "@\(user?.username ?? "")") {
                        Text("Share profile").font(.subheadMediumC).foregroundStyle(Theme.label)
                            .frame(maxWidth: .infinity).frame(height: 40).background(Theme.fillQuiet, in: Capsule())
                    }
                } else if let user {
                    Button {
                        Task {
                            if let id = await model.openDM(user) {
                                close()
                                nav.switchPage(.chats)
                                nav.open(room: id)
                            }
                        }
                    } label: {
                        Text("Message").font(.subheadMediumC).foregroundStyle(Theme.onInk)
                            .frame(maxWidth: .infinity).frame(height: 40).background(Theme.ink, in: Capsule())
                    }
                    let state = model.contacts.first { $0.id == user.id }?.state
                    if state == nil {
                        Button {
                            Task { await model.addContact(user) }
                        } label: {
                            Image(systemName: "person.badge.plus").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.label)
                                .frame(width: 48, height: 40).background(Theme.fillQuiet, in: Capsule())
                        }
                        .accessibilityLabel("Add")
                    }
                }
            }
            .buttonStyle(.press)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(Array(["Posts", "Media"].enumerated()), id: \.offset) { i, t in
                Button {
                    Haptics.selection()
                    withAnimation(Motion.ui) { tab = i }
                } label: {
                    VStack(spacing: 8) {
                        Text(LocalizedStringKey(t)).font(.subheadMediumC).foregroundStyle(tab == i ? Theme.label : Theme.label3)
                        ZStack {
                            Rectangle().fill(Color.clear).frame(height: 2)
                            if tab == i {
                                Capsule().fill(Theme.label).frame(height: 2).matchedGeometryEffect(id: "tab", in: ns)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(alignment: .bottom) { Hairline() }
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
                        Label("\(m.media.count)", systemImage: "square.on.square").font(.caption2C).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3).background(.black.opacity(0.4), in: Capsule()).padding(8)
                    }
                }
                if !m.text.isEmpty {
                    Text(m.text).font(.footnoteC).foregroundStyle(Theme.label).lineLimit(2)
                }
                HStack(spacing: 6) {
                    Avatar(user: m.user, size: 18)
                    Text(m.user.name).font(.caption2C).foregroundStyle(Theme.label2).lineLimit(1)
                    Spacer()
                    Image(systemName: m.liked ? "heart.fill" : "heart").font(.system(size: 11)).foregroundStyle(m.liked ? Theme.red : Theme.label3)
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

import SwiftUI

/// The Moments home: a large sky-blue title, a row of people (new posts
/// ringed), then the feed; the title bar frosts once the feed moves.
struct MomentsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    @Environment(\.column) private var ctx
    @State private var moments: [Moment] = []
    @State private var loading = true
    @State private var more = true
    @State private var fresh = false
    @State private var seenVersion = 0
    @AppStorage("ui:momentsSeen") private var seenAt: Double = 0

    private var people: [User] {
        var seen = Set<String>()
        var out: [User] = []
        for m in moments where !m.mine {
            if seen.insert(m.user.id).inserted { out.append(m.user) }
        }
        return out.sorted { a, b in
            hasNew(a) && !hasNew(b)
        }
    }

    private func hasNew(_ u: User) -> Bool {
        moments.contains { $0.user.id == u.id && Double($0.created) > seenAt }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.bg
            ScrollView {
                LazyVStack(spacing: 0) {
                    titleRow
                    peopleRow
                    if fresh {
                        Button {
                            Task { await reload() }
                        } label: {
                            Label("New moments", systemImage: "arrow.up")
                                .font(.subheadMediumC).foregroundStyle(.white)
                                .padding(.horizontal, 16).frame(height: 36).background(Theme.sky, in: Capsule())
                        }
                        .padding(.vertical, 8)
                        .transition(.scale.combined(with: .opacity))
                    }
                    if loading && moments.isEmpty {
                        ForEach(0..<2, id: \.self) { _ in MomentSkeleton() }
                    } else if moments.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 40, weight: .light)).foregroundStyle(Theme.label3)
                            Text("No moments yet").font(.headlineC)
                            Text("Share a photo or a few words with your friends.").font(.subheadC).foregroundStyle(Theme.label2)
                            Button { nav.composeMoment = true } label: {
                                Text("New moment").font(.headlineC).foregroundStyle(.white)
                                    .padding(.horizontal, 22).frame(height: 44).background(Theme.sky, in: Capsule())
                            }
                            .buttonStyle(.press)
                        }
                        .padding(.top, 60)
                    }
                    ForEach($moments) { $m in
                        MomentCard(moment: $m) {
                            withAnimation(Motion.ui) { moments.removeAll { $0.id == m.id } }
                        }
                        .frame(maxWidth: 640)
                        Hairline().padding(.horizontal, 16)
                    }
                    if more && !moments.isEmpty {
                        ProgressView().padding(24)
                            .onAppear { Task { await loadMore() } }
                    }
                }
            }
            .safeAreaPadding(EdgeInsets(top: ctx.insets.top, leading: ctx.insets.leading,
                                        bottom: ctx.insets.bottom + 90, trailing: ctx.insets.trailing))
            .refreshable { await reload() }

            if ctx.rail == nil {
                ColumnBar(back: BarItem(id: "back", symbol: "chevron.left", title: "Back") { nav.switchPage(.chats) },
                          actions: [BarItem(id: "new", symbol: "plus", title: "New moment", tint: Theme.sky, foreground: .white) { nav.composeMoment = true }])
                    .environment(\.column, ctx)
            }
        }
        .animation(Motion.ui, value: fresh)
        .task { await reload() }
        .onChange(of: model.momentsVersion) { _, _ in fresh = true }
        .onDisappear { seenAt = Date().timeIntervalSince1970 * 1000 }
    }

    private var titleRow: some View {
        HStack(spacing: 10) {
            Text("Moments").font(.largeTitleC).foregroundStyle(Theme.sky)
            Spacer()
            roundButton("square.and.pencil", "New moment") { nav.composeMoment = true }
            roundButton("person.crop.circle", "Your profile") { nav.profile = model.me?.id }
            if ctx.rail != nil {
                roundButton("xmark", "Close") { nav.switchPage(.chats) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    private func roundButton(_ symbol: String, _ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.label)
                .frame(width: 40, height: 40).background(Theme.fillQuiet, in: Circle())
        }
        .buttonStyle(.press(0.9))
        .accessibilityLabel(Text(title))
    }

    private var peopleRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                Button { nav.composeMoment = true } label: {
                    VStack(spacing: 6) {
                        Avatar(user: model.me, size: 64)
                            .padding(3)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "plus").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
                                    .frame(width: 22, height: 22).background(Theme.blue, in: Circle())
                                    .overlay(Circle().stroke(Theme.bg, lineWidth: 2.5))
                            }
                        Text("You").font(.captionC).foregroundStyle(Theme.label2)
                    }
                }
                .buttonStyle(.press(0.94))
                ForEach(people) { u in
                    Button { nav.profile = u.id } label: {
                        VStack(spacing: 6) {
                            Avatar(user: u, size: 64, ring: hasNew(u))
                                .padding(hasNew(u) ? 0 : 3)
                                .overlay(alignment: .bottomTrailing) {
                                    if u.friend == false {
                                        Image(systemName: "person.badge.plus").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                            .frame(width: 20, height: 20).background(Theme.label2, in: Circle())
                                            .overlay(Circle().stroke(Theme.bg, lineWidth: 2))
                                    }
                                }
                            Text(u.name).font(.captionC).foregroundStyle(Theme.label2).lineLimit(1).frame(width: 70)
                        }
                    }
                    .buttonStyle(.press(0.94))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private func reload() async {
        do {
            let list = try await model.feed()
            withAnimation(Motion.ui) {
                moments = list
                more = list.count >= 20
                fresh = false
            }
        } catch {
            model.show(error.localizedDescription, error: true)
        }
        loading = false
    }

    private func loadMore() async {
        guard let last = moments.last else { return }
        let list = (try? await model.feed(before: last.created)) ?? []
        let known = Set(moments.map(\.id))
        moments += list.filter { !known.contains($0.id) }
        more = list.count >= 20
    }
}

struct MomentSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(Theme.fillQuiet).frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonBar(width: 120)
                    SkeletonBar(width: 70, height: 9)
                }
            }
            .padding(.horizontal, 16)
            Rectangle().fill(Theme.fillQuiet).aspectRatio(1, contentMode: .fit)
            SkeletonBar(width: 200).padding(.horizontal, 16)
        }
        .padding(.vertical, 12)
    }
}

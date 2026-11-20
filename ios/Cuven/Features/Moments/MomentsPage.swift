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
    @State private var scrolled = false

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
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        peopleRow
                        if fresh {
                            Button {
                                Task { await reload() }
                            } label: {
                                HStack(spacing: 6) {
                                    SymbolView(.arrowUp, size: 15, weight: 2.4)
                                    Text("New moments").font(.subheadBoldC)
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16).frame(height: 36)
                                .background(Theme.skyTitle, in: Capsule())
                            }
                            .buttonStyle(.press)
                            .padding(.vertical, 8)
                            .transition(.scale.combined(with: .opacity))
                        }
                        if loading && moments.isEmpty {
                            ForEach(0..<2, id: \.self) { _ in MomentSkeleton() }
                        } else if moments.isEmpty {
                            VStack(spacing: 6) {
                                SymbolView(.photo, size: 34).foregroundStyle(Theme.label3).padding(.bottom, 6)
                                Text("No moments yet").font(.headlineC).foregroundStyle(Theme.label)
                                Text("Share a photo or a few words with your friends.")
                                    .font(.subheadC).lineSpacing(3).foregroundStyle(Theme.label2).multilineTextAlignment(.center)
                            }
                            .padding(.horizontal, 28)
                            .padding(.vertical, 48)
                        }
                        ForEach($moments) { $m in
                            MomentCard(moment: $m) {
                                withAnimation(Motion.ui) { moments.removeAll { $0.id == m.id } }
                            }
                            .frame(maxWidth: 640)
                        }
                        if more && !moments.isEmpty {
                            ProgressView().padding(24)
                                .onAppear { Task { await loadMore() } }
                        }
                        Color.clear.frame(height: 88)
                    } header: {
                        head
                    }
                }
            }
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 4 } action: { _, v in
                withAnimation(.easeOut(duration: 0.22)) { scrolled = v }
            }
            .refreshable { await reload() }

            // New moment: a round glass button floating at the page's foot.
            Button { nav.composeMoment = true } label: {
                SymbolView(.plus, size: 26, weight: 2.2)
                    .foregroundStyle(Theme.label)
                    .frame(width: 56, height: 56)
                    .glassCircle()
            }
            .buttonStyle(.press(0.9))
            .padding(.trailing, 20)
            .padding(.bottom, max(ctx.insets.bottom, 12) + 16)
            .accessibilityLabel("New moment")
        }
        .animation(Motion.ui, value: fresh)
        .task { await reload() }
        .onChange(of: model.momentsVersion) { _, _ in fresh = true }
        .onDisappear { seenAt = Date().timeIntervalSince1970 * 1000 }
    }

    /// The wordmark in sky blue, the close button beside it; frosted once the feed moves.
    private var head: some View {
        HStack(spacing: 8) {
            Text("Moments")
                .font(AppFont.make(28, .heavy))
                .tracking(-0.98)
                .foregroundStyle(Theme.skyTitle)
                .frame(maxWidth: .infinity, alignment: .leading)
            SheetClose()
        }
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .frame(minHeight: 64)
        .background {
            if scrolled {
                Rectangle().fill(.ultraThinMaterial)
                    .overlay(Theme.paper.opacity(0.86))
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 0.5) }
                    .transition(.opacity)
            }
        }
    }

    /// People: a ring round whoever has something new, a hairline after.
    private var peopleRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button { nav.composeMoment = true } label: {
                    person(user: model.me, name: String(localized: "Your moment"), fresh: false) {
                        SymbolView(.plus, size: 14, weight: 2.6).foregroundStyle(.white)
                            .frame(width: 24, height: 24).background(Theme.blue, in: Circle())
                    }
                }
                .buttonStyle(NoteFaceStyleShared())
                ForEach(people) { u in
                    Button { nav.profile = u.id } label: {
                        person(user: u, name: u.name, fresh: hasNew(u)) {
                            if u.friend == false {
                                SymbolView(.personPlus, size: 14).foregroundStyle(Theme.onInk)
                                    .frame(width: 24, height: 24).background(Theme.ink, in: Circle())
                            }
                        }
                    }
                    .buttonStyle(NoteFaceStyleShared())
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 14)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 0.5) }
    }

    private func person<Mark: View>(user: User?, name: String, fresh: Bool, @ViewBuilder badge: () -> Mark) -> some View {
        VStack(spacing: 6) {
            ZStack {
                if fresh {
                    Circle().fill(AngularGradient(colors: [Theme.blue, Theme.indigo, Color(hex: 0xbf5af2), Color(hex: 0xff375f), Theme.orange, Theme.blue],
                                                  center: .center, angle: .degrees(200 - 90)))
                    Circle().fill(Theme.paper).padding(2.5)
                } else {
                    Circle().strokeBorder(Theme.line, lineWidth: 1)
                }
                Avatar(user: user, size: 64)
            }
            .frame(width: 74, height: 74)
            .overlay(alignment: .topLeading) {
                badge()
                    .background(Circle().fill(Theme.paper).padding(-3))
                    .offset(x: 37 + 14 - 12 + 12, y: 50)
            }
            Text(name).font(.captionC).foregroundStyle(Theme.label).lineLimit(1)
        }
        .frame(width: 84)
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
                Circle().fill(Theme.fill4).frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonBar(width: 120)
                    SkeletonBar(width: 70, height: 9)
                }
            }
            .padding(.horizontal, 16)
            Rectangle().fill(Theme.fill4).aspectRatio(1, contentMode: .fit)
            SkeletonBar(width: 200).padding(.horizontal, 16)
        }
        .padding(.vertical, 12)
    }
}

/// A face that gives a little under the finger (the web's .note:active / .mo-person:active: 0.94).
struct NoteFaceStyleShared: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(configuration.isPressed ? Motion.pressIn : Motion.ui, value: configuration.isPressed)
    }
}

import SwiftUI

/// Every photo, video and drawing shared in your chats, newest first,
/// grouped by month in an even four-column grid, with last month's recap.
struct MemoriesPage: View {
    @Environment(AppModel.self) private var model
    @Environment(Nav.self) private var nav
    @Environment(\.column) private var ctx
    @State private var items: [MemoryItem] = []
    @State private var more = true
    @State private var loading = true
    @State private var filter = "all"
    @State private var query = ""
    @State private var newestFirst = true
    @Namespace private var ns

    private let filters: [(String, LocalizedStringKey)] = [("all", "All"), ("photo", "Photos"), ("video", "Videos"), ("drawing", "Drawings")]

    private var shown: [MemoryItem] {
        let q = query.lowercased()
        let list = q.isEmpty ? items : items.filter { ($0.chat?.name.lowercased().contains(q) ?? false) || ($0.from?.name.lowercased().contains(q) ?? false) }
        return newestFirst ? list : list.reversed()
    }

    private var months: [(String, [MemoryItem])] {
        var order: [String] = []
        var groups: [String: [MemoryItem]] = [:]
        for m in shown {
            let k = Fmt.month(m.date)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(m)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        ZStack {
            Theme.bg
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                    HStack {
                        Text("Memories").font(.largeTitleC).foregroundStyle(Theme.blue)
                        Spacer()
                        Menu {
                            Picker("Order", selection: $newestFirst) {
                                Text("Newest first").tag(true)
                                Text("Oldest first").tag(false)
                            }
                        } label: {
                            Image(systemName: "ellipsis").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.label)
                                .frame(width: 40, height: 40).background(Theme.fillQuiet, in: Circle())
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)

                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.label3)
                        TextField("Search chats or people", text: $query).font(.bodyC)
                    }
                    .padding(.horizontal, 14).frame(height: 42)
                    .background(Theme.field, in: Capsule())
                    .padding(.horizontal, 20)

                    HStack(spacing: 8) {
                        ForEach(filters, id: \.0) { f in
                            Button {
                                Haptics.selection()
                                withAnimation(Motion.ui) { filter = f.0 }
                            } label: {
                                Text(f.1).font(.subheadMediumC)
                                    .foregroundStyle(filter == f.0 ? Theme.onInk : Theme.label)
                                    .padding(.horizontal, 14).frame(height: 34)
                                    .background {
                                        if filter == f.0 { Capsule().fill(Theme.ink).matchedGeometryEffect(id: "f", in: ns) }
                                        else { Capsule().stroke(Theme.line, lineWidth: 1) }
                                    }
                            }
                            .buttonStyle(.press)
                        }
                    }
                    .padding(.horizontal, 20)

                    if let recap = recap { recapCard(recap) }

                    if loading && items.isEmpty {
                        grid(Array(repeating: nil, count: 12))
                    } else if items.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "sparkles.rectangle.stack").font(.system(size: 40, weight: .light)).foregroundStyle(Theme.label3)
                            Text("Photos you share in chats collect here.").font(.subheadC).foregroundStyle(Theme.label2)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 50)
                    }

                    ForEach(months, id: \.0) { month, list in
                        Section {
                            grid(list.map { Optional($0) })
                        } header: {
                            Text(month).font(.headlineC).foregroundStyle(Theme.label)
                                .padding(.horizontal, 20).padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.bg.opacity(0.94))
                        }
                    }

                    if more && !items.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding()
                            .onAppear { Task { await loadMore() } }
                    }
                }
            }
            .safeAreaPadding(EdgeInsets(top: ctx.insets.top, leading: ctx.insets.leading, bottom: ctx.insets.bottom + 90, trailing: ctx.insets.trailing))
            .refreshable { await reload() }

            if ctx.rail == nil {
                ColumnBar(back: BarItem(id: "back", symbol: "chevron.left", title: "Back") { nav.switchPage(.chats) })
                    .environment(\.column, ctx)
            }
        }
        .task(id: filter) { await reload() }
    }

    private var recap: [MemoryItem]? {
        let monthAgo = Date().addingTimeInterval(-30 * 86400)
        let r = items.filter { $0.date > monthAgo && $0.type != "video" }
        return r.count >= 3 ? Array(r.prefix(8)) : nil
    }

    private func recapCard(_ list: [MemoryItem]) -> some View {
        FrameReporting { frame in
            ZStack(alignment: .bottomLeading) {
                TimelineView(.periodic(from: .now, by: 3)) { tl in
                    let i = Int(tl.date.timeIntervalSinceReferenceDate / 3) % list.count
                    RemoteImage(list[i].url, maxPixel: 1200)
                        .id(list[i].id)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.8), value: i)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    Text("This month").font(.caption2C.weight(.bold)).foregroundStyle(.white.opacity(0.85)).textCase(.uppercase)
                    Text("\(list.count) moments together").font(.title3C).foregroundStyle(.white)
                }
                .padding(18)
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture {
                let first = list[0]
                withAnimation(Motion.morph) {
                    nav.viewer = ViewerItem(path: first.url, aspect: first.h > 0 ? CGFloat(first.w / first.h) : 1, source: frame())
                }
            }
        }
        .frame(height: 220)
        .padding(.horizontal, 20)
    }

    private func grid(_ list: [MemoryItem?]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 4), spacing: 2) {
            ForEach(Array(list.enumerated()), id: \.offset) { _, item in
                if let item {
                    FrameReporting { frame in
                        ZStack(alignment: .bottomTrailing) {
                            Group {
                                if item.type == "video" { VideoThumb(path: item.url, maxPixel: 300) }
                                else { RemoteImage(item.url, maxPixel: 300, placeholder: item.type == "drawing" ? .white : Theme.fillQuiet) }
                            }
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                            .clipped()
                            if item.type == "video" {
                                Text(Fmt.duration(item.dur)).font(.caption2C.monospacedDigit()).foregroundStyle(.white)
                                    .padding(4).shadow(radius: 2)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(Motion.morph) {
                                nav.viewer = ViewerItem(path: item.url, aspect: item.h > 0 ? CGFloat(item.w / item.h) : 1, source: frame(), isVideo: item.type == "video")
                            }
                        }
                        .contextMenu {
                            Button {
                                nav.switchPage(.chats)
                                nav.open(room: item.room)
                            } label: { Label("Show in chat", systemImage: "bubble.left") }
                        }
                    }
                    .aspectRatio(1, contentMode: .fit)
                } else {
                    Rectangle().fill(Theme.fillQuiet).aspectRatio(1, contentMode: .fit)
                }
            }
        }
    }

    private func reload() async {
        let r = await model.memories(type: filter == "all" ? nil : filter)
        withAnimation(Motion.ui) {
            items = r?.memories ?? []
            more = r?.more ?? false
        }
        loading = false
    }

    private func loadMore() async {
        guard let last = items.last else { return }
        let r = await model.memories(before: last.ts, type: filter == "all" ? nil : filter)
        let known = Set(items.map(\.id))
        items += (r?.memories ?? []).filter { !known.contains($0.id) }
        more = r?.more ?? false
    }
}

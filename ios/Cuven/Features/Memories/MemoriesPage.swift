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
    @AppStorage("ui:memories-type") private var filter = "all"
    @State private var query = ""
    @AppStorage("ui:memories-newest") private var newestFirst = true
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
        PageScaffold(title: .inline("Memories"),
                     back: ctx.rail == nil ? BarItem(id: "back", sym: .chevronLeft, title: "Back") { nav.switchPage(.chats) } : nil,
                     actions: [BarItem(id: "filters", sym: .filter, title: "Filters") {
                         withAnimation(Motion.bouncy) { nav.filterCard = .memories }
                     }],
                     background: Theme.paper) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    SymbolView(.search, size: 18).foregroundStyle(Theme.label2)
                    TextField("Search", text: $query).font(.bodyC).autocorrectionDisabled()
                        .submitLabel(.search)
                    ClearButton(text: $query)
                }
                .padding(.leading, 14).padding(.trailing, 8).frame(height: 44)
                .animation(Motion.quick, value: query.isEmpty)
                .background(Theme.fill2, in: Capsule())
                .padding(.horizontal, 16).padding(.bottom, 6)
                tabs
            }
        } content: {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let recap = recap { recapCard(recap) }

                if loading && items.isEmpty {
                    grid(Array(repeating: nil, count: 12)).padding(.top, 14)
                } else if items.isEmpty {
                    VStack(spacing: 6) {
                        SymbolView(.photo, size: 34).foregroundStyle(Theme.label3).padding(.bottom, 6)
                        Text("No memories yet").font(AppFont.make(17, .bold)).foregroundStyle(Theme.label)
                        Text("Photos, videos and drawings you and your friends share in chats are kept here.")
                            .font(.subheadC).lineSpacing(3).foregroundStyle(Theme.label2).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 56)
                }

                ForEach(months, id: \.0) { month, list in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(month).font(AppFont.make(15, .bold)).foregroundStyle(Theme.label)
                            Text("\(list.count)").font(AppFont.make(12, .semibold)).foregroundStyle(Theme.label3)
                        }
                        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 8)
                        grid(list.map { Optional($0) })
                    }
                    .padding(.top, 14)
                }

                if more && !items.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding()
                        .onAppear { Task { await loadMore() } }
                }
            }
        }
        .refreshable { await reload() }
        .task(id: filter) { await reload() }
    }

    /// Tabs with a line under the chosen one.
    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(filters, id: \.0) { f in
                let on = filter == f.0
                Button {
                    Haptics.selection()
                    withAnimation(.spring(duration: 0.32, bounce: 0.1)) { filter = f.0 }
                } label: {
                    Text(f.1)
                        .font(AppFont.make(15, on ? .bold : .semibold))
                        .foregroundStyle(on ? Theme.label : Theme.label2)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .overlay(alignment: .bottom) {
                            if on {
                                Capsule().fill(Theme.label).frame(height: 3)
                                    .matchedGeometryEffect(id: "line", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }

    private var recap: [MemoryItem]? {
        let monthAgo = Date().addingTimeInterval(-30 * 86400)
        let r = items.filter { $0.date > monthAgo && $0.type != "video" }
        return r.count >= 3 ? Array(r.prefix(8)) : nil
    }

    /// The recap: the latest month's best picture, large, its name over it.
    private func recapCard(_ list: [MemoryItem]) -> some View {
        FrameReporting { frame in
            ZStack(alignment: .topLeading) {
                TimelineView(.periodic(from: .now, by: 3)) { tl in
                    let i = Int(tl.date.timeIntervalSinceReferenceDate / 3) % list.count
                    RemoteImage(list[i].url, maxPixel: 1200)
                        .id(list[i].id)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.8), value: i)
                }
                LinearGradient(stops: [.init(color: .black.opacity(0.42), location: 0), .init(color: .clear, location: 0.46)],
                               startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Fmt.month(list[0].date)).font(AppFont.make(20, .bold))
                    Text("\(list.count) memories").font(.footnoteC).opacity(0.9)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 1)
                .padding(.top, 16).padding(.leading, 18).padding(.trailing, 60)
                SymbolView(.play, size: 18).foregroundStyle(.black).offset(x: 1)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.88), in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(14)
            }
            .aspectRatio(16 / 11, contentMode: .fit)
            .background(Theme.fill2)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 17, y: 16)
            .contentShape(Rectangle())
            .onTapGesture {
                let first = list[0]
                withAnimation(Motion.morph) {
                    nav.viewer = ViewerItem(path: first.url, aspect: first.h > 0 ? CGFloat(first.w / first.h) : 1, source: frame())
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private func grid(_ list: [MemoryItem?]) -> some View {
        let cols = ctx.size.width <= 380 ? 3 : 4
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: cols), spacing: 2) {
            ForEach(Array(list.enumerated()), id: \.offset) { _, item in
                if let item {
                    FrameReporting { frame in
                        ZStack(alignment: .bottomTrailing) {
                            Group {
                                if item.type == "video" { VideoThumb(path: item.url, maxPixel: 300) }
                                else { RemoteImage(item.url, maxPixel: 300, placeholder: item.type == "drawing" ? .white : Theme.fill2) }
                            }
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                            .clipped()
                            if item.type == "video" {
                                Text(Fmt.duration(item.dur)).font(AppFont.make(12, .semibold).monospacedDigit()).foregroundStyle(.white)
                                    .padding(5).shadow(color: .black.opacity(0.5), radius: 3)
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
                    Rectangle().fill(Theme.fill2).aspectRatio(1, contentMode: .fit)
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

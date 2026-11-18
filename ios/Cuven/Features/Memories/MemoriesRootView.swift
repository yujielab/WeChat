import SwiftUI
import CuvenCore

// MARK: - Canonical Memories Archive Root View (M10 — `PROJECT.md § 4, § 5.4, § 5.5`)
//
// Exact Public Contract:
// `public struct MemoriesRootView: View {`
// `    public init(store: AppStore, metrics: DuoLayoutMetrics, onClose: @escaping () -> Void)`
// `}`
//
// Apple HIG & Cuven Web Grounding (`public/js/views/memories.js:1-184`):
// - Chronological month-grouped 4-column square media grid (`memories.grid`) archiving every
//   photo, video, and sketch shared across conversations.
// - Search by conversation name, caption, or month (`memories.js:38-39, 108`).
// - Spring-underlined filter tabs: `All`, `Photos`, `Videos`, `Drawings` (`memories.js:18`).
// - Sort order menu: `Newest first` / `Oldest first` (`memories.js:51-54`).
// - Monthly Recap Flashback Hero Card (`memories.flashbackPlay`) launching `MemoriesFlashbackSlideshowView`.
// - Tapping any grid tile launches `FullscreenMediaLightboxView` (`1x...4x` zoom + 1:1 drag dismiss)
//   as an overlay inside `MemoriesRootView` so dismissing the viewer keeps `MemoriesRootView` open (`testB36`).
// - Posture-adaptive across all 6 iPhone & iPhone Duo postures:
//   * Clears `safeRight` (`84pt` Open / `91pt` Closed) so `DuoRail` & `PagesCapsuleView` never collide.
//   * `duoHalfBook`: Left book page displays Header + Search + Tabs + Recap Hero (`memories.flashbackPlay`),
//     Hinge spacer separates the crease, Right book page scrolls the 4-column Month Grid (`memories.grid`).
//   * `duoHalfLaptop`: Upper display pane showcases Header + Recap Hero above the fold, while the lower
//     tabletop deck houses Search, Filter Tabs, and the scrollable 4-column Month Grid.

public enum MemoriesFilterTab: String, CaseIterable, Identifiable, Sendable {
    case all
    case photos
    case videos
    case drawings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all:      return "All"
        case .photos:   return "Photos"
        case .videos:   return "Videos"
        case .drawings: return "Drawings"
        }
    }

    public func matches(_ kind: MessageKind) -> Bool {
        switch self {
        case .all:      return true
        case .photos:   return kind == .image
        case .videos:   return kind == .video
        case .drawings: return kind == .drawing
        }
    }
}

public enum MemoriesSortOrder: String, CaseIterable, Identifiable, Sendable {
    case newestFirst
    case oldestFirst

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .newestFirst: return "Newest first"
        case .oldestFirst: return "Oldest first"
        }
    }
}

private struct MemoriesMonthSection: Identifiable, Equatable {
    let monthKey: String
    let displayTitle: String
    let items: [MemoryItem]
    var id: String { monthKey }
}

private struct MemoriesLightboxSession: Equatable {
    let urls: [String]
    let initialIndex: Int
}

public struct MemoriesRootView: View {
    private let store: AppStore
    private let metrics: DuoLayoutMetrics
    private let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tabUnderlineNamespace

    @State private var selectedTab: MemoriesFilterTab = .all
    @State private var sortOrder: MemoriesSortOrder = .newestFirst
    @State private var searchQuery: String = ""
    @State private var isPresentingFlashback: Bool = false
    @State private var activeLightbox: MemoriesLightboxSession?

    public init(
        store: AppStore,
        metrics: DuoLayoutMetrics,
        onClose: @escaping () -> Void
    ) {
        self.store = store
        self.metrics = metrics
        self.onClose = onClose
    }

    // MARK: - Spatial & Posture Clearances

    private var rightRailClearance: CGFloat {
        if metrics.hasRightSystemColumn {
            return max(metrics.safeAreaRight, metrics.railWidth + 24)
        }
        return max(16, metrics.safeAreaRight + 16)
    }

    private var leadingInset: CGFloat {
        max(16, metrics.safeAreaLeft + 16)
    }

    // MARK: - Unified Archive Pipeline (`store.memories` + Live Shared Room Media/Drawings)

    private var mergedAllMemories: [MemoryItem] {
        var combined: [MemoryItem] = store.memories
        var seenURLs = Set(store.memories.map(\.mediaURL))

        // Automatically surface any newly sent photos, videos, or drawings from active chats (`memories.js:1-2`)
        let roomTitlesByID = Dictionary(
            store.rooms.map { ($0.id, $0.title) },
            uniquingKeysWith: { first, _ in first }
        )

        for (roomID, messages) in store.messagesByRoom {
            let roomTitle = roomTitlesByID[roomID] ?? "Conversation"
            for msg in messages where msg.deliveryState != .revoked {
                guard msg.kind == .image || msg.kind == .video || msg.kind == .drawing else { continue }
                for (offset, url) in msg.mediaURLs.enumerated() where !url.isEmpty {
                    if seenURLs.insert(url).inserted {
                        combined.append(
                            MemoryItem(
                                id: "live_mem_\(msg.id)_\(offset)",
                                kind: msg.kind,
                                mediaURL: url,
                                caption: msg.text,
                                roomTitle: roomTitle,
                                monthKey: Self.monthKey(fromEpoch: msg.createdAt),
                                createdAt: msg.createdAt
                            )
                        )
                    }
                }
            }
        }

        return combined.sorted { $0.createdAt > $1.createdAt }
    }

    private var trimmedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredMemories: [MemoryItem] {
        let q = trimmedSearchQuery.lowercased()
        let filtered = mergedAllMemories.filter { item in
            guard selectedTab.matches(item.kind) else { return false }
            guard !q.isEmpty else { return true }
            let monthTitle = Self.formattedMonthTitle(monthKey: item.monthKey, fallbackEpoch: item.createdAt).lowercased()
            return item.roomTitle.lowercased().contains(q)
                || item.caption.lowercased().contains(q)
                || item.monthKey.lowercased().contains(q)
                || monthTitle.contains(q)
        }
        switch sortOrder {
        case .newestFirst:
            return filtered.sorted { $0.createdAt > $1.createdAt }
        case .oldestFirst:
            return filtered.sorted { $0.createdAt < $1.createdAt }
        }
    }

    private var monthSections: [MemoriesMonthSection] {
        var groups: [MemoriesMonthSection] = []
        for item in filteredMemories {
            let key = item.monthKey.isEmpty ? Self.monthKey(fromEpoch: item.createdAt) : item.monthKey
            if let lastIdx = groups.indices.last, groups[lastIdx].monthKey == key {
                let prev = groups[lastIdx]
                groups[lastIdx] = MemoriesMonthSection(
                    monthKey: prev.monthKey,
                    displayTitle: prev.displayTitle,
                    items: prev.items + [item]
                )
            } else {
                groups.append(
                    MemoriesMonthSection(
                        monthKey: key,
                        displayTitle: Self.formattedMonthTitle(monthKey: key, fallbackEpoch: item.createdAt),
                        items: [item]
                    )
                )
            }
        }
        return groups
    }

    /// Latest month's items used for the Monthly Recap Flashback card & slideshow (`memories.js:114-120`).
    private var recapItems: [MemoryItem] {
        guard let newest = mergedAllMemories.first else { return [] }
        let latestMonthKey = newest.monthKey.isEmpty ? Self.monthKey(fromEpoch: newest.createdAt) : newest.monthKey
        let sameMonth = mergedAllMemories.filter {
            ($0.monthKey.isEmpty ? Self.monthKey(fromEpoch: $0.createdAt) : $0.monthKey) == latestMonthKey
        }
        return sameMonth.isEmpty ? Array(mergedAllMemories.prefix(6)) : sameMonth
    }

    private var recapHeroItem: MemoryItem? {
        recapItems.first(where: { $0.kind == .image }) ?? recapItems.first
    }

    private var recapMonthTitle: String {
        guard let hero = recapHeroItem else { return "Monthly" }
        return Self.formattedMonthTitle(monthKey: hero.monthKey, fallbackEpoch: hero.createdAt)
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            CuvenColors.paperBackground
                .ignoresSafeArea()

            Group {
                switch metrics.posture {
                case .duoHalfBook:
                    duoHalfBookSpreadLayout
                case .duoHalfLaptop:
                    duoHalfLaptopTabletopLayout
                default:
                    standardVerticalArchiveLayout
                }
            }

            // Fullscreen Pinch-Zoom Media Lightbox Overlay (`testB36`: closes only viewer, keeps Memories open)
            if let session = activeLightbox {
                FullscreenMediaLightboxView(
                    mediaURLs: session.urls,
                    initialIndex: session.initialIndex,
                    onDismiss: {
                        withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
                            activeLightbox = nil
                        }
                    }
                )
                .zIndex(80)
                .transition(.opacity)
            }

            // Monthly Recap Flashback Cinema Overlay (`memories.flashbackPlay` -> `MemoriesFlashbackSlideshowView`)
            if isPresentingFlashback, !recapItems.isEmpty {
                MemoriesFlashbackSlideshowView(
                    title: "My \(recapMonthTitle) recap",
                    subtitle: "\(recapItems.count) memories from your chats",
                    items: recapItems,
                    serverBaseURL: store.serverBaseURL,
                    rightRailClearance: rightRailClearance,
                    leftSafeInset: leadingInset,
                    topSafeInset: metrics.safeAreaTop,
                    bottomSafeInset: metrics.safeAreaBottom,
                    onDismiss: {
                        withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
                            isPresentingFlashback = false
                        }
                    }
                )
                .zIndex(90)
                .transition(.opacity)
            }
        }
    }

    // MARK: - 1. Standard / Duo Open / Compact Vertical Layout

    private var standardVerticalArchiveLayout: some View {
        VStack(spacing: 0) {
            headerBar
                .padding(.top, max(12, metrics.safeAreaTop + 6))
                .padding(.leading, leadingInset)
                .padding(.trailing, rightRailClearance)
                .padding(.bottom, 10)

            searchFieldBar
                .padding(.leading, leadingInset)
                .padding(.trailing, rightRailClearance)
                .padding(.bottom, 8)

            filterTabStrip
                .padding(.leading, leadingInset)
                .padding(.trailing, rightRailClearance)

            Divider()
                .overlay(CuvenColors.hairlineSeparator)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    if trimmedSearchQuery.isEmpty, let hero = recapHeroItem {
                        monthlyRecapHeroCard(hero: hero, count: recapItems.count, compactHeight: false)
                            .padding(.top, 14)
                    }

                    monthGridSectionsContent
                }
                .padding(.leading, leadingInset)
                .padding(.trailing, rightRailClearance)
                .padding(.top, trimmedSearchQuery.isEmpty ? 0 : 14)
                .padding(.bottom, max(36, metrics.safeAreaBottom + 24))
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("memories.grid")
        }
    }

    // MARK: - 2. Duo Half-Book Spread Layout (`462pt | hinge | 461pt`)

    private var duoHalfBookSpreadLayout: some View {
        let hingeWidth = metrics.hingeDivisionRect?.width ?? 28
        let leftWidth = metrics.leadingColumnWidth > 0 ? metrics.leadingColumnWidth : 440

        return HStack(spacing: 0) {
            // Left Book Page: Header + Search + Filter Tabs + Monthly Recap Flashback Card
            VStack(alignment: .leading, spacing: 14) {
                headerBar
                searchFieldBar
                filterTabStrip

                if let hero = recapHeroItem {
                    monthlyRecapHeroCard(hero: hero, count: recapItems.count, compactHeight: false)
                }

                Spacer(minLength: 0)
            }
            .padding(.top, max(12, metrics.safeAreaTop + 6))
            .padding(.leading, leadingInset)
            .padding(.trailing, 14)
            .padding(.bottom, max(16, metrics.safeAreaBottom + 8))
            .frame(width: leftWidth)

            // Book Hinge Gutter
            Rectangle()
                .fill(CuvenColors.hingeGutterShade)
                .frame(width: hingeWidth)
                .ignoresSafeArea()

            // Right Book Page: Month-Grouped 4-Column Square Media Grid (clear of right DuoRail)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    monthGridSectionsContent
                }
                .padding(.top, max(14, metrics.safeAreaTop + 8))
                .padding(.leading, 14)
                .padding(.trailing, rightRailClearance)
                .padding(.bottom, max(32, metrics.safeAreaBottom + 20))
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("memories.grid")
        }
    }

    // MARK: - 3. Duo Half-Laptop Tabletop Split Layout

    private var duoHalfLaptopTabletopLayout: some View {
        GeometryReader { proxy in
            let hingeY = metrics.hingeDivisionRect?.minY ?? (proxy.size.height * 0.48)
            let hingeHeight = max(20, metrics.hingeDivisionRect?.height ?? 28)
            let upperHeight = max(200, min(hingeY, proxy.size.height * 0.52))

            VStack(spacing: 0) {
                // Upper Display Pane above horizontal crease: Header + Monthly Recap Hero Card
                VStack(spacing: 10) {
                    headerBar
                    if let hero = recapHeroItem {
                        monthlyRecapHeroCard(hero: hero, count: recapItems.count, compactHeight: true)
                    }
                }
                .padding(.top, max(10, metrics.safeAreaTop + 4))
                .padding(.leading, leadingInset)
                .padding(.trailing, rightRailClearance)
                .padding(.bottom, 8)
                .frame(height: upperHeight)

                Rectangle()
                    .fill(CuvenColors.hingeGutterShade)
                    .frame(height: hingeHeight)

                // Lower Tabletop Deck: Search + Filter Tabs + 4-Column Month Grid
                VStack(spacing: 6) {
                    searchFieldBar
                        .padding(.top, 8)
                        .padding(.leading, leadingInset)
                        .padding(.trailing, rightRailClearance)

                    filterTabStrip
                        .padding(.leading, leadingInset)
                        .padding(.trailing, rightRailClearance)

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 18) {
                            monthGridSectionsContent
                        }
                        .padding(.leading, leadingInset)
                        .padding(.trailing, rightRailClearance)
                        .padding(.vertical, 10)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("memories.grid")
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: - Shared Subviews

    private var headerBar: some View {
        HStack(spacing: 12) {
            Button {
                CuvenHaptics.lightTap()
                onClose()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CuvenColors.inkPrimary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.cuvenGlassPill(mode: store.prefs.glassMode, cornerRadius: 22))
            .accessibilityLabel("Close")
            .accessibilityIdentifier("memories.close")

            Text("Memories")
                .font(CuvenFonts.clarinettaDisplay(size: 28, weight: .bold))
                .foregroundStyle(CuvenColors.inkPrimary)

            Spacer()

            Menu {
                ForEach(MemoriesSortOrder.allCases) { option in
                    Button {
                        CuvenHaptics.selectionChanged()
                        sortOrder = option
                    } label: {
                        if sortOrder == option {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CuvenColors.inkPrimary)
                    .frame(width: 44, height: 44)
                    .cuvenLiquidGlass(mode: store.prefs.glassMode, cornerRadius: 22)
            }
            .accessibilityLabel("Sort order")
            .accessibilityIdentifier("memories.sortMenu")
        }
        .cuvenCappedDynamicType()
    }

    private var searchFieldBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(CuvenColors.inkTertiary)

            TextField("Search by chat, person, or month", text: $searchQuery)
                .font(CuvenFonts.cappedBody())
                .foregroundStyle(CuvenColors.inkPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .accessibilityIdentifier("memories.searchField")

            if !searchQuery.isEmpty {
                Button {
                    CuvenHaptics.lightTap()
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(CuvenColors.inkTertiary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("memories.clearSearch")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(CuvenColors.fieldBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .cuvenCappedDynamicType()
    }

    private var filterTabStrip: some View {
        HStack(spacing: 4) {
            ForEach(MemoriesFilterTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button {
                    guard selectedTab != tab else { return }
                    CuvenHaptics.selectionChanged()
                    withAnimation(CuvenSprings.adaptive(CuvenSprings.pressBounce, reduceMotion: reduceMotion)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 7) {
                        Text(tab.title)
                            .font(CuvenFonts.cappedSubheadline(weight: isSelected ? .bold : .medium))
                            .foregroundStyle(isSelected ? CuvenColors.inkPrimary : CuvenColors.inkSecondary)

                        ZStack {
                            Capsule()
                                .fill(Color.clear)
                                .frame(height: 2.5)
                            if isSelected {
                                Capsule()
                                    .fill(CuvenColors.ctaInk)
                                    .frame(height: 2.5)
                                    .matchedGeometryEffect(id: "memoriesTabUnderline", in: tabUnderlineNamespace)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("memories.tab.\(tab.rawValue)")
            }
        }
        .cuvenCappedDynamicType()
    }

    // MARK: - Monthly Recap Flashback Hero Card (`memories.flashbackPlay`)

    private func monthlyRecapHeroCard(hero: MemoryItem, count: Int, compactHeight: Bool) -> some View {
        let cardShape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        let cardHeight: CGFloat = compactHeight ? 128 : 204

        return Button {
            CuvenHaptics.softImpact()
            withAnimation(CuvenSprings.adaptive(CuvenSprings.sheetPresent, reduceMotion: reduceMotion)) {
                isPresentingFlashback = true
            }
        } label: {
            ZStack(alignment: .bottomLeading) {
                CuvenMediaAssetView(
                    urlString: hero.mediaURL,
                    isDrawing: hero.kind == .drawing,
                    contentMode: .fill,
                    serverBaseURL: store.serverBaseURL
                )
                .frame(maxWidth: .infinity)
                .frame(height: cardHeight)
                .clipped()

                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.15),
                        .init(color: .black.opacity(0.72), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("My \(recapMonthTitle) recap")
                            .font(CuvenFonts.clarinettaDisplay(size: compactHeight ? 20 : 24, weight: .bold))
                            .foregroundStyle(.white)

                        Text("\(count) \(count == 1 ? "memory" : "photos, videos & drawings") from your chats")
                            .font(CuvenFonts.cappedFootnote(weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.84))
                            .lineLimit(1)
                    }

                    Spacer()

                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 46, height: 46)
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.45), lineWidth: 0.8))
                        Image(systemName: "play.fill")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: 1.5)
                    }
                }
                .padding(18)
            }
            .frame(height: cardHeight)
            .clipShape(cardShape)
            .overlay(cardShape.strokeBorder(CuvenColors.cardLine, lineWidth: 1.0))
            .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("My \(recapMonthTitle) recap, \(count) memories. Play flashback")
        .accessibilityIdentifier("memories.flashbackPlay")
    }

    // MARK: - Month-Grouped 4-Column Square Grid (`memories.js:126-169`)

    @ViewBuilder
    private var monthGridSectionsContent: some View {
        if monthSections.isEmpty {
            emptyArchiveStateView
        } else {
            let fourColumns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 4)

            ForEach(monthSections) { section in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(section.displayTitle)
                            .font(CuvenFonts.cappedTitle2(weight: .bold))
                            .foregroundStyle(CuvenColors.inkPrimary)

                        Text("\(section.items.count)")
                            .font(CuvenFonts.cappedSubheadline(weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(CuvenColors.inkSecondary)

                        Spacer()
                    }

                    LazyVGrid(columns: fourColumns, spacing: 3) {
                        ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                            memorySquareTile(item: item, sectionItems: section.items, indexInSection: index)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }

    private func memorySquareTile(
        item: MemoryItem,
        sectionItems: [MemoryItem],
        indexInSection: Int
    ) -> some View {
        let kindLabel: String = {
            switch item.kind {
            case .video:   return "Video"
            case .drawing: return "Drawing"
            default:       return "Photo"
            }
        }()

        return Button {
            CuvenHaptics.lightTap()
            let urls = sectionItems.map(\.mediaURL)
            withAnimation(CuvenSprings.adaptive(CuvenSprings.sheetPresent, reduceMotion: reduceMotion)) {
                activeLightbox = MemoriesLightboxSession(urls: urls, initialIndex: indexInSection)
            }
        } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    CuvenMediaAssetView(
                        urlString: item.mediaURL,
                        isDrawing: item.kind == .drawing,
                        contentMode: .fill,
                        serverBaseURL: store.serverBaseURL
                    )
                }
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    if item.kind == .video {
                        HStack(spacing: 3) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text("0:15")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.58), in: Capsule())
                        .padding(5)
                    } else if item.kind == .drawing {
                        Image(systemName: "paintbrush.pointed.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(Color.black.opacity(0.54), in: Circle())
                            .padding(5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(kindLabel) from \(item.roomTitle)\(item.caption.isEmpty ? "" : ", \(item.caption)")")
        .accessibilityIdentifier("memories.tile.\(item.id)")
    }

    private var emptyArchiveStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: trimmedSearchQuery.isEmpty ? "photo.on.rectangle" : "magnifyingglass")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(CuvenColors.inkTertiary)

            Text(trimmedSearchQuery.isEmpty ? "No memories yet" : "Nothing found")
                .font(CuvenFonts.cappedHeadline(weight: .bold))
                .foregroundStyle(CuvenColors.inkPrimary)

            Text(
                trimmedSearchQuery.isEmpty
                    ? "Photos, videos, and drawings shared in your chats are kept here automatically."
                    : "Nothing from a chat or caption matching “\(trimmedSearchQuery)”."
            )
            .font(CuvenFonts.cappedSubheadline())
            .foregroundStyle(CuvenColors.inkSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)

            if !trimmedSearchQuery.isEmpty {
                Button {
                    CuvenHaptics.lightTap()
                    searchQuery = ""
                } label: {
                    Text("Reset search")
                        .font(CuvenFonts.cappedSubheadline(weight: .semibold))
                        .foregroundStyle(CuvenColors.sidebarBlue)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
    }

    // MARK: - Month Key Formatting Helpers (`memories.js:17-23`)

    private static let englishMonthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December"
    ]

    private static func monthKey(fromEpoch rawEpoch: Int64) -> String {
        let seconds = rawEpoch > 10_000_000_000 ? Double(rawEpoch) / 1000.0 : Double(rawEpoch)
        let date = Date(timeIntervalSince1970: seconds)
        let comps = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
        let y = comps.year ?? 2026
        let m = comps.month ?? 1
        return String(format: "%04d-%02d", y, m)
    }

    private static func formattedMonthTitle(monthKey: String, fallbackEpoch: Int64) -> String {
        let nowYear = Calendar(identifier: .gregorian).component(.year, from: Date())
        let parts = monthKey.split(separator: "-")
        if parts.count == 2,
           let year = Int(parts[0]),
           let month = Int(parts[1]),
           (1...12).contains(month) {
            let monthName = englishMonthNames[month - 1]
            return year == nowYear ? monthName : "\(monthName) \(year)"
        }

        let seconds = fallbackEpoch > 10_000_000_000 ? Double(fallbackEpoch) / 1000.0 : Double(fallbackEpoch)
        let date = Date(timeIntervalSince1970: seconds)
        let comps = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
        let monthIdx = max(1, min(12, comps.month ?? 1)) - 1
        let year = comps.year ?? nowYear
        let monthName = englishMonthNames[monthIdx]
        return year == nowYear ? monthName : "\(monthName) \(year)"
    }
}

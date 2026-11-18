import SwiftUI
import CuvenCore

// MARK: - "For You" Smart Insights Card Deck (`chatlist.insightsDeck`)
//
// Grounding References:
// - Apple Human Interface Guidelines: Designing for iPhone Duo (horizontal scroll-snap deck
//   respecting leading/trailing column margins and right-edge 84–91pt system column)
// - Apple Human Interface Guidelines: Typography & Contrast (Clarinetta editorial heading,
//   tabular numerals for peer timezone clocks & temperatures, >= 44pt touch targets)
// - Apple Human Interface Guidelines: Motion (Reduce Motion cross-fade fallback, 1:1 interactive
//   card dismiss gesture with spring reflow)
// - Cuven Web Reference: `public/js/views/insights.js`, `src/insights.js`, `src/weather.js`,
//   `public/css/insights.css` (1.5pt dashed horizontal rules, 46pt full-width Ink CTA)

public enum InsightDeckCategory: String, CaseIterable, Identifiable, Sendable {
    case plans
    case people
    case photos
    case weather

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .plans: return "Plans"
        case .people: return "People"
        case .photos: return "Photos"
        case .weather: return "Weather"
        }
    }

    var systemImage: String {
        switch self {
        case .plans: return "calendar"
        case .people: return "person.2"
        case .photos: return "photo"
        case .weather: return "sun.max"
        }
    }
}

struct SynthesizedInsightCard: Identifiable, Equatable {
    struct RowItem: Identifiable, Equatable {
        enum LeadingVisual: Equatable {
            case avatar(name: String, urlString: String?, isOnline: Bool)
            case symbol(name: String)
            case photoBadge(urlString: String?)
        }

        let id: String
        let leading: LeadingVisual
        let label: String
        let value: String
    }

    let id: String
    let category: InsightDeckCategory
    let roomID: String
    let peerName: String
    let headerState: String
    let headerWhen: String
    let weatherChipText: String?
    let rows: [RowItem]
    let actionLabel: String?
    let actionSystemImage: String
    let actionDestinationQuery: String?
    let priority: Int
}

public struct SmartInsightsDeckView: View {
    private let store: AppStore
    private let metrics: DuoLayoutMetrics

    @Namespace private var categoryChipNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    @State private var selectedCategory: InsightDeckCategory?
    @State private var dismissedCardIDs: Set<String> = []
    @State private var isRefreshing = false
    @State private var refreshGeneration = 0

    public init(store: AppStore, metrics: DuoLayoutMetrics) {
        self.store = store
        self.metrics = metrics
    }

    private var horizontalInset: CGFloat {
        metrics.visibleColumnCount == 2 ? 18 : 20
    }

    private var trailingSafePadding: CGFloat {
        ChatListSpatialMetrics.trailingSystemColumnInset(for: metrics)
    }

    private var singleCardWidth: CGFloat {
        let colWidth = ChatListSpatialMetrics.effectiveColumnWidth(for: metrics)
        return min(306, max(252, colWidth - horizontalInset * 2))
    }

    private var multiCardWidth: CGFloat {
        let colWidth = ChatListSpatialMetrics.effectiveColumnWidth(for: metrics)
        return min(268, max(236, colWidth - horizontalInset * 2 - 24))
    }

    private var allCards: [SynthesizedInsightCard] {
        guard store.prefs.smartAssistEnabled else { return [] }
        return buildCards()
            .filter { !dismissedCardIDs.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return lhs.priority > rhs.priority
                }
                return lhs.id < rhs.id
            }
    }

    private var availableCategories: [InsightDeckCategory] {
        let present = Set(allCards.map(\.category))
        return InsightDeckCategory.allCases.filter { present.contains($0) }
    }

    private var activeCategory: InsightDeckCategory? {
        if let selected = selectedCategory, availableCategories.contains(selected) {
            return selected
        }
        // Lead with the highest-priority card's category (`insights.js:235`)
        return allCards.first?.category ?? availableCategories.first
    }

    private var visibleCards: [SynthesizedInsightCard] {
        guard let category = activeCategory else { return [] }
        return allCards.filter { $0.category == category }
    }

    public var body: some View {
        if !allCards.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                // Header: Clarinetta "For you" + interactive Refresh button
                HStack(alignment: .center, spacing: 8) {
                    Text("For you")
                        .font(CuvenFonts.clarinettaDisplay(size: 20, weight: .bold, italic: false))
                        .foregroundStyle(CuvenColors.inkPrimary)

                    Spacer()

                    Button {
                        triggerRefresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(CuvenColors.inkSecondary)
                            .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                            .animation(
                                reduceMotion ? nil : .easeInOut(duration: 0.55),
                                value: isRefreshing
                            )
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Refresh smart insights")
                    .accessibilityIdentifier("chatlist.insightsDeck.refresh")
                }
                .padding(.leading, horizontalInset + metrics.safeAreaLeft)
                .padding(.trailing, max(10, horizontalInset - 10) + trailingSafePadding)

                // 4-Category Gliding Chips (`Plans / People / Photos / Weather`, `insights.css:28-62`)
                if availableCategories.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(availableCategories) { category in
                                let isSelected = category == activeCategory
                                Button {
                                    CuvenHaptics.selectionChanged()
                                    if reduceMotion {
                                        selectedCategory = category
                                    } else {
                                        withAnimation(CuvenSprings.railMorph) {
                                            selectedCategory = category
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: weatherAwareChipSymbol(for: category))
                                            .font(.system(size: 13.5, weight: .semibold))
                                        Text(category.label)
                                            .font(CuvenFonts.cappedCaption())
                                            .fontWeight(.semibold)
                                    }
                                    .foregroundStyle(isSelected ? CuvenColors.paperBackground : CuvenColors.inkPrimary)
                                    .padding(.horizontal, 14)
                                    .frame(height: 36)
                                    .background {
                                        if isSelected {
                                            Capsule()
                                                .fill(CuvenColors.inkPrimary)
                                                .matchedGeometryEffect(
                                                    id: "chatlist.insights.activeCategory",
                                                    in: categoryChipNamespace
                                                )
                                        } else {
                                            Capsule()
                                                .fill(ChatListPalette.subtleChipFill)
                                        }
                                    }
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                                .accessibilityIdentifier("chatlist.insightsDeck.tab.\(category.rawValue)")
                            }
                        }
                        .padding(.leading, horizontalInset + metrics.safeAreaLeft)
                        .padding(.trailing, horizontalInset + trailingSafePadding)
                    }
                }

                // Horizontal Snap Cards (`insights.css:65-162`)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(visibleCards) { card in
                            InsightDeckCardView(
                                card: card,
                                cardWidth: visibleCards.count == 1 ? singleCardWidth : multiCardWidth,
                                reduceMotion: reduceMotion,
                                onPrimaryAction: {
                                    handleCardAction(card)
                                },
                                onDismiss: {
                                    dismissCard(card.id)
                                }
                            )
                            .accessibilityIdentifier("chatlist.insightsDeck.card.\(card.id)")
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.leading, horizontalInset + metrics.safeAreaLeft)
                    .padding(.trailing, horizontalInset + trailingSafePadding)
                    .padding(.bottom, 4)
                }
                .scrollTargetBehavior(.viewAligned)
                .id("\(activeCategory?.rawValue ?? "none")-\(refreshGeneration)")
            }
            .padding(.vertical, 6)
            .accessibilityIdentifier("chatlist.insightsDeck")
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: - Actions

    private func triggerRefresh() {
        CuvenHaptics.softImpact()
        isRefreshing = true
        if reduceMotion {
            dismissedCardIDs.removeAll()
            refreshGeneration &+= 1
        } else {
            withAnimation(CuvenSprings.sheetPresent) {
                dismissedCardIDs.removeAll()
                refreshGeneration &+= 1
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(560))
            isRefreshing = false
        }
    }

    private func dismissCard(_ cardID: String) {
        CuvenHaptics.lightTap()
        if reduceMotion {
            dismissedCardIDs.insert(cardID)
        } else {
            withAnimation(CuvenSprings.railMorph) {
                _ = dismissedCardIDs.insert(cardID)
            }
        }
    }

    private func handleCardAction(_ card: SynthesizedInsightCard) {
        CuvenHaptics.lightTap()
        if let query = card.actionDestinationQuery,
           let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let mapsURL = URL(string: "http://maps.apple.com/?q=\(encoded)") {
            openURL(mapsURL)
            return
        }
        store.selectRoom(card.roomID)
    }

    // MARK: - Genuine Card Synthesis from `store.insightsByRoom`, `store.rooms`, & `store.messagesByRoom`

    private func buildCards() -> [SynthesizedInsightCard] {
        let roomMap = Dictionary(uniqueKeysWithValues: store.rooms.filter { !$0.isHidden }.map { ($0.id, $0) })
        let onlineByUser = Dictionary(uniqueKeysWithValues: store.contacts.map { ($0.user.id, $0.user.isOnline) })
        var cards: [SynthesizedInsightCard] = []

        let sortedInsights = store.insightsByRoom.values.sorted { lhs, rhs in
            let leftTS = roomMap[lhs.roomID]?.lastMessageTimestamp ?? 0
            let rightTS = roomMap[rhs.roomID]?.lastMessageTimestamp ?? 0
            return leftTS > rightTS
        }

        for insight in sortedInsights {
            guard let room = roomMap[insight.roomID] else { continue }
            let peerOnline = room.peerUserID.flatMap { onlineByUser[$0] } ?? false
            let weatherChip: String? = {
                switch (insight.temperatureText, insight.weatherSummary) {
                case let (temp?, summary?) where !temp.isEmpty && !summary.isEmpty:
                    return "\(temp) · \(summary)"
                case let (temp?, _):
                    return temp.isEmpty ? nil : temp
                case let (_, summary?):
                    return summary.isEmpty ? nil : summary
                case (nil, nil):
                    return nil
                }
            }()

            let lowerSummary = insight.summary.lowercased()
            let hasPlanSignal = insight.actionChip != nil
                || lowerSummary.contains("meet")
                || lowerSummary.contains("ride")
                || lowerSummary.contains("byd")
                || lowerSummary.contains("flight")
                || lowerSummary.contains("landed")
                || lowerSummary.contains("tomorrow")
                || lowerSummary.contains("weekend")
                || lowerSummary.contains("hiking")
                || lowerSummary.contains("coffee")
                || lowerSummary.contains("starbucks")
                || lowerSummary.contains(":")

            // 1. Plans Card (`Plans` tab)
            if hasPlanSignal {
                let isRide = lowerSummary.contains("ride") || lowerSummary.contains("byd") || lowerSummary.contains("car")
                let isDirections = (insight.actionChip?.lowercased().contains("direction") ?? false)
                    || lowerSummary.contains("starbucks")
                    || lowerSummary.contains("west lake")
                let stateLabel = isRide ? "On the trip" : (isDirections ? "Meetup" : "Follow-up")
                let leadSymbol = isRide ? "car.fill" : (isDirections ? "mappin.and.ellipse" : "calendar.badge.clock")

                var planRows: [SynthesizedInsightCard.RowItem] = [
                    .init(
                        id: "\(insight.id)-peer",
                        leading: .avatar(name: room.title, urlString: room.avatarURL, isOnline: peerOnline),
                        label: room.title,
                        value: insight.peerLocalTime ?? ""
                    ),
                    .init(
                        id: "\(insight.id)-summary",
                        leading: .symbol(name: leadSymbol),
                        label: insight.summary,
                        value: ""
                    )
                ]
                if let weatherChip {
                    planRows.append(
                        .init(
                            id: "\(insight.id)-wxchip",
                            leading: .symbol(name: weatherSymbol(from: insight.weatherSummary)),
                            label: insight.weatherSummary ?? "Local weather",
                            value: insight.temperatureText ?? ""
                        )
                    )
                }

                cards.append(
                    SynthesizedInsightCard(
                        id: "\(insight.id)-plan",
                        category: .plans,
                        roomID: room.id,
                        peerName: room.title,
                        headerState: stateLabel,
                        headerWhen: insight.peerLocalTime ?? "Today",
                        weatherChipText: weatherChip,
                        rows: planRows,
                        actionLabel: insight.actionChip ?? "Open chat",
                        actionSystemImage: isDirections ? "location.fill" : "bubble.left.fill",
                        actionDestinationQuery: isDirections && (insight.actionChip?.lowercased().contains("direction") ?? false) ? room.subtitle : nil,
                        priority: 95
                    )
                )
            }

            // 2. People Recap / Check-in Card (`People` tab)
            let isMoodCheckIn = lowerSummary.contains("tired") || lowerSummary.contains("busy") || lowerSummary.contains("sick")
            cards.append(
                SynthesizedInsightCard(
                    id: "\(insight.id)-people",
                    category: .people,
                    roomID: room.id,
                    peerName: room.title,
                    headerState: isMoodCheckIn ? "Checking in" : "Recap",
                    headerWhen: insight.peerLocalTime ?? (peerOnline ? "Online" : "Recent"),
                    weatherChipText: weatherChip,
                    rows: [
                        .init(
                            id: "\(insight.id)-people-avatar",
                            leading: .avatar(name: room.title, urlString: room.avatarURL, isOnline: peerOnline),
                            label: room.title,
                            value: insight.peerLocalTime ?? ""
                        ),
                        .init(
                            id: "\(insight.id)-people-note",
                            leading: .symbol(name: isMoodCheckIn ? "heart.fill" : "sparkles"),
                            label: insight.summary,
                            value: ""
                        )
                    ],
                    actionLabel: isMoodCheckIn ? "Say hi" : (insight.actionChip ?? "Open chat"),
                    actionSystemImage: "bubble.left.fill",
                    actionDestinationQuery: nil,
                    priority: hasPlanSignal ? 72 : 88
                )
            )

            // 3. Open-Meteo Weather Card (`Weather` tab — `src/weather.js`, `insights.js:181-190`)
            if insight.weatherSummary != nil || insight.temperatureText != nil {
                var weatherRows: [SynthesizedInsightCard.RowItem] = [
                    .init(
                        id: "\(insight.id)-wx-main",
                        leading: .symbol(name: weatherSymbol(from: insight.weatherSummary)),
                        label: insight.weatherSummary ?? "Clear",
                        value: insight.temperatureText ?? ""
                    )
                ]
                if let localClock = insight.peerLocalTime, !localClock.isEmpty {
                    weatherRows.append(
                        .init(
                            id: "\(insight.id)-wx-clock",
                            leading: .avatar(name: room.title, urlString: room.avatarURL, isOnline: peerOnline),
                            label: "\(room.title)'s local time",
                            value: localClock
                        )
                    )
                }

                cards.append(
                    SynthesizedInsightCard(
                        id: "\(insight.id)-weather",
                        category: .weather,
                        roomID: room.id,
                        peerName: room.title,
                        headerState: "\(room.title)'s area",
                        headerWhen: insight.peerLocalTime ?? "Now",
                        weatherChipText: weatherChip,
                        rows: weatherRows,
                        actionLabel: "Open chat",
                        actionSystemImage: "bubble.left.fill",
                        actionDestinationQuery: nil,
                        priority: 68
                    )
                )
            }
        }

        // 4. Shared Photos Cards (`Photos` tab — scans `messagesByRoom` for recent peer images)
        let myID = store.currentUser?.id
        for room in store.rooms where !room.isHidden && room.kind == .dm {
            guard let messages = store.messagesByRoom[room.id] else { continue }
            let peerPhotos = messages
                .filter { $0.kind == .image && $0.senderID != myID && $0.deliveryState != .revoked }
                .suffix(2)
            let peerOnline = room.peerUserID.flatMap { onlineByUser[$0] } ?? false
            for photoMsg in peerPhotos {
                let caption = photoMsg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = caption.isEmpty ? "Shared a photo with you" : caption
                cards.append(
                    SynthesizedInsightCard(
                        id: "photo-\(photoMsg.id)",
                        category: .photos,
                        roomID: room.id,
                        peerName: room.title,
                        headerState: "Take a look",
                        headerWhen: ChatListTimeFormatter.listTime(
                            from: photoMsg.createdAt,
                            use24Hour: store.prefs.use24HourTime
                        ),
                        weatherChipText: nil,
                        rows: [
                            .init(
                                id: "photo-row-\(photoMsg.id)",
                                leading: .photoBadge(urlString: photoMsg.mediaURLs.first),
                                label: label,
                                value: ""
                            ),
                            .init(
                                id: "photo-peer-\(photoMsg.id)",
                                leading: .avatar(name: room.title, urlString: room.avatarURL, isOnline: peerOnline),
                                label: room.title,
                                value: ""
                            )
                        ],
                        actionLabel: "View in chat",
                        actionSystemImage: "photo.fill",
                        actionDestinationQuery: nil,
                        priority: 64
                    )
                )
            }
        }

        return cards
    }

    private func weatherAwareChipSymbol(for category: InsightDeckCategory) -> String {
        guard category == .weather else { return category.systemImage }
        let firstWeather = store.insightsByRoom.values.compactMap(\.weatherSummary).first
        return weatherSymbol(from: firstWeather)
    }

    private func weatherSymbol(from summary: String?) -> String {
        let lower = (summary ?? "").lowercased()
        if lower.contains("thunder") || lower.contains("storm") { return "cloud.bolt.rain.fill" }
        if lower.contains("snow") { return "cloud.snow.fill" }
        if lower.contains("rain") || lower.contains("drizzle") { return "cloud.rain.fill" }
        if lower.contains("night") { return "moon.stars.fill" }
        if lower.contains("cloud") || lower.contains("overcast") || lower.contains("fog") { return "cloud.sun.fill" }
        return "sun.max.fill"
    }
}

// MARK: - Individual Smart Insight Card (`insights.css:70-158`)

private struct InsightDeckCardView: View {
    let card: SynthesizedInsightCard
    let cardWidth: CGFloat
    let reduceMotion: Bool
    let onPrimaryAction: () -> Void
    let onDismiss: () -> Void

    @State private var dragOffsetY: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Card Header: State + Peer Local Time / Weather Chip + Dismiss ×
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(card.headerState)
                    .font(CuvenFonts.cappedCaption())
                    .fontWeight(.semibold)
                    .foregroundStyle(CuvenColors.inkPrimary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if !card.headerWhen.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 10, weight: .semibold))
                        Text(card.headerWhen)
                            .font(CuvenFonts.cappedCaption().monospacedDigit())
                    }
                    .foregroundStyle(CuvenColors.inkSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(ChatListPalette.subtleChipFill))
                }

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(ChatListPalette.tertiaryInk)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss \(card.headerState) insight for \(card.peerName)")
            }

            // 1.5pt Dashed Horizontal Rule + Info Rows + 1.5pt Dashed Rule (`insights.css:93-99`)
            VStack(alignment: .leading, spacing: 10) {
                InsightDashedDivider()

                ForEach(card.rows) { row in
                    HStack(alignment: .center, spacing: 10) {
                        leadingVisualView(row.leading)
                            .frame(width: 30, height: 30)

                        Text(row.label)
                            .font(CuvenFonts.cappedCaption())
                            .fontWeight(.medium)
                            .foregroundStyle(CuvenColors.inkPrimary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if !row.value.isEmpty {
                            Text(row.value)
                                .font(CuvenFonts.cappedBody().monospacedDigit())
                                .fontWeight(.bold)
                                .foregroundStyle(CuvenColors.inkPrimary)
                                .lineLimit(1)
                        }
                    }
                    .frame(minHeight: 30)
                }

                if card.actionLabel != nil {
                    InsightDashedDivider()
                }
            }

            Spacer(minLength: 0)

            // Full-width 46pt Ink quick-jump CTA (`insights.css:138-155`)
            if let actionLabel = card.actionLabel {
                Button(action: onPrimaryAction) {
                    HStack(spacing: 7) {
                        Image(systemName: card.actionSystemImage)
                            .font(.system(size: 14, weight: .semibold))
                        Text(actionLabel)
                            .font(CuvenFonts.cappedBody())
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(CuvenColors.paperBackground)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Capsule().fill(CuvenColors.inkPrimary))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chatlist.insightsDeck.action.\(card.id)")
            }
        }
        .padding(16)
        .frame(width: cardWidth)
        .background(
            RoundedRectangle(cornerRadius: ChatListRadii.insightCard, style: .continuous)
                .fill(ChatListPalette.insightCardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChatListRadii.insightCard, style: .continuous)
                .strokeBorder(CuvenColors.hairlineSeparator, lineWidth: 0.8)
        )
        .offset(y: dragOffsetY)
        .opacity(max(0.35, 1.0 - Double(abs(dragOffsetY)) / 140.0))
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onChanged { value in
                    // Vertical upward swipe-to-dismiss without blocking horizontal deck scrolling
                    guard abs(value.translation.height) > abs(value.translation.width) * 1.25,
                          value.translation.height < 0 else { return }
                    dragOffsetY = ChatListSwipeMath.rubberband(
                        overshoot: value.translation.height,
                        dimension: 180,
                        coefficient: 0.65
                    )
                }
                .onEnded { value in
                    if dragOffsetY < -52 || value.predictedEndTranslation.height < -110 {
                        onDismiss()
                    } else if reduceMotion {
                        dragOffsetY = 0
                    } else {
                        withAnimation(CuvenSprings.pressBounce) {
                            dragOffsetY = 0
                        }
                    }
                }
        )
    }

    @ViewBuilder
    private func leadingVisualView(_ visual: SynthesizedInsightCard.RowItem.LeadingVisual) -> some View {
        switch visual {
        case let .avatar(name, urlString, isOnline):
            CuvenAvatarView(name: name, urlString: urlString, size: 30, isOnline: isOnline)

        case let .symbol(name):
            ZStack {
                Circle()
                    .fill(ChatListPalette.subtleChipFill)
                Image(systemName: name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(CuvenColors.inkPrimary)
            }

        case let .photoBadge(urlString):
            if let urlString, !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                CuvenAvatarView(
                    name: "",
                    urlString: urlString,
                    size: 30,
                    isOnline: false,
                    isGroupSquircle: true
                )
            } else {
                photoPlaceholderTile
            }
        }
    }

    private var photoPlaceholderTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(ChatListPalette.subtleChipFill)
            Image(systemName: "photo.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CuvenColors.inkSecondary)
        }
    }
}

private struct InsightDashedDivider: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0.75))
                path.addLine(to: CGPoint(x: proxy.size.width, y: 0.75))
            }
            .stroke(
                CuvenColors.inkPrimary.opacity(0.16),
                style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])
            )
        }
        .frame(height: 1.5)
        .accessibilityHidden(true)
    }
}

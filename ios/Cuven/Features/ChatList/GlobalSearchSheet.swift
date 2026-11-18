import SwiftUI
import CuvenCore

// MARK: - Instant Cross-Room, Message & Contact Global Search (`DISPATCH.md` Item 4)
//
// Grounding References:
// - Apple Human Interface Guidelines: Searching (scoped instant results, recent items before
//   typing, highlighted matched substrings with WCAG AA >= 5.8:1 contrast)
// - Cuven Web Reference: `public/js/views/chatList.js:810-918`, `public/css/list.css:156-178`

public struct GlobalSearchSheet: View {
    enum SearchScope: String, CaseIterable, Identifiable {
        case all
        case chats
        case messages
        case people

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All"
            case .chats: return "Chats"
            case .messages: return "Messages"
            case .people: return "People"
            }
        }
    }

    struct MessageSearchHit: Identifiable {
        let id: String
        let room: Room
        let message: Message
    }

    private let store: AppStore

    @Namespace private var scopePillNamespace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var query = ""
    @State private var selectedScope: SearchScope = .all
    @FocusState private var isSearchFocused: Bool

    public init(store: AppStore) {
        self.store = store
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleRooms: [Room] {
        store.rooms
            .filter { !$0.isHidden }
            .sorted { $0.lastMessageTimestamp > $1.lastMessageTimestamp }
    }

    private var matchingRooms: [Room] {
        guard !trimmedQuery.isEmpty else { return [] }
        return visibleRooms.filter { room in
            room.title.localizedCaseInsensitiveContains(trimmedQuery)
                || room.subtitle.localizedCaseInsensitiveContains(trimmedQuery)
                || room.lastMessagePreview.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private var matchingMessages: [MessageSearchHit] {
        guard !trimmedQuery.isEmpty else { return [] }
        let roomByID = Dictionary(uniqueKeysWithValues: visibleRooms.map { ($0.id, $0) })
        var hits: [MessageSearchHit] = []

        for (roomID, messages) in store.messagesByRoom {
            guard let room = roomByID[roomID] else { continue }
            for message in messages where message.deliveryState != .revoked {
                if message.text.localizedCaseInsensitiveContains(trimmedQuery)
                    || message.senderDisplay.localizedCaseInsensitiveContains(trimmedQuery)
                    || message.highlightedKeywords.contains(where: { $0.localizedCaseInsensitiveContains(trimmedQuery) }) {
                    hits.append(MessageSearchHit(id: "\(roomID)-\(message.id)", room: room, message: message))
                }
            }
        }
        return hits
            .sorted { $0.message.createdAt > $1.message.createdAt }
            .prefix(30)
            .map { $0 }
    }

    private var matchingPeople: [CuvenUser] {
        guard !trimmedQuery.isEmpty else { return [] }
        let normalized = trimmedQuery.hasPrefix("@") ? String(trimmedQuery.dropFirst()) : trimmedQuery
        guard !normalized.isEmpty else { return [] }

        let myID = store.currentUser?.id
        var seen: Set<String> = []
        var matches: [CuvenUser] = []

        for contact in store.contacts where contact.status != .blocked {
            let u = contact.user
            if u.id != myID,
               (u.display.localizedCaseInsensitiveContains(normalized)
                || u.username.localizedCaseInsensitiveContains(normalized)
                || u.bio.localizedCaseInsensitiveContains(normalized)),
               seen.insert(u.id).inserted {
                matches.append(u)
            }
        }
        for person in store.suggestedPeople {
            if person.id != myID,
               (person.display.localizedCaseInsensitiveContains(normalized)
                || person.username.localizedCaseInsensitiveContains(normalized)
                || person.bio.localizedCaseInsensitiveContains(normalized)),
               seen.insert(person.id).inserted {
                matches.append(person)
            }
        }
        return matches
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Top Liquid Glass Search Bar + Cancel (`list.css:156-168`)
                HStack(spacing: 10) {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(CuvenColors.inkSecondary)

                        TextField("Search chats, messages & @people", text: $query)
                            .focused($isSearchFocused)
                            .font(CuvenFonts.cappedBody())
                            .foregroundStyle(CuvenColors.inkPrimary)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .accessibilityIdentifier("globalSearch.input")

                        if !query.isEmpty {
                            Button {
                                query = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(ChatListPalette.tertiaryInk)
                                    .frame(width: 36, height: 36)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear query")
                        }
                    }
                    .padding(.horizontal, 15)
                    .frame(height: 50)
                    .cuvenLiquidGlass(mode: store.prefs.glassMode, cornerRadius: 25, interactiveBounce: false)

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(CuvenColors.inkPrimary)
                            .frame(width: 50, height: 50)
                            .cuvenLiquidGlass(mode: store.prefs.glassMode, cornerRadius: 25, interactiveBounce: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel search")
                    .accessibilityIdentifier("globalSearch.cancelButton")
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

                // Scope Filter Bar when query is active
                if !trimmedQuery.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(SearchScope.allCases) { scope in
                                let isSelected = selectedScope == scope
                                Button {
                                    CuvenHaptics.selectionChanged()
                                    if reduceMotion {
                                        selectedScope = scope
                                    } else {
                                        withAnimation(CuvenSprings.railMorph) {
                                            selectedScope = scope
                                        }
                                    }
                                } label: {
                                    Text(scope.label)
                                        .font(CuvenFonts.cappedCaption())
                                        .fontWeight(isSelected ? .semibold : .medium)
                                        .foregroundStyle(isSelected ? Color.white : CuvenColors.inkSecondary)
                                        .padding(.horizontal, 15)
                                        .frame(height: 36)
                                        .background {
                                            if isSelected {
                                                Capsule()
                                                    .fill(ChatListPalette.filterGlassBlue)
                                                    .matchedGeometryEffect(
                                                        id: "globalSearch.scopePill",
                                                        in: scopePillNamespace
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
                                .accessibilityIdentifier("globalSearch.scope.\(scope.rawValue)")
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 6)
                }

                // Results Scroll Area (`chatList.js:882-917`)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if trimmedQuery.isEmpty {
                            recentConversationsSection
                        } else {
                            populatedQueryResults
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 32)
                }
            }
            .background(CuvenColors.paperBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                isSearchFocused = true
            }
        }
        .accessibilityIdentifier("globalSearch.sheet")
    }

    // MARK: - Empty Query Recent Section (`chatList.js:886-893`)

    private var recentConversationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !visibleRooms.isEmpty {
                Text("RECENT")
                    .font(CuvenFonts.cappedCaption())
                    .fontWeight(.semibold)
                    .tracking(0.6)
                    .foregroundStyle(CuvenColors.inkSecondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)

                ForEach(visibleRooms.prefix(10)) { room in
                    searchRoomRow(room)
                }
            }
        }
    }

    // MARK: - Active Query Sections

    @ViewBuilder
    private var populatedQueryResults: some View {
        let showChats = (selectedScope == .all || selectedScope == .chats) && !matchingRooms.isEmpty
        let showMessages = (selectedScope == .all || selectedScope == .messages) && !matchingMessages.isEmpty
        let showPeople = (selectedScope == .all || selectedScope == .people) && !matchingPeople.isEmpty

        if !showChats && !showMessages && !showPeople {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(ChatListPalette.tertiaryInk)
                Text("No results")
                    .font(CuvenFonts.cappedTitle())
                    .fontWeight(.semibold)
                    .foregroundStyle(CuvenColors.inkPrimary)
                Text("Nothing found for “\(trimmedQuery)”")
                    .font(CuvenFonts.cappedCaption())
                    .foregroundStyle(CuvenColors.inkSecondary)

                let handle = trimmedQuery.replacingOccurrences(of: "@", with: "")
                if !handle.isEmpty && !handle.contains(" ") {
                    Button {
                        Task {
                            await store.sendFriendRequest(usernameOrID: handle)
                            CuvenHaptics.success()
                            dismiss()
                        }
                    } label: {
                        Text("Send friend request to @\(handle)")
                            .font(CuvenFonts.cappedCaption())
                            .fontWeight(.semibold)
                            .foregroundStyle(CuvenColors.paperBackground)
                            .padding(.horizontal, 18)
                            .frame(minHeight: 44)
                            .background(Capsule().fill(CuvenColors.inkPrimary))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
        } else {
            if showChats {
                sectionEyebrow("CHATS")
                ForEach(matchingRooms) { room in
                    searchRoomRow(room)
                }
            }

            if showMessages {
                sectionEyebrow("MESSAGES")
                ForEach(matchingMessages) { hit in
                    searchMessageRow(hit)
                }
            }

            if showPeople {
                sectionEyebrow("CONTACTS & PEOPLE")
                ForEach(matchingPeople) { user in
                    searchPersonRow(user)
                }
            }
        }
    }

    private func sectionEyebrow(_ title: String) -> some View {
        Text(title)
            .font(CuvenFonts.cappedCaption())
            .fontWeight(.semibold)
            .tracking(0.6)
            .foregroundStyle(CuvenColors.inkSecondary)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 2)
    }

    private func searchRoomRow(_ room: Room) -> some View {
        Button {
            CuvenHaptics.selectionChanged()
            store.selectRoom(room.id)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                CuvenAvatarView(
                    name: room.title,
                    urlString: room.avatarURL,
                    size: 42,
                    isOnline: false
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        ChatListSearchHighlighter.highlighted(
                            room.title,
                            query: trimmedQuery,
                            baseColor: CuvenColors.inkPrimary
                        )
                    )
                    .font(CuvenFonts.cappedBody())
                    .fontWeight(.medium)
                    .lineLimit(1)

                    if !room.lastMessagePreview.isEmpty {
                        Text(
                            ChatListSearchHighlighter.highlighted(
                                room.lastMessagePreview,
                                query: trimmedQuery,
                                baseColor: CuvenColors.inkSecondary
                            )
                        )
                        .font(CuvenFonts.cappedCaption())
                        .lineLimit(1)
                    }
                }

                Spacer()

                Text(
                    ChatListTimeFormatter.listTime(
                        from: room.lastMessageTimestamp,
                        use24Hour: store.prefs.use24HourTime
                    )
                )
                .font(CuvenFonts.cappedCaption().monospacedDigit())
                .foregroundStyle(CuvenColors.inkSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 64)
            .background(
                RoundedRectangle(cornerRadius: ChatListRadii.row, style: .continuous)
                    .fill(CuvenColors.paperBackground)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chatlist.row.\(room.id)")
    }

    private func searchMessageRow(_ hit: MessageSearchHit) -> some View {
        Button {
            CuvenHaptics.selectionChanged()
            store.selectRoom(hit.room.id)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                CuvenAvatarView(
                    name: hit.room.title,
                    urlString: hit.room.avatarURL,
                    size: 40,
                    isOnline: false
                )

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(hit.room.title)
                            .font(CuvenFonts.cappedBody())
                            .fontWeight(.semibold)
                            .foregroundStyle(CuvenColors.inkPrimary)
                            .lineLimit(1)

                        Spacer()

                        Text(
                            ChatListTimeFormatter.listTime(
                                from: hit.message.createdAt,
                                use24Hour: store.prefs.use24HourTime
                            )
                        )
                        .font(CuvenFonts.cappedCaption().monospacedDigit())
                        .foregroundStyle(CuvenColors.inkSecondary)
                    }

                    Text(
                        ChatListSearchHighlighter.highlighted(
                            "\(hit.message.senderDisplay): \(hit.message.text)",
                            query: trimmedQuery,
                            baseColor: CuvenColors.inkSecondary
                        )
                    )
                    .font(CuvenFonts.cappedCaption())
                    .lineLimit(2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 66)
            .background(
                RoundedRectangle(cornerRadius: ChatListRadii.row, style: .continuous)
                    .fill(CuvenColors.paperBackground)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("globalSearch.message.\(hit.id)")
    }

    private func searchPersonRow(_ user: CuvenUser) -> some View {
        Button {
            Task {
                CuvenHaptics.selectionChanged()
                let roomID = await store.createDirectChat(with: user.id)
                store.selectRoom(roomID)
                dismiss()
            }
        } label: {
            HStack(spacing: 12) {
                CuvenAvatarView(
                    name: user.display,
                    urlString: user.avatarURL,
                    size: 42,
                    isOnline: user.isOnline
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        ChatListSearchHighlighter.highlighted(
                            user.display,
                            query: trimmedQuery,
                            baseColor: CuvenColors.inkPrimary
                        )
                    )
                    .font(CuvenFonts.cappedBody())
                    .fontWeight(.medium)
                    .lineLimit(1)

                    Text(
                        ChatListSearchHighlighter.highlighted(
                            "@\(user.username)",
                            query: trimmedQuery,
                            baseColor: CuvenColors.inkSecondary
                        )
                    )
                    .font(CuvenFonts.cappedCaption())
                    .lineLimit(1)
                }

                Spacer()

                Image(systemName: "bubble.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ChatListPalette.messagesTitleBlue)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 64)
            .background(
                RoundedRectangle(cornerRadius: ChatListRadii.row, style: .continuous)
                    .fill(CuvenColors.paperBackground)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("globalSearch.person.\(user.id)")
    }
}

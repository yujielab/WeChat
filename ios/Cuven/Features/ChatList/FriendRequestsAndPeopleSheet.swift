import SwiftUI
import CuvenCore

// MARK: - Unified Friends, Requests & People Sheet (`PROJECT.md § 5.4`)
//
// Grounding References:
// - Apple Human Interface Guidelines: Sheets, Lists & Accessibility (>= 44x44pt touch regions,
//   WCAG AA contrast, Reduce Motion collapse fallbacks)
// - Cuven Web Reference: `public/js/views/people.js:176-423`, `public/css/people.css:156-220`,
//   `Spec Miner 2` Features #17 & #18 (`Alani` request, `Sofie` suggested, `Mira / Yueee` discover)

public struct FriendRequestsAndPeopleSheet: View {
    private let store: AppStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var searchQuery = ""
    @State private var requestedUserIDs: Set<String> = []
    @State private var dismissedPendingInIDs: Set<String> = []
    @State private var composerSheetMode: NewChatComposerSheet.ComposerMode?
    @State private var isSendingDirectHandleRequest = false
    @State private var sentDirectHandleBanner: String?

    public init(store: AppStore) {
        self.store = store
    }

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedHandleQuery: String {
        trimmedQuery.hasPrefix("@") ? String(trimmedQuery.dropFirst()) : trimmedQuery
    }

    private var incomingRequests: [ContactItem] {
        store.contacts.filter { $0.status == .pendingIn && !dismissedPendingInIDs.contains($0.user.id) }
    }

    private var outgoingRequests: [ContactItem] {
        store.contacts.filter { $0.status == .pendingOut }
    }

    private var acceptedContacts: [ContactItem] {
        store.contacts
            .filter { $0.status == .accepted }
            .sorted { $0.user.display.localizedCaseInsensitiveCompare($1.user.display) == .orderedAscending }
    }

    private var discoverUsers: [CuvenUser] {
        let existingIDs = Set(
            store.contacts
                .filter { $0.status == .accepted || $0.status == .pendingIn || $0.status == .blocked }
                .map(\.user.id)
        )
        let myID = store.currentUser?.id
        var combined: [CuvenUser] = []
        var seen: Set<String> = []

        for contact in store.contacts where contact.status == .suggested {
            if contact.user.id != myID, !existingIDs.contains(contact.user.id), seen.insert(contact.user.id).inserted {
                combined.append(contact.user)
            }
        }
        for person in store.suggestedPeople {
            if person.id != myID, !existingIDs.contains(person.id), seen.insert(person.id).inserted {
                combined.append(person)
            }
        }
        return combined
    }

    private var filteredSearchUsers: [(user: CuvenUser, status: ContactStatus?)] {
        guard !normalizedHandleQuery.isEmpty else { return [] }
        let q = normalizedHandleQuery.lowercased()
        var results: [(CuvenUser, ContactStatus?)] = []
        var seen: Set<String> = []

        for item in store.contacts where item.status != .blocked {
            if item.user.display.lowercased().contains(q) || item.user.username.lowercased().contains(q) {
                if seen.insert(item.user.id).inserted {
                    results.append((item.user, item.status))
                }
            }
        }
        for user in store.suggestedPeople {
            if user.display.lowercased().contains(q) || user.username.lowercased().contains(q) {
                if seen.insert(user.id).inserted {
                    results.append((user, .suggested))
                }
            }
        }
        return results
    }

    private var shareInviteText: String {
        let username = store.currentUser?.username ?? "me"
        return "Chat with me on Cuven — I'm @\(username) \(store.serverBaseURL.absoluteString)"
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Search Pill (`people.js:200, 211`)
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(CuvenColors.inkSecondary)

                        TextField("Find people by @username", text: $searchQuery)
                            .font(CuvenFonts.cappedBody())
                            .foregroundStyle(CuvenColors.inkPrimary)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .accessibilityIdentifier("friends.searchField")

                        if !searchQuery.isEmpty {
                            Button {
                                searchQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(ChatListPalette.tertiaryInk)
                                    .frame(width: 36, height: 36)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear search")
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    .cuvenLiquidGlass(mode: store.prefs.glassMode, cornerRadius: 24, interactiveBounce: false)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    if let banner = sentDirectHandleBanner {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(CuvenColors.onlineGreen)
                            Text(banner)
                                .font(CuvenFonts.cappedCaption())
                                .foregroundStyle(CuvenColors.inkPrimary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: ChatListRadii.small, style: .continuous)
                                .fill(CuvenColors.elevatedSurface)
                        )
                        .padding(.horizontal, 16)
                    }

                    if !normalizedHandleQuery.isEmpty {
                        searchResultsContent
                    } else {
                        defaultFriendsContent
                    }
                }
                .padding(.bottom, 32)
            }
            .background(CuvenColors.paperBackground.ignoresSafeArea())
            .navigationTitle("Friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(CuvenFonts.cappedBody())
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("friends.doneButton")
                }
            }
            .sheet(item: $composerSheetMode) { mode in
                NewChatComposerSheet(store: store, initialMode: mode)
            }
        }
        .accessibilityIdentifier("friends.sheet")
    }

    // MARK: - Search Results View (`people.js:258-269`)

    private var searchResultsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !filteredSearchUsers.isEmpty {
                Text("MATCHING PEOPLE")
                    .font(CuvenFonts.cappedCaption())
                    .fontWeight(.semibold)
                    .foregroundStyle(CuvenColors.inkSecondary)
                    .padding(.horizontal, 20)

                VStack(spacing: 4) {
                    ForEach(filteredSearchUsers, id: \.user.id) { entry in
                        let isPending = entry.status == .pendingOut || requestedUserIDs.contains(entry.user.id)
                        PersonRowCardView(
                            user: entry.user,
                            subtitle: statusSubtitle(for: entry.user, status: entry.status),
                            queryHighlight: normalizedHandleQuery,
                            primaryButtonTitle: entry.status == .accepted ? "Chat" : (entry.status == .pendingIn ? "Accept" : (isPending ? "Requested" : "Add")),
                            isPrimarySolid: entry.status != .accepted && !isPending,
                            isPrimaryDisabled: isPending,
                            onRowTap: {
                                if entry.status == .accepted {
                                    Task { await startDirectChat(with: entry.user) }
                                }
                            },
                            onPrimaryTap: {
                                Task {
                                    if entry.status == .accepted {
                                        await startDirectChat(with: entry.user)
                                    } else if entry.status == .pendingIn {
                                        await acceptRequest(for: entry.user)
                                    } else {
                                        await addSuggestedPerson(entry.user)
                                    }
                                }
                            },
                            onDismissTap: nil
                        )
                    }
                }
                .padding(.horizontal, 10)
            }

            // Direct remote @username add fallback
            let exactMatchExists = filteredSearchUsers.contains {
                $0.user.username.caseInsensitiveCompare(normalizedHandleQuery) == .orderedSame
            }
            if !exactMatchExists {
                Button {
                    Task { await sendDirectUsernameRequest() }
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(ChatListPalette.messagesTitleBlue.opacity(0.14))
                                .frame(width: 44, height: 44)
                            Image(systemName: "person.badge.plus")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(ChatListPalette.messagesTitleBlue)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Add @\(normalizedHandleQuery)")
                                .font(CuvenFonts.cappedBody())
                                .fontWeight(.semibold)
                                .foregroundStyle(CuvenColors.inkPrimary)
                            Text("Send a friend request by username")
                                .font(CuvenFonts.cappedCaption())
                                .foregroundStyle(CuvenColors.inkSecondary)
                        }

                        Spacer()

                        if isSendingDirectHandleRequest {
                            ProgressView()
                        } else {
                            Text("Send")
                                .font(CuvenFonts.cappedCaption())
                                .fontWeight(.semibold)
                                .foregroundStyle(CuvenColors.paperBackground)
                                .padding(.horizontal, 14)
                                .frame(height: 34)
                                .background(Capsule().fill(CuvenColors.inkPrimary))
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: ChatListRadii.row, style: .continuous)
                            .fill(CuvenColors.elevatedSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: ChatListRadii.row, style: .continuous)
                            .strokeBorder(CuvenColors.hairlineSeparator, lineWidth: 0.8)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isSendingDirectHandleRequest)
                .padding(.horizontal, 16)
                .accessibilityIdentifier("friends.addByUsernameButton")
            }
        }
    }

    // MARK: - Default Friends Sheet Sections (`people.js:204-238`)

    private var defaultFriendsContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 1. Quick Actions Group: New Message + New Group + Invite Friends (`people.js:205-207`)
            VStack(spacing: 0) {
                Button {
                    CuvenHaptics.lightTap()
                    composerSheetMode = .directMessage
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(ChatListPalette.messagesTitleBlue)
                            .frame(width: 28)

                        Text("New message")
                            .font(CuvenFonts.cappedBody())
                            .fontWeight(.medium)
                            .foregroundStyle(CuvenColors.inkPrimary)

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ChatListPalette.tertiaryInk)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("friends.newMessageButton")

                Divider()
                    .padding(.leading, 56)

                Button {
                    CuvenHaptics.lightTap()
                    composerSheetMode = .group
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(ChatListPalette.messagesTitleBlue)
                            .frame(width: 28)

                        Text("New group")
                            .font(CuvenFonts.cappedBody())
                            .fontWeight(.medium)
                            .foregroundStyle(CuvenColors.inkPrimary)

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ChatListPalette.tertiaryInk)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("friends.newGroupButton")

                Divider()
                    .padding(.leading, 56)

                ShareLink(item: shareInviteText) {
                    HStack(spacing: 12) {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(ChatListPalette.messagesTitleBlue)
                            .frame(width: 28)

                        Text("Invite friends")
                            .font(CuvenFonts.cappedBody())
                            .fontWeight(.medium)
                            .foregroundStyle(CuvenColors.inkPrimary)

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ChatListPalette.tertiaryInk)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("friends.inviteFriendsButton")
            }
            .background(
                RoundedRectangle(cornerRadius: ChatListRadii.row, style: .continuous)
                    .fill(CuvenColors.elevatedSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ChatListRadii.row, style: .continuous)
                    .strokeBorder(CuvenColors.hairlineSeparator, lineWidth: 0.8)
            )
            .padding(.horizontal, 16)

            // 2. Incoming Requests ("Wants to add you", e.g. Alani `@alani`)
            if !incomingRequests.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("WANTS TO ADD YOU")
                        .font(CuvenFonts.cappedCaption())
                        .fontWeight(.semibold)
                        .foregroundStyle(CuvenColors.inkSecondary)
                        .padding(.horizontal, 20)

                    VStack(spacing: 4) {
                        ForEach(incomingRequests) { item in
                            PersonRowCardView(
                                user: item.user,
                                subtitle: item.mutualNote ?? "@\(item.user.username)",
                                primaryButtonTitle: "Accept",
                                isPrimarySolid: true,
                                isPrimaryDisabled: false,
                                onRowTap: nil,
                                onPrimaryTap: {
                                    Task { await acceptRequest(for: item.user) }
                                },
                                onDismissTap: {
                                    CuvenHaptics.lightTap()
                                    if reduceMotion {
                                        dismissedPendingInIDs.insert(item.user.id)
                                    } else {
                                        withAnimation(CuvenSprings.railMorph) {
                                            _ = dismissedPendingInIDs.insert(item.user.id)
                                        }
                                    }
                                }
                            )
                            .accessibilityIdentifier("friends.request.incoming.\(item.user.id)")
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }

            // 3. Outgoing Requests ("Sent")
            if !outgoingRequests.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SENT")
                        .font(CuvenFonts.cappedCaption())
                        .fontWeight(.semibold)
                        .foregroundStyle(CuvenColors.inkSecondary)
                        .padding(.horizontal, 20)

                    VStack(spacing: 4) {
                        ForEach(outgoingRequests) { item in
                            PersonRowCardView(
                                user: item.user,
                                subtitle: "Request sent · @\(item.user.username)",
                                primaryButtonTitle: "Requested",
                                isPrimarySolid: false,
                                isPrimaryDisabled: true,
                                onRowTap: nil,
                                onPrimaryTap: {},
                                onDismissTap: nil
                            )
                            .accessibilityIdentifier("friends.request.outgoing.\(item.user.id)")
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }

            if incomingRequests.isEmpty && outgoingRequests.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(ChatListPalette.tertiaryInk)
                    Text("No pending requests")
                        .font(CuvenFonts.cappedBody())
                        .fontWeight(.semibold)
                        .foregroundStyle(CuvenColors.inkPrimary)
                    Text("Friend requests appear here.")
                        .font(CuvenFonts.cappedCaption())
                        .foregroundStyle(CuvenColors.inkSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }

            // 4. People You May Know (`Mira`, `Yueee`)
            if !discoverUsers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PEOPLE YOU MAY KNOW")
                        .font(CuvenFonts.cappedCaption())
                        .fontWeight(.semibold)
                        .foregroundStyle(CuvenColors.inkSecondary)
                        .padding(.horizontal, 20)

                    VStack(spacing: 4) {
                        ForEach(discoverUsers) { person in
                            let isRequested = requestedUserIDs.contains(person.id)
                            let mutual = store.contacts.first(where: { $0.user.id == person.id })?.mutualNote
                            PersonRowCardView(
                                user: person,
                                subtitle: mutual ?? (person.bio.isEmpty ? "@\(person.username)" : person.bio),
                                primaryButtonTitle: isRequested ? "Requested" : "Add",
                                isPrimarySolid: !isRequested,
                                isPrimaryDisabled: isRequested,
                                onRowTap: nil,
                                onPrimaryTap: {
                                    Task { await addSuggestedPerson(person) }
                                },
                                onDismissTap: {
                                    dismissSuggested(person)
                                }
                            )
                            .accessibilityIdentifier("friends.discover.\(person.id)")
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }

            // 5. Accepted Contacts (`Sofie`, `Coisini`, `Hong`, `Gang`)
            VStack(alignment: .leading, spacing: 6) {
                Text("CONTACTS")
                    .font(CuvenFonts.cappedCaption())
                    .fontWeight(.semibold)
                    .foregroundStyle(CuvenColors.inkSecondary)
                    .padding(.horizontal, 20)

                if acceptedContacts.isEmpty {
                    Text("No contacts yet. Search a @username above.")
                        .font(CuvenFonts.cappedCaption())
                        .foregroundStyle(CuvenColors.inkSecondary)
                        .padding(.horizontal, 20)
                } else {
                    VStack(spacing: 4) {
                        ForEach(acceptedContacts) { contact in
                            PersonRowCardView(
                                user: contact.user,
                                subtitle: "@\(contact.user.username)",
                                primaryButtonTitle: "Chat",
                                isPrimarySolid: false,
                                isPrimaryDisabled: false,
                                onRowTap: {
                                    Task { await startDirectChat(with: contact.user) }
                                },
                                onPrimaryTap: {
                                    Task { await startDirectChat(with: contact.user) }
                                },
                                onDismissTap: nil
                            )
                            .accessibilityIdentifier("friends.contact.\(contact.user.id)")
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
        }
    }

    // MARK: - Actions

    private func statusSubtitle(for user: CuvenUser, status: ContactStatus?) -> String {
        switch status {
        case .pendingOut: return "Request sent · @\(user.username)"
        case .pendingIn: return "Wants to add you · @\(user.username)"
        default: return "@\(user.username)"
        }
    }

    private func acceptRequest(for user: CuvenUser) async {
        CuvenHaptics.success()
        await store.acceptFriendRequest(userID: user.id)
    }

    private func addSuggestedPerson(_ user: CuvenUser) async {
        CuvenHaptics.lightTap()
        requestedUserIDs.insert(user.id)
        await store.sendFriendRequest(usernameOrID: user.username.isEmpty ? user.id : user.username)
    }

    private func dismissSuggested(_ user: CuvenUser) {
        CuvenHaptics.lightTap()
        if reduceMotion {
            store.dismissSuggestedPerson(userID: user.id)
        } else {
            withAnimation(CuvenSprings.railMorph) {
                store.dismissSuggestedPerson(userID: user.id)
            }
        }
    }

    private func startDirectChat(with user: CuvenUser) async {
        CuvenHaptics.selectionChanged()
        let roomID = await store.createDirectChat(with: user.id)
        store.selectRoom(roomID)
        dismiss()
    }

    private func sendDirectUsernameRequest() async {
        guard !normalizedHandleQuery.isEmpty, !isSendingDirectHandleRequest else { return }
        isSendingDirectHandleRequest = true
        await store.sendFriendRequest(usernameOrID: normalizedHandleQuery)
        CuvenHaptics.success()
        sentDirectHandleBanner = "Friend request sent to @\(normalizedHandleQuery)"
        isSendingDirectHandleRequest = false
    }
}

// MARK: - Inline Inbox Suggested & People You May Know Section (`people.js:283-381`)

struct InboxPeopleDiscoverySectionView: View {
    let store: AppStore
    let metrics: DuoLayoutMetrics
    let showRequestsInline: Bool
    let onOpenFriendsSheet: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var requestedUserIDs: Set<String> = []
    @State private var isInviteCardDismissed = false
    @State private var isShowingSeeAllSheet = false

    private var horizontalInset: CGFloat {
        metrics.visibleColumnCount == 2 ? 18 : 20
    }

    private var trailingSafePadding: CGFloat {
        ChatListSpatialMetrics.trailingSystemColumnInset(for: metrics)
    }

    private var incomingRequests: [ContactItem] {
        store.contacts.filter { $0.status == .pendingIn }
    }

    /// Accepted contacts who don't yet have an open 1:1 DM room (`Sofie` -> `"Tap to chat"`, `people.js:279-280`).
    private var suggestedChatContacts: [CuvenUser] {
        let activeDMPeerIDs = Set(
            store.rooms
                .filter { !$0.isHidden && $0.kind == .dm }
                .compactMap(\.peerUserID)
        )
        return store.contacts
            .filter { $0.status == .accepted && !activeDMPeerIDs.contains($0.user.id) }
            .map(\.user)
    }

    /// Non-friend discoverable people (`Mira`, `Yueee`, `people.js:280-281`).
    private var discoverPeople: [CuvenUser] {
        let excludedIDs = Set(
            store.contacts
                .filter { $0.status == .accepted || $0.status == .pendingIn || $0.status == .blocked }
                .map(\.user.id)
        )
        let myID = store.currentUser?.id
        var list: [CuvenUser] = []
        var seen: Set<String> = []

        for item in store.contacts where item.status == .suggested {
            if item.user.id != myID, !excludedIDs.contains(item.user.id), seen.insert(item.user.id).inserted {
                list.append(item.user)
            }
        }
        for user in store.suggestedPeople {
            if user.id != myID, !excludedIDs.contains(user.id), seen.insert(user.id).inserted {
                list.append(user)
            }
        }
        return list
    }

    private var shareInviteText: String {
        let username = store.currentUser?.username ?? "me"
        return "Chat with me on Cuven — I'm @\(username) \(store.serverBaseURL.absoluteString)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Optional inline Incoming Requests when `Requests` filter tab is selected
            if showRequestsInline {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Friend requests")
                            .font(CuvenFonts.cappedBody())
                            .fontWeight(.bold)
                            .foregroundStyle(CuvenColors.inkPrimary)

                        Spacer()

                        Button(action: onOpenFriendsSheet) {
                            Text("Find people")
                                .font(CuvenFonts.cappedCaption())
                                .fontWeight(.semibold)
                                .foregroundStyle(ChatListPalette.accessibleBlueText)
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.leading, horizontalInset + metrics.safeAreaLeft)
                    .padding(.trailing, horizontalInset + trailingSafePadding)

                    if incomingRequests.isEmpty {
                        HStack(spacing: 10) {
                            Image(systemName: "person.badge.plus")
                                .font(.system(size: 18))
                                .foregroundStyle(ChatListPalette.tertiaryInk)
                            Text("No incoming friend requests right now.")
                                .font(CuvenFonts.cappedCaption())
                                .foregroundStyle(CuvenColors.inkSecondary)
                        }
                        .padding(.horizontal, horizontalInset + metrics.safeAreaLeft)
                        .padding(.vertical, 8)
                    } else {
                        VStack(spacing: 4) {
                            ForEach(incomingRequests) { request in
                                PersonRowCardView(
                                    user: request.user,
                                    subtitle: request.mutualNote ?? "@\(request.user.username)",
                                    primaryButtonTitle: "Accept",
                                    isPrimarySolid: true,
                                    isPrimaryDisabled: false,
                                    onRowTap: nil,
                                    onPrimaryTap: {
                                        Task {
                                            CuvenHaptics.success()
                                            await store.acceptFriendRequest(userID: request.user.id)
                                        }
                                    },
                                    onDismissTap: nil
                                )
                                .accessibilityIdentifier("chatlist.inlineRequest.\(request.user.id)")
                            }
                        }
                        .padding(.leading, max(8, horizontalInset - 8) + metrics.safeAreaLeft)
                        .padding(.trailing, max(8, horizontalInset - 8) + trailingSafePadding)
                    }
                }
            }

            // 1. Suggested (`Sofie` -> "Tap to chat", `people.js:315-319`)
            if !suggestedChatContacts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Suggested")
                        .font(CuvenFonts.cappedBody())
                        .fontWeight(.bold)
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .padding(.leading, horizontalInset + metrics.safeAreaLeft)
                        .padding(.trailing, horizontalInset + trailingSafePadding)

                    VStack(spacing: 4) {
                        ForEach(suggestedChatContacts) { user in
                            PersonRowCardView(
                                user: user,
                                subtitle: "Tap to chat",
                                primaryButtonTitle: nil,
                                isPrimarySolid: false,
                                isPrimaryDisabled: false,
                                onRowTap: {
                                    Task {
                                        CuvenHaptics.selectionChanged()
                                        let roomID = await store.createDirectChat(with: user.id)
                                        store.selectRoom(roomID)
                                    }
                                },
                                onPrimaryTap: {},
                                onDismissTap: nil
                            )
                            .accessibilityIdentifier("chatlist.suggested.\(user.id)")
                        }
                    }
                    .padding(.leading, max(8, horizontalInset - 8) + metrics.safeAreaLeft)
                    .padding(.trailing, max(8, horizontalInset - 8) + trailingSafePadding)
                }
            }

            // 2. People you may know (`Invite friends` card + `Mira / Yueee`, `people.js:320-325`)
            if !discoverPeople.isEmpty || !isInviteCardDismissed {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("People you may know")
                            .font(CuvenFonts.cappedBody())
                            .fontWeight(.bold)
                            .foregroundStyle(CuvenColors.inkPrimary)

                        Spacer()

                        if discoverPeople.count > 5 {
                            Button {
                                isShowingSeeAllSheet = true
                            } label: {
                                Text("See all")
                                    .font(CuvenFonts.cappedCaption())
                                    .fontWeight(.semibold)
                                    .foregroundStyle(ChatListPalette.accessibleBlueText)
                                    .padding(.horizontal, 8)
                                    .frame(minHeight: 44)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.leading, horizontalInset + metrics.safeAreaLeft)
                    .padding(.trailing, horizontalInset + trailingSafePadding)

                    VStack(spacing: 4) {
                        // Dismissible "Invite friends" share card (`people.css:202-210`)
                        if !isInviteCardDismissed {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(ChatListPalette.subtleChipFill)
                                        .frame(width: 52, height: 52)
                                    Image(systemName: "person.badge.plus")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundStyle(CuvenColors.inkPrimary)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Invite friends")
                                        .font(CuvenFonts.cappedBody())
                                        .fontWeight(.semibold)
                                        .foregroundStyle(CuvenColors.inkPrimary)
                                    Text("Send friends a link to Cuven.")
                                        .font(CuvenFonts.cappedCaption())
                                        .foregroundStyle(CuvenColors.inkSecondary)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                ShareLink(item: shareInviteText) {
                                    Text("Share")
                                        .font(CuvenFonts.cappedCaption())
                                        .fontWeight(.semibold)
                                        .foregroundStyle(ChatListPalette.accessibleBlueText)
                                        .padding(.horizontal, 14)
                                        .frame(minWidth: 74, minHeight: 36)
                                        .background(Capsule().fill(CuvenColors.paperBackground))
                                        .overlay(
                                            Capsule()
                                                .strokeBorder(CuvenColors.inkPrimary, lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)

                                Button {
                                    CuvenHaptics.lightTap()
                                    if reduceMotion {
                                        isInviteCardDismissed = true
                                    } else {
                                        withAnimation(CuvenSprings.railMorph) {
                                            isInviteCardDismissed = true
                                        }
                                    }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(CuvenColors.inkSecondary)
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Hide invite card")
                            }
                            .padding(.leading, 12)
                            .padding(.trailing, 4)
                            .padding(.vertical, 6)
                        }

                        ForEach(discoverPeople.prefix(5)) { person in
                            let isRequested = requestedUserIDs.contains(person.id)
                            let mutual = store.contacts.first(where: { $0.user.id == person.id })?.mutualNote
                            PersonRowCardView(
                                user: person,
                                subtitle: mutual ?? (person.bio.isEmpty ? "Suggested for you" : person.bio),
                                primaryButtonTitle: isRequested ? "Requested" : "Add",
                                isPrimarySolid: !isRequested,
                                isPrimaryDisabled: isRequested,
                                onRowTap: nil,
                                onPrimaryTap: {
                                    Task {
                                        CuvenHaptics.lightTap()
                                        requestedUserIDs.insert(person.id)
                                        await store.sendFriendRequest(
                                            usernameOrID: person.username.isEmpty ? person.id : person.username
                                        )
                                    }
                                },
                                onDismissTap: {
                                    CuvenHaptics.lightTap()
                                    if reduceMotion {
                                        store.dismissSuggestedPerson(userID: person.id)
                                    } else {
                                        withAnimation(CuvenSprings.railMorph) {
                                            store.dismissSuggestedPerson(userID: person.id)
                                        }
                                    }
                                }
                            )
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                            .accessibilityIdentifier("chatlist.discover.\(person.id)")
                        }
                    }
                    .padding(.leading, max(8, horizontalInset - 8) + metrics.safeAreaLeft)
                    .padding(.trailing, max(8, horizontalInset - 8) + trailingSafePadding)
                }
            }
        }
        .padding(.top, 10)
        .sheet(isPresented: $isShowingSeeAllSheet) {
            FriendRequestsAndPeopleSheet(store: store)
        }
    }
}

// MARK: - Shared Person Row Card (`people.css:170-198`)

struct PersonRowCardView: View {
    let user: CuvenUser
    let subtitle: String
    var queryHighlight: String = ""
    let primaryButtonTitle: String?
    let isPrimarySolid: Bool
    let isPrimaryDisabled: Bool
    let onRowTap: (() -> Void)?
    let onPrimaryTap: () -> Void
    let onDismissTap: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let onRowTap {
                    Button(action: onRowTap) {
                        leadingPersonSummary
                    }
                    .buttonStyle(.plain)
                } else {
                    leadingPersonSummary
                }
            }

            if let primaryButtonTitle {
                Button(action: onPrimaryTap) {
                    Text(primaryButtonTitle)
                        .font(CuvenFonts.cappedCaption())
                        .fontWeight(.semibold)
                        .foregroundStyle(
                            isPrimaryDisabled
                                ? CuvenColors.inkSecondary
                                : (isPrimarySolid ? CuvenColors.paperBackground : CuvenColors.inkPrimary)
                        )
                        .padding(.horizontal, 16)
                        .frame(minWidth: 84, minHeight: 36)
                        .background(
                            Capsule()
                                .fill(
                                    isPrimaryDisabled
                                        ? ChatListPalette.subtleChipFill
                                        : (isPrimarySolid ? CuvenColors.inkPrimary : ChatListPalette.subtleChipFill)
                                )
                        )
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isPrimaryDisabled)
                .accessibilityIdentifier("personRow.action.\(user.id)")
            }

            if let onDismissTap {
                Button(action: onDismissTap) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CuvenColors.inkSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss \(user.display)")
                .accessibilityIdentifier("personRow.dismiss.\(user.id)")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, onDismissTap == nil ? 12 : 4)
        .frame(minHeight: 70)
        .background(
            RoundedRectangle(cornerRadius: ChatListRadii.row, style: .continuous)
                .fill(CuvenColors.paperBackground)
        )
    }

    private var leadingPersonSummary: some View {
        HStack(spacing: 13) {
            CuvenAvatarView(
                name: user.display,
                urlString: user.avatarURL,
                size: 52,
                isOnline: user.isOnline
            )

            VStack(alignment: .leading, spacing: 2) {
                if queryHighlight.isEmpty {
                    Text(user.display)
                        .font(CuvenFonts.cappedBody())
                        .fontWeight(.semibold)
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .lineLimit(1)
                } else {
                    Text(
                        ChatListSearchHighlighter.highlighted(
                            user.display,
                            query: queryHighlight,
                            baseColor: CuvenColors.inkPrimary
                        )
                    )
                    .font(CuvenFonts.cappedBody())
                    .fontWeight(.semibold)
                    .lineLimit(1)
                }

                Text(subtitle)
                    .font(CuvenFonts.cappedCaption())
                    .foregroundStyle(CuvenColors.inkSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

import SwiftUI
import CuvenCore

// MARK: - New DM & Multi-Select Group Creator Sheet (`DISPATCH.md` Item 4)
//
// Grounding References:
// - Apple Human Interface Guidelines: Sheets & Selection Controls (multi-select checkmarks,
//   removable recipient tokens, >= 44pt hit targets)
// - Cuven Web Reference: `public/js/views/sheets.js:336-372` (`openNewGroup`), `people.js:199-275`

public struct NewChatComposerSheet: View {
    enum ComposerMode: String, CaseIterable, Identifiable {
        case directMessage
        case group

        var id: String { rawValue }

        var title: String {
            switch self {
            case .directMessage: return "Direct Message"
            case .group: return "New Group"
            }
        }
    }

    private let store: AppStore

    @Namespace private var modeSwitchNamespace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var mode: ComposerMode
    @State private var searchQuery = ""
    @State private var groupName = ""
    @State private var selectedMemberIDs: [String] = []
    @State private var isCreating = false

    public init(store: AppStore) {
        self.store = store
        self._mode = State(initialValue: .directMessage)
    }

    init(store: AppStore, initialMode: ComposerMode) {
        self.store = store
        self._mode = State(initialValue: initialMode)
    }

    private var candidateUsers: [CuvenUser] {
        let myID = store.currentUser?.id
        var list: [CuvenUser] = []
        var seen: Set<String> = []

        for contact in store.contacts where contact.status == .accepted {
            if contact.user.id != myID, seen.insert(contact.user.id).inserted {
                list.append(contact.user)
            }
        }
        for person in store.suggestedPeople {
            if person.id != myID, seen.insert(person.id).inserted {
                list.append(person)
            }
        }
        return list.sorted { $0.display.localizedCaseInsensitiveCompare($1.display) == .orderedAscending }
    }

    private var filteredCandidates: [CuvenUser] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return candidateUsers }
        let q = (trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed).lowercased()
        return candidateUsers.filter {
            $0.display.lowercased().contains(q) || $0.username.lowercased().contains(q)
        }
    }

    private var selectedMembers: [CuvenUser] {
        let byID = Dictionary(uniqueKeysWithValues: candidateUsers.map { ($0.id, $0) })
        return selectedMemberIDs.compactMap { byID[$0] }
    }

    private var resolvedGroupName: String {
        let explicit = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return explicit }
        let names = selectedMembers.prefix(3).map(\.display)
        return names.isEmpty ? "New Group" : names.joined(separator: ", ")
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Segmented Mode Bar (`Direct Message` | `New Group`)
                HStack(spacing: 4) {
                    ForEach(ComposerMode.allCases) { option in
                        let isSelected = mode == option
                        Button {
                            CuvenHaptics.selectionChanged()
                            if reduceMotion {
                                mode = option
                            } else {
                                withAnimation(CuvenSprings.railMorph) {
                                    mode = option
                                }
                            }
                        } label: {
                            Text(option.title)
                                .font(CuvenFonts.cappedCaption())
                                .fontWeight(.semibold)
                                .foregroundStyle(isSelected ? CuvenColors.paperBackground : CuvenColors.inkPrimary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 38)
                                .background {
                                    if isSelected {
                                        Capsule()
                                            .fill(CuvenColors.inkPrimary)
                                            .matchedGeometryEffect(
                                                id: "newChatComposer.modePill",
                                                in: modeSwitchNamespace
                                            )
                                    }
                                }
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("newChat.mode.\(option.rawValue)")
                    }
                }
                .padding(.horizontal, 4)
                .background(Capsule().fill(ChatListPalette.subtleChipFill))
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 12)

                if mode == .group {
                    groupConfigurationHeader
                }

                // Filter / @username Search Input
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(CuvenColors.inkSecondary)

                    TextField("Search people or @username", text: $searchQuery)
                        .font(CuvenFonts.cappedBody())
                        .foregroundStyle(CuvenColors.inkPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("newChat.searchField")

                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(ChatListPalette.tertiaryInk)
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(ChatListPalette.subtleChipFill)
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

                // Candidate List
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if filteredCandidates.isEmpty {
                            emptySearchFallback
                        } else {
                            ForEach(filteredCandidates) { user in
                                candidateRow(for: user)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                }

                // Bottom Group Creation CTA (`sheets.js:341, 362-371`)
                if mode == .group {
                    VStack(spacing: 0) {
                        Divider()
                        Button {
                            Task { await createGroupConversation() }
                        } label: {
                            HStack(spacing: 8) {
                                if isCreating {
                                    ProgressView()
                                        .tint(CuvenColors.paperBackground)
                                }
                                Text(
                                    selectedMemberIDs.isEmpty
                                        ? "Choose members"
                                        : "Create group (\(selectedMemberIDs.count))"
                                )
                                .font(CuvenFonts.cappedBody())
                                .fontWeight(.semibold)
                            }
                            .foregroundStyle(CuvenColors.paperBackground)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Capsule().fill(CuvenColors.inkPrimary))
                            .opacity(selectedMemberIDs.isEmpty || isCreating ? 0.35 : 1.0)
                        }
                        .disabled(selectedMemberIDs.isEmpty || isCreating)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .accessibilityIdentifier("newChat.createGroupButton")
                    }
                    .background(CuvenColors.paperBackground)
                }
            }
            .background(CuvenColors.paperBackground.ignoresSafeArea())
            .navigationTitle(mode == .group ? "New group" : "New message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .font(CuvenFonts.cappedBody())
                    .accessibilityIdentifier("newChat.cancelButton")
                }
            }
        }
        .accessibilityIdentifier("newChat.sheet")
    }

    // MARK: - Subviews

    private var groupConfigurationHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Group name (optional)", text: $groupName)
                .font(CuvenFonts.cappedBody())
                .foregroundStyle(CuvenColors.inkPrimary)
                .onChange(of: groupName) { _, value in
                    if value.count > 40 {
                        groupName = String(value.prefix(40))
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(CuvenColors.elevatedSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(CuvenColors.hairlineSeparator, lineWidth: 0.8)
                )
                .padding(.horizontal, 16)
                .accessibilityIdentifier("newChat.groupNameField")

            if !selectedMembers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(selectedMembers) { member in
                            Button {
                                toggleMemberSelection(member.id)
                            } label: {
                                HStack(spacing: 6) {
                                    CuvenAvatarView(
                                        name: member.display,
                                        urlString: member.avatarURL,
                                        size: 24,
                                        isOnline: false
                                    )
                                    Text(member.display)
                                        .font(CuvenFonts.cappedCaption())
                                        .fontWeight(.medium)
                                        .foregroundStyle(CuvenColors.inkPrimary)
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 13))
                                        .foregroundStyle(ChatListPalette.tertiaryInk)
                                }
                                .padding(.leading, 5)
                                .padding(.trailing, 9)
                                .frame(height: 34)
                                .background(Capsule().fill(ChatListPalette.subtleChipFill))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .padding(.bottom, 10)
    }

    private func candidateRow(for user: CuvenUser) -> some View {
        let isPicked = selectedMemberIDs.contains(user.id)
        return Button {
            if mode == .group {
                toggleMemberSelection(user.id)
            } else {
                Task { await startDirectConversation(with: user.id) }
            }
        } label: {
            HStack(spacing: 12) {
                CuvenAvatarView(
                    name: user.display,
                    urlString: user.avatarURL,
                    size: 44,
                    isOnline: user.isOnline
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        ChatListSearchHighlighter.highlighted(
                            user.display,
                            query: searchQuery,
                            baseColor: CuvenColors.inkPrimary
                        )
                    )
                    .font(CuvenFonts.cappedBody())
                    .fontWeight(.medium)
                    .lineLimit(1)

                    Text("@\(user.username)")
                        .font(CuvenFonts.cappedCaption())
                        .foregroundStyle(CuvenColors.inkSecondary)
                        .lineLimit(1)
                }

                Spacer()

                if mode == .group {
                    ZStack {
                        Circle()
                            .strokeBorder(
                                isPicked ? ChatListPalette.messagesTitleBlue : CuvenColors.hairlineSeparator,
                                lineWidth: 1.8
                            )
                            .background(
                                Circle()
                                    .fill(isPicked ? ChatListPalette.messagesTitleBlue : Color.clear)
                            )
                            .frame(width: 24, height: 24)

                        if isPicked {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.white)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ChatListPalette.tertiaryInk)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minHeight: 62)
            .background(
                RoundedRectangle(cornerRadius: ChatListRadii.row, style: .continuous)
                    .fill(isPicked ? ChatListPalette.splitSelectionFill : CuvenColors.paperBackground)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isCreating)
        .accessibilityIdentifier("newChat.candidate.\(user.id)")
    }

    private var emptySearchFallback: some View {
        let handle = searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
        return VStack(spacing: 12) {
            Text(handle.isEmpty ? "No contacts yet" : "No local match for “\(handle)”")
                .font(CuvenFonts.cappedBody())
                .fontWeight(.semibold)
                .foregroundStyle(CuvenColors.inkPrimary)
                .padding(.top, 28)

            if !handle.isEmpty && mode == .directMessage {
                Button {
                    Task {
                        isCreating = true
                        await store.sendFriendRequest(usernameOrID: handle)
                        let roomID = await store.createDirectChat(with: handle)
                        CuvenHaptics.success()
                        isCreating = false
                        store.selectRoom(roomID)
                        dismiss()
                    }
                } label: {
                    Text("Message @\(handle)")
                        .font(CuvenFonts.cappedBody())
                        .fontWeight(.semibold)
                        .foregroundStyle(CuvenColors.paperBackground)
                        .padding(.horizontal, 20)
                        .frame(minHeight: 44)
                        .background(Capsule().fill(CuvenColors.inkPrimary))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func toggleMemberSelection(_ userID: String) {
        CuvenHaptics.selectionChanged()
        if reduceMotion {
            if let idx = selectedMemberIDs.firstIndex(of: userID) {
                selectedMemberIDs.remove(at: idx)
            } else {
                selectedMemberIDs.append(userID)
            }
        } else {
            withAnimation(CuvenSprings.pressBounce) {
                if let idx = selectedMemberIDs.firstIndex(of: userID) {
                    selectedMemberIDs.remove(at: idx)
                } else {
                    selectedMemberIDs.append(userID)
                }
            }
        }
    }

    private func startDirectConversation(with userID: String) async {
        guard !isCreating else { return }
        isCreating = true
        CuvenHaptics.selectionChanged()
        let roomID = await store.createDirectChat(with: userID)
        isCreating = false
        store.selectRoom(roomID)
        dismiss()
    }

    private func createGroupConversation() async {
        guard !selectedMemberIDs.isEmpty, !isCreating else { return }
        isCreating = true
        CuvenHaptics.success()
        let roomID = await store.createGroupChat(name: resolvedGroupName, memberIDs: selectedMemberIDs)
        isCreating = false
        store.selectRoom(roomID)
        dismiss()
    }
}

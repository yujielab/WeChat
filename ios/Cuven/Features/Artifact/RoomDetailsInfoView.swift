import SwiftUI
import CuvenCore

// MARK: - Conversation Details & Room Info View (M10 — `PROJECT.md § 4, § 5.4, § 5.5`)
//
// Apple HIG & Cuven Web Grounding:
// - Cuven Web Parity (`public/js/views/sheets.js:374-473`, `public/js/views/artifact.js:38-83`):
//   * Contact / Group Profile Hero Card with cover backdrop, `84pt` `CuvenAvatarView`, online dot, `@username` / member count, and bio.
//   * Smart Conversation Insights card (`insightsSection(roomId)` — peer local time, weather, summary, action chip).
//   * Peer `Moments` entry cell opening `UserMomentsProfileView`.
//   * Shared Photos, Videos & Sketches preview strip opening `FullscreenMediaLightboxView`.
//   * `Mute` & `Pin chat` switches (`store.toggleRoomMute`, `store.toggleRoomPin`) + 8-preset Conversation Backdrop selector.
//   * Group `Members` grid + `+ Add` contact picker sheet (`addMembers`).
//   * Destructive `Leave group` / `Delete chat` guard (`store.deleteOrHideRoom`).
// - Apple HIG › Designing for iPhone Duo: Respects asymmetric right safe-area column (`safeRight >= 64pt`)
//   so all rows, toggles, and the bottom `Back` / `Close` action bar remain clear of `DuoRail`.

public struct RoomDetailsInfoView: View {
    private let store: AppStore
    private let roomID: String
    private let metrics: DuoLayoutMetrics
    private let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showPeerMomentsSheet: Bool = false
    @State private var showAddMemberSheet: Bool = false
    @State private var showDeleteOrLeaveAlert: Bool = false
    @State private var activeLightboxIndex: Int?

    public init(
        store: AppStore,
        roomID: String,
        metrics: DuoLayoutMetrics,
        onClose: @escaping () -> Void
    ) {
        self.store = store
        self.roomID = roomID
        self.metrics = metrics
        self.onClose = onClose
    }

    // MARK: - Live Store Resolution

    private var liveRoom: Room {
        store.rooms.first(where: { $0.id == roomID })
            ?? Room(id: roomID, kind: .dm, title: "Conversation", subtitle: "")
    }

    private var isGroup: Bool {
        liveRoom.kind == .group
    }

    private var peerUser: CuvenUser? {
        guard !isGroup else { return nil }
        let targetID = liveRoom.peerUserID
            ?? liveRoom.memberIDs.first(where: { $0 != store.currentUser?.id })
        if let targetID {
            if let contact = store.contacts.first(where: { $0.user.id == targetID }) {
                return contact.user
            }
            if let suggested = store.suggestedPeople.first(where: { $0.id == targetID }) {
                return suggested
            }
            if let author = store.moments.first(where: { $0.author.id == targetID })?.author {
                return author
            }
        }
        let handle = liveRoom.subtitle.hasPrefix("@")
            ? String(liveRoom.subtitle.dropFirst())
            : liveRoom.title.lowercased().replacingOccurrences(of: " ", with: "_")
        return CuvenUser(
            id: targetID ?? "peer_\(roomID)",
            username: handle,
            display: liveRoom.title,
            avatarURL: liveRoom.avatarURL,
            isOnline: false
        )
    }

    private var resolvedMembers: [CuvenUser] {
        var result: [CuvenUser] = []
        var seen: Set<String> = []
        for uid in liveRoom.memberIDs where seen.insert(uid).inserted {
            if let me = store.currentUser, me.id == uid {
                result.append(me)
            } else if let contact = store.contacts.first(where: { $0.user.id == uid }) {
                result.append(contact.user)
            } else if let suggested = store.suggestedPeople.first(where: { $0.id == uid }) {
                result.append(suggested)
            } else if let author = store.moments.first(where: { $0.author.id == uid })?.author {
                result.append(author)
            } else {
                result.append(CuvenUser(id: uid, username: uid, display: uid.replacingOccurrences(of: "u_", with: "").capitalized))
            }
        }
        return result
    }

    private var sharedMediaItems: [(id: String, url: String, isDrawing: Bool, isVideo: Bool)] {
        let msgs = store.messagesByRoom[roomID] ?? []
        var collected: [(id: String, url: String, isDrawing: Bool, isVideo: Bool)] = []
        for msg in msgs.reversed() where msg.deliveryState != .revoked {
            switch msg.kind {
            case .image, .drawing, .video:
                for (offset, url) in msg.mediaURLs.enumerated() where !url.isEmpty {
                    collected.append((
                        id: "\(msg.id)_\(offset)",
                        url: url,
                        isDrawing: msg.kind == .drawing,
                        isVideo: msg.kind == .video
                    ))
                }
            default:
                break
            }
        }
        return collected
    }

    private var sharedLinks: [(id: String, url: URL, sender: String)] {
        let msgs = store.messagesByRoom[roomID] ?? []
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        var found: [(id: String, url: URL, sender: String)] = []
        var seen = Set<String>()
        for msg in msgs.reversed() where msg.deliveryState != .revoked && !msg.text.isEmpty {
            let range = NSRange(msg.text.startIndex..<msg.text.endIndex, in: msg.text)
            for match in detector.matches(in: msg.text, options: [], range: range) {
                if let url = match.url,
                   let scheme = url.scheme?.lowercased(),
                   (scheme == "http" || scheme == "https"),
                   seen.insert(url.absoluteString).inserted {
                    found.append((id: "\(msg.id)_\(url.absoluteString)", url: url, sender: msg.senderDisplay))
                }
            }
        }
        return found
    }

    private var peerMomentsCount: Int {
        guard let peer = peerUser else { return 0 }
        return store.moments.filter { $0.author.id == peer.id }.count
    }

    private var trailingRailClearance: CGFloat {
        if metrics.hasRightSystemColumn {
            return max(metrics.safeAreaRight, metrics.railWidth + 24)
        }
        return max(16, metrics.safeAreaRight + 16)
    }

    private var leadingInset: CGFloat {
        max(16, metrics.safeAreaLeft + 16)
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    profileHeroCard

                    if !isGroup,
                       store.prefs.smartAssistEnabled,
                       let insight = store.insights[roomID] {
                        roomInsightCard(insight)
                    }

                    if !isGroup, peerUser != nil {
                        peerMomentsSection
                    }

                    if !sharedMediaItems.isEmpty {
                        sharedMediaSection
                    }

                    if !sharedLinks.isEmpty {
                        sharedLinksSection
                    }

                    roomFlagsAndToolsSection

                    backdropSelectorSection

                    if isGroup {
                        groupMembersSection
                    }

                    dangerSection
                }
                .padding(.top, max(14, metrics.safeAreaTop + 8))
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingRailClearance)
                .padding(.bottom, max(88, metrics.safeAreaBottom + 76))
            }

            bottomCloseActionBar
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingRailClearance)
                .padding(.bottom, max(12, metrics.safeAreaBottom + 6))

            if let idx = activeLightboxIndex {
                let urls = sharedMediaItems.map(\.url)
                FullscreenMediaLightboxView(
                    mediaURLs: urls,
                    initialIndex: idx,
                    onDismiss: {
                        withAnimation(CuvenSprings.adaptive(CuvenSprings.smooth, reduceMotion: reduceMotion)) {
                            activeLightboxIndex = nil
                        }
                    }
                )
                .zIndex(50)
            }
        }
        .background(CuvenColors.paperBackground.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("artifact.roomInfo")
        .sheet(isPresented: $showPeerMomentsSheet) {
            if let peer = peerUser {
                UserMomentsProfileView(
                    store: store,
                    user: peer,
                    metrics: metrics,
                    onBack: { showPeerMomentsSheet = false },
                    onStartChat: { _ in showPeerMomentsSheet = false }
                )
            }
        }
        .sheet(isPresented: $showAddMemberSheet) {
            AddGroupMembersSheet(
                store: store,
                roomID: roomID,
                existingMemberIDs: Set(liveRoom.memberIDs)
            )
        }
        .alert(
            isGroup ? "Leave this group?" : "Delete conversation?",
            isPresented: $showDeleteOrLeaveAlert
        ) {
            Button(isGroup ? "Leave Group" : "Delete Chat", role: .destructive) {
                CuvenHaptics.rigidImpact()
                Task {
                    await store.deleteOrHideRoom(roomID: roomID)
                    onClose()
                }
            }
            Button("Cancel", role: .cancel) {
                CuvenHaptics.lightTap()
            }
        } message: {
            Text(
                isGroup
                    ? "You won't receive new messages from \(liveRoom.title) unless someone adds you back."
                    : "This hides \(liveRoom.title) from your conversation list."
            )
        }
    }

    // MARK: - 1. Profile Hero Card (`sheets.js:404-406` + Quick Audio/Video Call)

    private var profileHeroCard: some View {
        let cardShape = RoundedRectangle(cornerRadius: 24, style: .continuous)

        return VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                // Cover banner
                heroCoverBackdrop
                    .frame(height: 104)
                    .clipped()

                CuvenAvatarView(
                    name: isGroup ? liveRoom.title : (peerUser?.display ?? liveRoom.title),
                    urlString: isGroup ? liveRoom.avatarURL : (peerUser?.avatarURL ?? liveRoom.avatarURL),
                    size: 84,
                    isOnline: peerUser?.isOnline ?? false,
                    isGroupSquircle: isGroup,
                    showElevationRing: true
                )
                .offset(y: 38)
            }
            .padding(.bottom, 44)

            VStack(spacing: 4) {
                Text(isGroup ? liveRoom.title : (peerUser?.display ?? liveRoom.title))
                    .font(CuvenFonts.clarinettaDisplay(size: 24, weight: .bold))
                    .foregroundStyle(CuvenColors.inkPrimary)
                    .multilineTextAlignment(.center)

                Text(
                    isGroup
                        ? "\(max(resolvedMembers.count, liveRoom.memberIDs.count)) members"
                        : "@\(peerUser?.username ?? "cuven")"
                )
                .font(CuvenFonts.cappedSubheadline())
                .foregroundStyle(CuvenColors.inkSecondary)

                if let bio = peerUser?.bio, !bio.isEmpty {
                    Text(bio)
                        .font(CuvenFonts.cappedFootnote())
                        .foregroundStyle(CuvenColors.inkSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                        .padding(.horizontal, 16)
                }

                // Quick Audio & Video Call pills
                HStack(spacing: 10) {
                    Button {
                        CuvenHaptics.softImpact()
                        Task { await store.startCall(roomID: roomID, mode: .audio) }
                    } label: {
                        Label("Audio", systemImage: "phone.fill")
                            .font(CuvenFonts.cappedSubheadline(weight: .semibold))
                            .foregroundStyle(CuvenColors.inkPrimary)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 44)
                            .background(CuvenColors.fieldBackground, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("artifact.quickAudioCall")

                    Button {
                        CuvenHaptics.softImpact()
                        Task { await store.startCall(roomID: roomID, mode: .video) }
                    } label: {
                        Label("Video", systemImage: "video.fill")
                            .font(CuvenFonts.cappedSubheadline(weight: .semibold))
                            .foregroundStyle(CuvenColors.inkPrimary)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 44)
                            .background(CuvenColors.fieldBackground, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("artifact.quickVideoCall")
                }
                .padding(.top, 10)
            }
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity)
        .background(CuvenColors.elevatedSurface, in: cardShape)
        .clipShape(cardShape)
        .overlay(cardShape.strokeBorder(CuvenColors.cardLine, lineWidth: 1.0))
    }

    private var sharedLinksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SHARED LINKS")
                .font(CuvenFonts.cappedCaption2(weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(CuvenColors.inkSecondary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(sharedLinks.prefix(4).enumerated()), id: \.element.id) { idx, item in
                    if idx > 0 {
                        Divider()
                            .overlay(CuvenColors.hairlineSeparator)
                            .padding(.leading, 48)
                    }
                    Link(destination: item.url) {
                        HStack(spacing: 12) {
                            Image(systemName: "link")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(CuvenColors.sidebarBlue)
                                .frame(width: 28, height: 28)
                                .background(CuvenColors.sidebarBlue.opacity(0.12), in: Circle())

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.url.host ?? item.url.absoluteString)
                                    .font(CuvenFonts.cappedSubheadline(weight: .semibold))
                                    .foregroundStyle(CuvenColors.inkPrimary)
                                    .lineLimit(1)
                                Text(item.url.absoluteString)
                                    .font(CuvenFonts.cappedCaption())
                                    .foregroundStyle(CuvenColors.inkSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(CuvenColors.inkTertiary)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 50)
                    }
                }
            }
            .background(CuvenColors.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(CuvenColors.cardLine, lineWidth: 1.0)
            )
        }
    }

    @ViewBuilder
    private var heroCoverBackdrop: some View {
        if let cover = peerUser?.coverURL, !cover.isEmpty {
            if cover.hasPrefix("cuven-demo://cover/"),
               let preset = BackdropPreset(rawValue: String(cover.dropFirst("cuven-demo://cover/".count))) {
                CuvenBackdropView(preset: preset)
            } else if let preset = BackdropPreset(rawValue: cover) {
                CuvenBackdropView(preset: preset)
            } else {
                CuvenBackdropView(preset: liveRoom.backdrop ?? .mist, customImageURL: cover)
            }
        } else {
            CuvenBackdropView(preset: liveRoom.backdrop ?? (isGroup ? .ocean : .mist))
        }
    }

    // MARK: - 2. Conversation Smart Insights Card (`sheets.js:420`)

    private func roomInsightCard(_ insight: RoomInsight) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CuvenColors.sidebarBlue)
                Text("Conversation Context")
                    .font(CuvenFonts.cappedCaption(weight: .semibold))
                    .foregroundStyle(CuvenColors.sidebarBlue)

                Spacer()

                if let weather = insight.weatherSummary {
                    let tempSuffix = insight.temperatureText.map { " · \($0)" } ?? ""
                    Text(weather + tempSuffix)
                        .font(CuvenFonts.cappedCaption2(weight: .medium))
                        .foregroundStyle(CuvenColors.inkSecondary)
                        .lineLimit(1)
                }
            }

            Text(insight.summary)
                .font(CuvenFonts.cappedSubheadline())
                .foregroundStyle(CuvenColors.inkPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if let chip = insight.actionChip, !chip.isEmpty {
                    Text(chip)
                        .font(CuvenFonts.cappedCaption(weight: .semibold))
                        .foregroundStyle(CuvenColors.accessibleBlueText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(CuvenColors.sidebarBlue.opacity(0.12), in: Capsule())
                }

                if let localTime = insight.peerLocalTime, !localTime.isEmpty {
                    Label(localTime, systemImage: "clock")
                        .font(CuvenFonts.cappedCaption2())
                        .foregroundStyle(CuvenColors.inkSecondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CuvenColors.elevatedSurface, in: shape)
        .overlay(shape.strokeBorder(CuvenColors.cardLine, lineWidth: 1.0))
    }

    // MARK: - 3. Peer Moments Entry (`sheets.js:414-417`)

    private var peerMomentsSection: some View {
        Button {
            CuvenHaptics.lightTap()
            showPeerMomentsSheet = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(CuvenColors.momentsSkyBlue)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Moments")
                        .font(CuvenFonts.cappedBody(weight: .medium))
                        .foregroundStyle(CuvenColors.inkPrimary)
                    if peerMomentsCount > 0 {
                        Text("\(peerMomentsCount) shared \(peerMomentsCount == 1 ? "post" : "posts")")
                            .font(CuvenFonts.cappedCaption())
                            .foregroundStyle(CuvenColors.inkSecondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CuvenColors.inkTertiary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 54)
            .background(CuvenColors.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(CuvenColors.cardLine, lineWidth: 1.0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("artifact.peerMomentsButton")
    }

    // MARK: - 4. Shared Media & Sketches Strip

    private var sharedMediaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SHARED MEDIA & SKETCHES")
                    .font(CuvenFonts.cappedCaption2(weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(CuvenColors.inkSecondary)
                Spacer()
                Text("\(sharedMediaItems.count)")
                    .font(CuvenFonts.cappedCaption(weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(CuvenColors.inkTertiary)
            }
            .padding(.horizontal, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(sharedMediaItems.enumerated()), id: \.element.id) { index, media in
                        Button {
                            CuvenHaptics.lightTap()
                            activeLightboxIndex = index
                        } label: {
                            ZStack(alignment: .bottomTrailing) {
                                CuvenMediaAssetView(
                                    urlString: media.url,
                                    isDrawing: media.isDrawing,
                                    contentMode: .fill,
                                    serverBaseURL: store.serverBaseURL
                                )
                                .frame(width: 78, height: 78)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                                if media.isDrawing || media.isVideo {
                                    Image(systemName: media.isDrawing ? "paintbrush.pointed.fill" : "play.fill")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(5)
                                        .background(Color.black.opacity(0.52), in: Circle())
                                        .padding(5)
                                }
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(CuvenColors.cardLine, lineWidth: 0.8)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(media.isDrawing ? "Shared drawing" : (media.isVideo ? "Shared video" : "Shared photo"))
                    }
                }
            }
        }
    }

    // MARK: - 5. Mute, Pin & Drawing Board Actions (`sheets.js:408-411`)

    private var roomFlagsAndToolsSection: some View {
        let groupShape = RoundedRectangle(cornerRadius: 20, style: .continuous)

        return VStack(spacing: 0) {
            Toggle(
                isOn: Binding(
                    get: { liveRoom.isMuted },
                    set: { _ in
                        CuvenHaptics.selectionChanged()
                        Task { await store.toggleRoomMute(roomID: roomID) }
                    }
                )
            ) {
                HStack(spacing: 12) {
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(CuvenColors.sidebarBlue)
                        .frame(width: 28)
                    Text("Mute notifications")
                        .font(CuvenFonts.cappedBody())
                        .foregroundStyle(CuvenColors.inkPrimary)
                }
            }
            .tint(CuvenColors.onlineGreen)
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .accessibilityIdentifier("artifact.muteToggle")

            Divider()
                .overlay(CuvenColors.hairlineSeparator)
                .padding(.leading, 56)

            Toggle(
                isOn: Binding(
                    get: { liveRoom.isPinned },
                    set: { _ in
                        CuvenHaptics.selectionChanged()
                        Task { await store.toggleRoomPin(roomID: roomID) }
                    }
                )
            ) {
                HStack(spacing: 12) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(CuvenColors.sidebarBlue)
                        .frame(width: 28)
                    Text("Pin conversation")
                        .font(CuvenFonts.cappedBody())
                        .foregroundStyle(CuvenColors.inkPrimary)
                }
            }
            .tint(CuvenColors.onlineGreen)
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .accessibilityIdentifier("artifact.pinToggle")

            Divider()
                .overlay(CuvenColors.hairlineSeparator)
                .padding(.leading, 56)

            Button {
                CuvenHaptics.lightTap()
                store.openArtifact(.drawingBoard)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "scribble.variable")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(CuvenColors.sidebarBlue)
                        .frame(width: 28)
                    Text("Open drawing board")
                        .font(CuvenFonts.cappedBody())
                        .foregroundStyle(CuvenColors.inkPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CuvenColors.inkTertiary)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("artifact.openDrawingButton")
        }
        .background(CuvenColors.elevatedSurface, in: groupShape)
        .overlay(groupShape.strokeBorder(CuvenColors.cardLine, lineWidth: 1.0))
    }

    // MARK: - 6. Conversation Backdrop Preset Swatches

    private var backdropSelectorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CONVERSATION BACKDROP")
                .font(CuvenFonts.cappedCaption2(weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(CuvenColors.inkSecondary)
                .padding(.horizontal, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(BackdropPreset.allCases, id: \.self) { preset in
                        let isSelected = (liveRoom.backdrop ?? store.prefs.defaultBackdrop) == preset
                        Button {
                            CuvenHaptics.selectionChanged()
                            if let idx = store.rooms.firstIndex(where: { $0.id == roomID }) {
                                store.rooms[idx].backdrop = preset
                            }
                        } label: {
                            VStack(spacing: 5) {
                                CuvenBackdropView(preset: preset)
                                    .frame(width: 52, height: 52)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .strokeBorder(
                                                isSelected ? CuvenColors.sidebarBlue : CuvenColors.cardLine,
                                                lineWidth: isSelected ? 2.2 : 0.8
                                            )
                                    }
                                Text(preset.displayName)
                                    .font(CuvenFonts.cappedCaption2(weight: isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? CuvenColors.inkPrimary : CuvenColors.inkSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(preset.displayName) backdrop")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - 7. Group Members Grid & `+ Add` (`sheets.js:422-430`)

    private var groupMembersSection: some View {
        let columns = [GridItem(.adaptive(minimum: 68, maximum: 88), spacing: 12)]

        return VStack(alignment: .leading, spacing: 10) {
            Text("MEMBERS")
                .font(CuvenFonts.cappedCaption2(weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(CuvenColors.inkSecondary)
                .padding(.horizontal, 4)

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(resolvedMembers) { member in
                    VStack(spacing: 5) {
                        CuvenAvatarView(
                            name: member.display,
                            urlString: member.avatarURL,
                            size: 48,
                            isOnline: member.isOnline
                        )
                        Text(member.display)
                            .font(CuvenFonts.cappedCaption())
                            .foregroundStyle(CuvenColors.inkPrimary)
                            .lineLimit(1)
                    }
                }

                Button {
                    CuvenHaptics.lightTap()
                    showAddMemberSheet = true
                } label: {
                    VStack(spacing: 5) {
                        ZStack {
                            Circle()
                                .fill(CuvenColors.fieldBackground)
                                .frame(width: 48, height: 48)
                                .overlay(Circle().strokeBorder(CuvenColors.cardLine, lineWidth: 1.0))
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(CuvenColors.sidebarBlue)
                        }
                        Text("Add")
                            .font(CuvenFonts.cappedCaption(weight: .medium))
                            .foregroundStyle(CuvenColors.sidebarBlue)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add member")
                .accessibilityIdentifier("artifact.addMemberButton")
            }
            .padding(14)
            .background(CuvenColors.elevatedSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(CuvenColors.cardLine, lineWidth: 1.0)
            )
        }
    }

    // MARK: - 8. Destructive Action (`Leave group` / `Delete chat`)

    private var dangerSection: some View {
        Button {
            CuvenHaptics.warning()
            showDeleteOrLeaveAlert = true
        } label: {
            Text(isGroup ? "Leave group" : "Delete chat")
                .font(CuvenFonts.cappedBody(weight: .semibold))
                .foregroundStyle(CuvenColors.dangerRedText)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(CuvenColors.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(CuvenColors.cardLine, lineWidth: 1.0)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("artifact.dangerActionButton")
    }

    // MARK: - 9. Bottom Close / Back Bar (`artifact.js:39-48` & `testB12`)

    private var bottomCloseActionBar: some View {
        let isSingleColumn = metrics.visibleColumnCount == 1

        return HStack {
            Button {
                CuvenHaptics.lightTap()
                onClose()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isSingleColumn ? "chevron.left" : "xmark")
                        .font(.system(size: 15, weight: .semibold))
                    Text(isSingleColumn ? "Back" : "Close")
                        .font(CuvenFonts.cappedSubheadline(weight: .semibold))
                }
                .foregroundStyle(CuvenColors.inkPrimary)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
            }
            .buttonStyle(.cuvenGlassPill(mode: store.prefs.glassMode, cornerRadius: 22))
            .accessibilityLabel(isSingleColumn ? "Back" : "Close")
            .accessibilityIdentifier("artifact.close")

            Spacer()
        }
        .cuvenCappedDynamicType()
    }
}

// MARK: - Add Group Members Picker Sheet (`sheets.js:444-466`)

private struct AddGroupMembersSheet: View {
    let store: AppStore
    let roomID: String
    let existingMemberIDs: Set<String>

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<String> = []

    private var eligibleContacts: [CuvenUser] {
        store.contacts
            .filter { $0.status == .accepted && !existingMemberIDs.contains($0.user.id) }
            .map(\.user)
    }

    var body: some View {
        NavigationStack {
            List {
                if eligibleContacts.isEmpty {
                    Text("All of your contacts are already in this group.")
                        .font(CuvenFonts.cappedSubheadline())
                        .foregroundStyle(CuvenColors.inkSecondary)
                        .listRowBackground(CuvenColors.elevatedSurface)
                } else {
                    ForEach(eligibleContacts) { contact in
                        let picked = selectedIDs.contains(contact.id)
                        Button {
                            CuvenHaptics.selectionChanged()
                            if picked {
                                selectedIDs.remove(contact.id)
                            } else {
                                selectedIDs.insert(contact.id)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                CuvenAvatarView(
                                    name: contact.display,
                                    urlString: contact.avatarURL,
                                    size: 40,
                                    isOnline: contact.isOnline
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(contact.display)
                                        .font(CuvenFonts.cappedBody(weight: .medium))
                                        .foregroundStyle(CuvenColors.inkPrimary)
                                    Text("@\(contact.username)")
                                        .font(CuvenFonts.cappedCaption())
                                        .foregroundStyle(CuvenColors.inkSecondary)
                                }
                                Spacer()
                                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(picked ? CuvenColors.sidebarBlue : CuvenColors.inkTertiary)
                            }
                            .frame(minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Add Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let idx = store.rooms.firstIndex(where: { $0.id == roomID }) {
                            for uid in selectedIDs where !store.rooms[idx].memberIDs.contains(uid) {
                                store.rooms[idx].memberIDs.append(uid)
                            }
                            let count = store.rooms[idx].memberIDs.count
                            store.rooms[idx].subtitle = "\(count) members"
                        }
                        CuvenHaptics.success()
                        dismiss()
                    }
                    .disabled(selectedIDs.isEmpty)
                }
            }
        }
    }
}

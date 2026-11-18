import Foundation
import CoreGraphics
import Observation
import CuvenCore

// MARK: - Central AppStore Coordinator (PROJECT.md § 5.2, ios/Cuven/Core/AppStore.swift)
//
// Owns session & Keychain state, instant Stale-While-Revalidate `BootCache` cold-start hydration,
// `CuvenAPIClient` + `CuvenWebSocketClient` (`/api/ws` 17 realtime events), `PersistentOutbox` FIFO
// idempotent delivery, `NDJSONStreamClient` AI explain streaming, and deterministic `--uitest-demo`
// / `--uitest-logged-out` / `--uitest-posture=<case>` runtime coordination.

@MainActor
@Observable
public final class AppStore {

    // MARK: - Session & Environment (`PROJECT.md § 5.2`)

    public var serverBaseURL: URL {
        didSet {
            guard serverBaseURL != oldValue else { return }
            sessionStore.saveServerBaseURL(serverBaseURL)
            let token = sessionStore.loadSessionToken()
            KeychainSessionStore.synchronizeSharedCookieStorage(token: token, serverBaseURL: serverBaseURL)
            let updatedURL = serverBaseURL
            Task {
                await apiClient.setBaseURL(updatedURL)
            }
        }
    }
    public var isAuthenticated: Bool = false
    public var isDemoMode: Bool = false
    public var isBootstrapping: Bool = false
    public var authError: String? = nil
    public var currentUser: CuvenUser? = nil
    public var needsInviteCode: Bool = false
    public var isWebSocketConnected: Bool = false

    // MARK: - Spatial & Navigation State (`PROJECT.md § 5.2`)

    public var activePage: NavigationPage = .chats
    public var selectedSidebarScope: SidebarScope = .all
    public var selectedRoomID: String? = nil
    public var activeArtifactMode: ArtifactMode? = nil
    public var activeColumnIndex: Int = 1 // 0: Sidebar, 1: ChatList, 2: Thread, 3: Artifact
    public var postureOverride: DuoPosture? = nil
    public var searchQuery: String = ""

    /// Peer-compatible alias (`AdaptiveActionBars.swift`) backed directly by `selectedSidebarScope`.
    public var activeSidebarScope: SidebarScope {
        get { selectedSidebarScope }
        set { selectedSidebarScope = newValue }
    }

    // MARK: - Domain Collections (`PROJECT.md § 5.2`)

    public var rooms: [Room] = []
    public var messagesByRoom: [String: [Message]] = [:]
    public var draftsByRoom: [String: String] = [:]
    public var typingPreviewByRoom: [String: String] = [:]
    public var ghostSuggestionByRoom: [String: String] = [:]
    public var contacts: [ContactItem] = []
    public var suggestedPeople: [CuvenUser] = []
    public var notes: [UserNote] = []
    public var myNote: UserNote? = nil
    public var moments: [MomentPost] = []
    public var memories: [MemoryItem] = []
    public var stickerPacks: [StickerPack] = []
    public var installedStickerPackNames: Set<String> = [
        "HandDrawnEmoji",
        "GameEmoji"
    ]
    public var insightsByRoom: [String: RoomInsight] = [:]

    /// Peer-compatible alias (`RoomDetailsInfoView.swift`) backed directly by `insightsByRoom`.
    public var insights: [String: RoomInsight] {
        get { insightsByRoom }
        set { insightsByRoom = newValue }
    }
    public var activeCall: CallSession? = nil
    public var prefs: UserPrefs = UserPrefs()
    public var aiMemories: [AIMemoryItem] = []
    public var aiRoutineBuckets: [AIRoutineHourBucket] = (0..<24).map {
        AIRoutineHourBucket(hour: $0, activityScore: 0)
    }
    public var recentAvatarURLs: [String] = []

    // MARK: - Auxiliary Thread, Banner & Call Signaling State

    public var replyingToMessageByRoom: [String: Message] = [:]
    public var editingMessageByRoom: [String: Message] = [:]
    public var activeBannerMessage: String? = nil
    public var lastCallSignalPayload: [String: CuvenJSONValue]? = nil

    // MARK: - Underlying Infrastructure Clients

    public let apiClient: CuvenAPIClient
    public let webSocketClient: CuvenWebSocketClient
    public let streamClient: NDJSONStreamClient
    public let bootCache: BootCache
    public let outbox: PersistentOutbox
    public let blobStore: OutboxBlobStore
    public let sessionStore: KeychainSessionStore
    public let mediaLoader: AuthenticatedMediaLoader

    private let launchArguments: [String]
    private var typingClearTasks: [String: Task<Void, Never>] = [:]
    private var lastTypingSentAtMs: [String: Int64] = [:]
    private var didConnectOutbox: Bool = false

    // MARK: - Initialization

    public init(
        launchArguments: [String] = ProcessInfo.processInfo.arguments,
        apiClient: CuvenAPIClient? = nil,
        webSocketDialer: CuvenWebSocketDialer = URLSessionWebSocketDialer(),
        bootCache: BootCache = BootCache(),
        outbox: PersistentOutbox = PersistentOutbox(),
        blobStore: OutboxBlobStore = OutboxBlobStore(),
        sessionStore: KeychainSessionStore = .shared,
        mediaLoader: AuthenticatedMediaLoader = .shared
    ) {
        self.launchArguments = launchArguments
        self.bootCache = bootCache
        self.outbox = outbox
        self.blobStore = blobStore
        self.sessionStore = sessionStore
        self.mediaLoader = mediaLoader

        let initialBaseURL = sessionStore.loadServerBaseURL()
        self.serverBaseURL = initialBaseURL
        self.prefs = sessionStore.loadUserPrefs()
        if let savedPacks = sessionStore.loadInstalledStickerPacks(), !savedPacks.isEmpty {
            self.installedStickerPackNames = savedPacks
        }

        let isForcedLoggedOut = launchArguments.contains("--uitest-logged-out")
        let isForcedDemo = launchArguments.contains("--uitest-demo")
        let storedToken = (isForcedLoggedOut || isForcedDemo) ? nil : sessionStore.loadSessionToken()

        if let storedToken {
            KeychainSessionStore.synchronizeSharedCookieStorage(token: storedToken, serverBaseURL: initialBaseURL)
        }

        let resolvedAPI = apiClient ?? CuvenAPIClient(
            baseURL: initialBaseURL,
            sessionToken: storedToken
        )
        self.apiClient = resolvedAPI
        self.webSocketClient = CuvenWebSocketClient(apiClient: resolvedAPI, dialer: webSocketDialer)
        self.streamClient = NDJSONStreamClient(apiClient: resolvedAPI)

        // Apply `--uitest-posture=<case>` immediately for deterministic frame-1 layout metrics
        for arg in launchArguments where arg.hasPrefix("--uitest-posture=") {
            let rawPosture = String(arg.dropFirst("--uitest-posture=".count))
            if let parsed = DuoPosture(rawValue: rawPosture) {
                self.postureOverride = parsed
            }
        }

        if isForcedDemo {
            enterDemoMode()
        } else if isForcedLoggedOut {
            self.isAuthenticated = false
            self.isDemoMode = false
            self.currentUser = nil
            self.stickerPacks = DemoSeedFactory.buildStickerPacks()
        } else if storedToken != nil, let cached = bootCache.loadSynchronously() {
            applyBootSnapshot(cached)
        } else {
            self.stickerPacks = DemoSeedFactory.buildStickerPacks()
        }
    }

    // MARK: - Lifecycle & Bootstrap (`PROJECT.md § 5.2`)

    public func bootstrap() async {
        await wireInfrastructureCallbacksIfNeeded()

        if launchArguments.contains("--uitest-demo") || isDemoMode {
            if !isAuthenticated {
                enterDemoMode()
            }
            return
        }

        if launchArguments.contains("--uitest-logged-out") {
            isAuthenticated = false
            isDemoMode = false
            isBootstrapping = false
            return
        }

        let token = sessionStore.loadSessionToken()
        await apiClient.setSessionToken(token)

        isBootstrapping = (currentUser == nil && rooms.isEmpty)
        defer { isBootstrapping = false }

        do {
            let status = try await apiClient.fetchAuthStatus()
            needsInviteCode = status.needsInviteCode
            guard status.isAuthenticated else {
                if token != nil {
                    sessionStore.clearSession(for: serverBaseURL)
                }
                isAuthenticated = false
                currentUser = nil
                return
            }

            isAuthenticated = true
            isDemoMode = false
            if let user = status.user {
                currentUser = mergeLocalTintIfNeeded(into: user)
            }
            await refreshAllAuthenticatedData()
            startRealtimeSocket()
        } catch {
            // Preserve cached offline snapshot if already hydrated (`BootCache` stale-while-revalidate)
            if currentUser != nil {
                isAuthenticated = true
                startRealtimeSocket()
            }
        }
    }

    public func enterDemoMode() {
        let seed = DemoSeedFactory.makeDataset()
        isDemoMode = true
        isAuthenticated = true
        isBootstrapping = false
        authError = nil
        currentUser = seed.currentUser
        rooms = sortRooms(seed.rooms)
        messagesByRoom = seed.messagesByRoom
        typingPreviewByRoom = seed.typingPreviewByRoom
        ghostSuggestionByRoom = seed.ghostSuggestionByRoom
        contacts = seed.contacts
        suggestedPeople = seed.suggestedPeople
        myNote = seed.myNote
        notes = seed.notes
        moments = seed.moments
        memories = seed.memories
        stickerPacks = seed.stickerPacks
        installedStickerPackNames = seed.installedStickerPackNames
        insightsByRoom = seed.insightsByRoom
        prefs = seed.prefs
        aiMemories = seed.aiMemories
        aiRoutineBuckets = seed.aiRoutineBuckets
        recentAvatarURLs = seed.recentAvatarURLs
        activePage = .chats
        selectedSidebarScope = .all
        activeArtifactMode = nil
        activeColumnIndex = 1
        selectedRoomID = rooms.first(where: { !$0.isHidden })?.id
    }

    public func signIn(username: String, password: String) async throws {
        await wireInfrastructureCallbacksIfNeeded()
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUsername.isEmpty, !password.isEmpty else {
            let err = CuvenAPIError(message: "Please enter both username and password.", statusCode: 400)
            authError = err.message
            throw err
        }

        authError = nil
        isBootstrapping = true
        defer { isBootstrapping = false }

        do {
            let user = try await apiClient.login(username: cleanUsername, password: password)
            if let token = await apiClient.sessionToken {
                sessionStore.saveSessionToken(token, for: serverBaseURL)
            }
            isDemoMode = false
            isAuthenticated = true
            currentUser = mergeLocalTintIfNeeded(into: user)
            activePage = .chats
            activeColumnIndex = 1
            await refreshAllAuthenticatedData()
            startRealtimeSocket()
        } catch let apiErr as CuvenAPIError {
            authError = apiErr.message
            throw apiErr
        } catch {
            authError = error.localizedDescription
            throw error
        }
    }

    public func register(username: String, password: String, display: String, inviteCode: String?) async throws {
        await wireInfrastructureCallbacksIfNeeded()
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDisplay = display.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUsername.isEmpty, !password.isEmpty else {
            let err = CuvenAPIError(message: "Username and password are required.", statusCode: 400)
            authError = err.message
            throw err
        }

        authError = nil
        isBootstrapping = true
        defer { isBootstrapping = false }

        do {
            let user = try await apiClient.register(
                username: cleanUsername,
                password: password,
                display: cleanDisplay.isEmpty ? cleanUsername : cleanDisplay,
                inviteCode: inviteCode
            )
            if let token = await apiClient.sessionToken {
                sessionStore.saveSessionToken(token, for: serverBaseURL)
            }
            isDemoMode = false
            isAuthenticated = true
            currentUser = mergeLocalTintIfNeeded(into: user)
            activePage = .chats
            activeColumnIndex = 1
            await refreshAllAuthenticatedData()
            startRealtimeSocket()
        } catch let apiErr as CuvenAPIError {
            authError = apiErr.message
            throw apiErr
        } catch {
            authError = error.localizedDescription
            throw error
        }
    }

    public func signOut() async {
        let wasDemo = isDemoMode
        await webSocketClient.stop()
        if !wasDemo {
            try? await apiClient.logout()
        }
        sessionStore.clearSession(for: serverBaseURL)
        bootCache.clear()

        isAuthenticated = false
        isDemoMode = false
        isWebSocketConnected = false
        authError = nil
        currentUser = nil
        activeCall = nil
        activeArtifactMode = nil
        selectedRoomID = nil
        activePage = .chats
        selectedSidebarScope = .all
        activeColumnIndex = 1
        searchQuery = ""
        rooms = []
        messagesByRoom = [:]
        draftsByRoom = [:]
        typingPreviewByRoom = [:]
        ghostSuggestionByRoom = [:]
        contacts = []
        suggestedPeople = []
        notes = []
        myNote = nil
        moments = []
        memories = []
        insightsByRoom = [:]
    }

    // MARK: - Spatial & Column Navigation (`PROJECT.md § 5.2`)

    public func selectRoom(_ roomID: String?) {
        selectedRoomID = roomID
        guard let roomID, !roomID.isEmpty else {
            if activeColumnIndex >= 2 {
                activeColumnIndex = 1
            }
            activeArtifactMode = nil
            return
        }

        activePage = .chats
        if activeArtifactMode == nil || activeColumnIndex < 2 {
            activeColumnIndex = 2
        }

        var latestTimestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
        if let rIdx = rooms.firstIndex(where: { $0.id == roomID }) {
            rooms[rIdx].unreadCount = 0
            rooms[rIdx].isMarkedUnread = false
            if rooms[rIdx].lastMessageTimestamp > 0 {
                latestTimestamp = rooms[rIdx].lastMessageTimestamp
            }
        }

        guard !isDemoMode else { return }

        Task {
            if prefs.sendReadReceipts {
                try? await apiClient.markRoomRead(roomID: roomID, timestampMs: latestTimestamp)
                await webSocketClient.send(.read(roomID: roomID, timestampMs: latestTimestamp))
            }
            await loadMessagesIfNeeded(for: roomID)
        }
    }

    public func openArtifact(_ mode: ArtifactMode, for roomID: String) {
        if selectedRoomID != roomID {
            selectedRoomID = roomID
        }
        activePage = .chats
        activeArtifactMode = mode
        activeColumnIndex = 3
    }

    /// Convenience overload (`AdaptiveActionBars.swift`) targeting the currently selected or top visible room.
    public func openArtifact(_ mode: ArtifactMode) {
        let targetRoomID = selectedRoomID ?? rooms.first(where: { !$0.isHidden })?.id ?? ""
        if !targetRoomID.isEmpty {
            openArtifact(mode, for: targetRoomID)
        } else {
            activeArtifactMode = mode
            activeColumnIndex = 3
        }
    }

    public func closeArtifact() {
        activeArtifactMode = nil
        if activeColumnIndex >= 3 {
            activeColumnIndex = selectedRoomID != nil ? 2 : 1
        }
    }

    public func navigateToPage(_ page: NavigationPage) {
        activePage = page
        switch page {
        case .menu:
            activeColumnIndex = 0
        case .chats:
            if activeColumnIndex == 0 {
                activeColumnIndex = 1
            }
        case .moments, .memories, .friends, .you:
            break
        }
    }

    // MARK: - Messaging & Persistent Outbox Actions (`PROJECT.md § 5.2`)

    public func sendText(_ text: String, in roomID: String, replyToID: String? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !roomID.isEmpty else { return }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let cid = "cid_\(UUID().uuidString.lowercased())"
        let senderID = currentUser?.id ?? "u_me"
        let senderDisplay = currentUser?.display ?? "You"
        let effectiveReplyID = replyToID ?? replyingToMessageByRoom[roomID]?.id
        let extractedMentions = extractMentionedUserIDs(in: trimmed)

        let optimistic = Message(
            id: isDemoMode ? "msg_\(UUID().uuidString.prefix(10).lowercased())" : cid,
            localID: cid,
            roomID: roomID,
            senderID: senderID,
            senderDisplay: senderDisplay,
            kind: .text,
            text: trimmed,
            replyToMessageID: effectiveReplyID,
            mentions: extractedMentions,
            deliveryState: isDemoMode ? .sent : .sending,
            createdAt: nowMs
        )

        upsertMessage(optimistic, in: roomID)
        updateRoomSummary(roomID: roomID, preview: String(trimmed.prefix(120)), timestampMs: nowMs)
        draftsByRoom[roomID] = ""
        ghostSuggestionByRoom.removeValue(forKey: roomID)
        replyingToMessageByRoom.removeValue(forKey: roomID)
        recordLocalRoutineActivity(at: Date())

        if isDemoMode {
            scheduleDemoDeliveryProgression(messageID: optimistic.id, in: roomID)
            return
        }

        var body: [String: CuvenJSONValue] = [
            "room": .string(roomID),
            "type": .string("text"),
            "body": .string(trimmed)
        ]
        if let effectiveReplyID {
            body["replyTo"] = .string(effectiveReplyID)
        }
        if !extractedMentions.isEmpty {
            body["meta"] = .object([
                "mentions": .array(extractedMentions.map(CuvenJSONValue.string))
            ])
        }

        await wireInfrastructureCallbacksIfNeeded()
        await outbox.enqueue(cid: cid, roomID: roomID, body: body, optimisticMessage: optimistic)
        saveSnapshotQuietly()
    }

    public func sendMedia(
        data: Data,
        mimeType: String,
        kind: MessageKind,
        in roomID: String,
        width: Int? = nil,
        height: Int? = nil,
        duration: Double? = nil
    ) async {
        guard !data.isEmpty, !roomID.isEmpty else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let cid = "cid_\(UUID().uuidString.lowercased())"
        let ext = Self.fileExtension(for: mimeType, kind: kind)
        let localURL = mediaLoader.persistLocalMediaFile(data, fileExtension: ext, preferredName: cid)?.absoluteString
            ?? "data:\(mimeType);base64,\(data.base64EncodedString())"

        let senderID = currentUser?.id ?? "u_me"
        let senderDisplay = currentUser?.display ?? "You"
        let captionText: String
        let previewLabel: String
        switch kind {
        case .drawing:
            captionText = "Sketch"
            previewLabel = "[Drawing]"
        case .voice:
            captionText = "Voice message"
            previewLabel = "[Voice]"
        case .video:
            captionText = "Video"
            previewLabel = "[Video]"
        case .file:
            captionText = "Attachment"
            previewLabel = "[File]"
        default:
            captionText = ""
            previewLabel = "[Photo]"
        }

        let optimistic = Message(
            id: isDemoMode ? "msg_\(UUID().uuidString.prefix(10).lowercased())" : cid,
            localID: cid,
            roomID: roomID,
            senderID: senderID,
            senderDisplay: senderDisplay,
            kind: kind,
            text: captionText,
            mediaURLs: [localURL],
            mediaWidth: width,
            mediaHeight: height,
            durationSeconds: duration,
            deliveryState: isDemoMode ? .sent : .sending,
            createdAt: nowMs
        )

        upsertMessage(optimistic, in: roomID)
        updateRoomSummary(roomID: roomID, preview: previewLabel, timestampMs: nowMs)
        recordLocalRoutineActivity(at: Date())

        if kind == .image || kind == .video || kind == .drawing {
            let roomTitle = rooms.first(where: { $0.id == roomID })?.title ?? "Chat"
            let memory = MemoryItem(
                id: "mem_\(cid)",
                kind: kind,
                mediaURL: localURL,
                caption: captionText,
                roomTitle: roomTitle,
                monthKey: CuvenWireMapper.monthKeyFromTimestamp(nowMs),
                createdAt: nowMs
            )
            memories.insert(memory, at: 0)
        }

        if isDemoMode {
            scheduleDemoDeliveryProgression(messageID: optimistic.id, in: roomID)
            return
        }

        blobStore.put(cid: cid, data: data)
        var meta: [String: CuvenJSONValue] = [:]
        if let width { meta["w"] = .int(Int64(width)) }
        if let height { meta["h"] = .int(Int64(height)) }
        if let duration { meta["dur"] = .double(duration) }

        let descriptor = OutboxMediaDescriptor(
            kind: kind.rawValue,
            contentType: mimeType,
            fileName: "\(cid).\(ext)",
            width: width,
            height: height,
            durationSeconds: duration
        )
        let body: [String: CuvenJSONValue] = [
            "room": .string(roomID),
            "type": .string(kind.rawValue),
            "body": .string(captionText),
            "meta": .object(meta)
        ]

        await wireInfrastructureCallbacksIfNeeded()
        await outbox.enqueue(
            cid: cid,
            roomID: roomID,
            body: body,
            optimisticMessage: optimistic,
            media: descriptor
        )
        saveSnapshotQuietly()
    }

    public func sendDrawing(pngData: Data, in roomID: String) async {
        await sendMedia(
            data: pngData,
            mimeType: "image/png",
            kind: .drawing,
            in: roomID,
            width: 1024,
            height: 768
        )
    }

    /// Peer-compatible overload (`DrawingBoardCanvasView.swift`) preserving exact exported pixel dimensions.
    public func sendDrawing(roomID: String, pngData: Data, size: CGSize) async {
        await sendMedia(
            data: pngData,
            mimeType: "image/png",
            kind: .drawing,
            in: roomID,
            width: max(1, Int(size.width.rounded())),
            height: max(1, Int(size.height.rounded()))
        )
    }

    public func sendSticker(_ sticker: StickerItem, in roomID: String) async {
        guard !roomID.isEmpty else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let cid = "cid_\(UUID().uuidString.lowercased())"
        let senderID = currentUser?.id ?? "u_me"
        let senderDisplay = currentUser?.display ?? "You"

        let optimistic = Message(
            id: isDemoMode ? "msg_\(UUID().uuidString.prefix(10).lowercased())" : cid,
            localID: cid,
            roomID: roomID,
            senderID: senderID,
            senderDisplay: senderDisplay,
            kind: .sticker,
            text: sticker.emoji,
            mediaURLs: [sticker.assetURL],
            stickerID: sticker.id,
            stickerSet: sticker.setName,
            stickerFormat: sticker.format,
            deliveryState: isDemoMode ? .sent : .sending,
            createdAt: nowMs
        )

        upsertMessage(optimistic, in: roomID)
        let preview = sticker.emoji.isEmpty ? "[Sticker]" : "[Sticker] \(sticker.emoji)"
        updateRoomSummary(roomID: roomID, preview: preview, timestampMs: nowMs)
        recordLocalRoutineActivity(at: Date())

        if isDemoMode {
            scheduleDemoDeliveryProgression(messageID: optimistic.id, in: roomID)
            return
        }

        let body: [String: CuvenJSONValue] = [
            "room": .string(roomID),
            "type": .string("sticker"),
            "body": .string(sticker.emoji),
            "meta": .object([
                "id": .string(sticker.id),
                "set": .string(sticker.setName),
                "emoji": .string(sticker.emoji),
                "kind": .string(CuvenWireMapper.wireStickerKind(sticker.format)),
                "url": .string(sticker.assetURL)
            ])
        ]

        await wireInfrastructureCallbacksIfNeeded()
        await outbox.enqueue(cid: cid, roomID: roomID, body: body, optimisticMessage: optimistic)
        saveSnapshotQuietly()
    }

    public func toggleReaction(_ emoji: String, on messageID: String, in roomID: String) async {
        guard EditPolicyValidator.isValidReaction(emoji),
              var list = messagesByRoom[roomID],
              let idx = list.firstIndex(where: { $0.id == messageID }) else {
            return
        }

        let uid = currentUser?.id ?? "u_me"
        let existingSame = list[idx].reactions.contains { $0.userID == uid && $0.emoji == emoji }
        list[idx].reactions.removeAll { $0.userID == uid }
        let wireEmoji: String
        if existingSame || emoji.isEmpty {
            wireEmoji = ""
        } else {
            list[idx].reactions.append(MessageReaction(userID: uid, emoji: emoji))
            wireEmoji = emoji
        }
        messagesByRoom[roomID] = list

        guard !isDemoMode else { return }
        if let updated = try? await apiClient.setReaction(
            messageID: messageID,
            emoji: wireEmoji,
            displayLookup: buildDisplayLookup()
        ) {
            upsertMessage(updated, in: roomID)
            saveSnapshotQuietly()
        }
    }

    public func editMessage(_ messageID: String, in roomID: String, newText: String) async throws {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var list = messagesByRoom[roomID],
              let idx = list.firstIndex(where: { $0.id == messageID }) else {
            throw EditValidationError.cannotEditMessage
        }

        let uid = currentUser?.id ?? "u_me"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if let problem = EditPolicyValidator.validateEdit(
            message: list[idx],
            editorUserID: uid,
            newText: trimmed,
            nowMilliseconds: nowMs
        ) {
            throw problem
        }

        let previousText = list[idx].text
        guard previousText != trimmed else { return }

        list[idx].editHistory.append(MessageEditEntry(text: previousText, editedAt: nowMs))
        list[idx].editCount += 1
        list[idx].text = trimmed
        messagesByRoom[roomID] = list
        editingMessageByRoom.removeValue(forKey: roomID)

        if idx == list.count - 1 {
            updateRoomSummary(roomID: roomID, preview: String(trimmed.prefix(120)), timestampMs: list[idx].createdAt)
        }

        guard !isDemoMode else { return }
        let serverUpdated = try await apiClient.editMessage(
            messageID: messageID,
            newText: trimmed,
            displayLookup: buildDisplayLookup()
        )
        upsertMessage(serverUpdated, in: roomID)
        saveSnapshotQuietly()
    }

    public func revokeMessage(_ messageID: String, in roomID: String) async {
        guard var list = messagesByRoom[roomID],
              let idx = list.firstIndex(where: { $0.id == messageID }) else {
            return
        }

        list[idx].deliveryState = .revoked
        list[idx].text = ""
        list[idx].mediaURLs = []
        list[idx].reactions = []
        messagesByRoom[roomID] = list

        if idx == list.count - 1 {
            updateRoomSummary(roomID: roomID, preview: "Message unsent", timestampMs: list[idx].createdAt)
        }

        guard !isDemoMode else { return }
        if let updated = try? await apiClient.revokeMessage(
            messageID: messageID,
            displayLookup: buildDisplayLookup()
        ) {
            upsertMessage(updated, in: roomID)
            saveSnapshotQuietly()
        }
    }

    public func sendTypingPreview(_ previewText: String, in roomID: String) {
        guard !isDemoMode, !roomID.isEmpty else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if !previewText.isEmpty, let last = lastTypingSentAtMs[roomID], nowMs - last < 220 {
            return
        }
        lastTypingSentAtMs[roomID] = nowMs
        Task {
            await webSocketClient.send(.typing(roomID: roomID, previewText: previewText))
        }
    }

    public func retryFailedMessage(_ messageOrLocalID: String, in roomID: String) async {
        guard var list = messagesByRoom[roomID],
              let idx = list.firstIndex(where: { $0.id == messageOrLocalID || $0.localID == messageOrLocalID }) else {
            return
        }
        let cid = list[idx].localID ?? list[idx].id
        list[idx].deliveryState = .sending
        let optimistic = list[idx]
        messagesByRoom[roomID] = list

        if isDemoMode {
            scheduleDemoDeliveryProgression(messageID: optimistic.id, in: roomID)
            return
        }
        _ = await outbox.retry(cid: cid, updatedOptimisticMessage: optimistic)
    }

    // MARK: - Room Management (`PROJECT.md § 5.2`)

    public func toggleRoomPin(_ roomID: String) {
        guard let idx = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        rooms[idx].isPinned.toggle()
        let newPinned = rooms[idx].isPinned
        rooms = sortRooms(rooms)
        saveSnapshotQuietly()

        guard !isDemoMode else { return }
        Task {
            try? await apiClient.setRoomFlags(roomID: roomID, pinned: newPinned)
        }
    }

    public func toggleRoomMute(_ roomID: String) {
        guard let idx = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        rooms[idx].isMuted.toggle()
        let newMuted = rooms[idx].isMuted
        saveSnapshotQuietly()

        guard !isDemoMode else { return }
        Task {
            try? await apiClient.setRoomFlags(roomID: roomID, muted: newMuted)
        }
    }

    public func toggleRoomUnread(_ roomID: String) {
        guard let idx = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        let currentlyUnread = rooms[idx].unreadCount > 0 || rooms[idx].isMarkedUnread
        if currentlyUnread {
            rooms[idx].unreadCount = 0
            rooms[idx].isMarkedUnread = false
        } else {
            rooms[idx].isMarkedUnread = true
        }
        let markUnread = !currentlyUnread
        saveSnapshotQuietly()

        guard !isDemoMode else { return }
        let ts = rooms[idx].lastMessageTimestamp > 0
            ? rooms[idx].lastMessageTimestamp
            : Int64(Date().timeIntervalSince1970 * 1000)
        Task {
            if markUnread {
                try? await apiClient.setRoomFlags(roomID: roomID, unread: true)
            } else {
                try? await apiClient.setRoomFlags(roomID: roomID, unread: false)
                try? await apiClient.markRoomRead(roomID: roomID, timestampMs: ts)
            }
        }
    }

    public func deleteOrHideRoom(_ roomID: String) {
        guard let idx = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        rooms[idx].isHidden = true
        if selectedRoomID == roomID {
            selectedRoomID = rooms.first(where: { !$0.isHidden })?.id
            if activeArtifactMode != nil {
                activeArtifactMode = nil
            }
            if activeColumnIndex >= 2 && selectedRoomID == nil {
                activeColumnIndex = 1
            }
        }
        saveSnapshotQuietly()

        guard !isDemoMode else { return }
        Task {
            try? await apiClient.setRoomFlags(roomID: roomID, hidden: true)
        }
    }

    /// Peer-compatible labeled async overloads (`RoomDetailsInfoView.swift`).
    public func toggleRoomPin(roomID: String) async {
        toggleRoomPin(roomID)
    }

    public func toggleRoomMute(roomID: String) async {
        toggleRoomMute(roomID)
    }

    public func toggleRoomUnread(roomID: String) async {
        toggleRoomUnread(roomID)
    }

    public func deleteOrHideRoom(roomID: String) async {
        deleteOrHideRoom(roomID)
    }

    public func leaveGroup(_ roomID: String) async {
        deleteOrHideRoom(roomID)
        guard !isDemoMode else { return }
        let encoded = roomID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? roomID
        _ = try? await apiClient.requestJSON(method: "POST", path: "/api/group/\(encoded)/leave", payload: [:])
    }

    public func setRoomBackdrop(_ preset: BackdropPreset?, for roomID: String) {
        guard let idx = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        rooms[idx].backdrop = preset
        saveSnapshotQuietly()

        guard !isDemoMode else { return }
        let map = currentRoomBackdropsMap()
        let snapshotPrefs = prefs
        Task {
            try? await apiClient.syncPreferences(snapshotPrefs, roomBackdrops: map)
        }
    }

    public func createDirectChat(with userID: String) async -> String {
        let cleaned = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let handle = cleaned.hasPrefix("@") ? String(cleaned.dropFirst()) : cleaned

        // Check existing DM by peerUserID or username subtitle
        if let existingIdx = rooms.firstIndex(where: {
            $0.kind == .dm && (
                $0.peerUserID == cleaned ||
                $0.peerUserID == handle ||
                $0.subtitle.caseInsensitiveCompare("@\(handle)") == .orderedSame
            )
        }) {
            rooms[existingIdx].isHidden = false
            return rooms[existingIdx].id
        }

        if !isDemoMode {
            if let serverRoom = try? await apiClient.createOrOpenDM(userOrUsername: handle) {
                upsertRoom(serverRoom)
                saveSnapshotQuietly()
                return serverRoom.id
            }
        }

        // Resolve known contact / suggested person or synthesize clean peer entry
        let matchedUser = contacts.first(where: { $0.user.id == cleaned || $0.user.username.caseInsensitiveCompare(handle) == .orderedSame })?.user
            ?? suggestedPeople.first(where: { $0.id == cleaned || $0.username.caseInsensitiveCompare(handle) == .orderedSame })
            ?? CuvenUser(
                id: cleaned.hasPrefix("u_") ? cleaned : "u_\(handle.lowercased())",
                username: handle.lowercased(),
                display: handle.prefix(1).uppercased() + handle.dropFirst(),
                isOnline: true
            )

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let roomID = "room_\(matchedUser.username.lowercased())"
        let newRoom = Room(
            id: roomID,
            kind: .dm,
            title: matchedUser.display,
            subtitle: "@\(matchedUser.username)",
            avatarURL: matchedUser.avatarURL,
            peerUserID: matchedUser.id,
            memberIDs: [currentUser?.id ?? "u_tokio", matchedUser.id],
            lastMessagePreview: "Say hello to \(matchedUser.display)",
            lastMessageTimestamp: nowMs,
            unreadCount: 0,
            backdrop: prefs.defaultBackdrop
        )
        upsertRoom(newRoom)
        if messagesByRoom[roomID] == nil {
            messagesByRoom[roomID] = []
        }
        return roomID
    }

    public func createGroupChat(name: String, memberIDs: [String]) async -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = trimmedName.isEmpty ? "Group Chat" : trimmedName

        if !isDemoMode {
            if let serverRoom = try? await apiClient.createGroup(name: resolvedTitle, memberIDs: memberIDs) {
                upsertRoom(serverRoom)
                saveSnapshotQuietly()
                return serverRoom.id
            }
        }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let myID = currentUser?.id ?? "u_tokio"
        let allMembers = Array(Set([myID] + memberIDs))
        let roomID = "room_grp_\(UUID().uuidString.prefix(8).lowercased())"
        let creatorDisplay = currentUser?.display ?? "You"

        let newRoom = Room(
            id: roomID,
            kind: .group,
            title: resolvedTitle,
            subtitle: "\(allMembers.count) members",
            memberIDs: allMembers,
            lastMessagePreview: "\(creatorDisplay) created \(resolvedTitle)",
            lastMessageTimestamp: nowMs,
            backdrop: prefs.defaultBackdrop
        )
        upsertRoom(newRoom)
        messagesByRoom[roomID] = [
            Message(
                id: "sys_\(roomID)",
                roomID: roomID,
                senderID: "",
                senderDisplay: "System",
                kind: .system,
                text: "\(creatorDisplay) created \(resolvedTitle)",
                createdAt: nowMs
            )
        ]
        return roomID
    }

    // MARK: - Social, 24h Notes, Moments & Stickers (`PROJECT.md § 5.2`)

    public func publishNote(text: String) async {
        let normalized = EditPolicyValidator.normalizeNoteText(text)
        guard !normalized.isEmpty else {
            await deleteMyNote()
            return
        }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let me = currentUser ?? CuvenUser(id: "u_tokio", username: "tokio", display: "Tokio")
        myNote = UserNote(
            userID: me.id,
            userDisplay: me.display,
            avatarURL: me.avatarURL,
            text: normalized,
            createdAt: nowMs
        )
        saveSnapshotQuietly()

        guard !isDemoMode else { return }
        if let serverNote = try? await apiClient.publishNote(text: normalized, currentUser: currentUser) {
            myNote = serverNote
            saveSnapshotQuietly()
        }
    }

    public func deleteMyNote() async {
        myNote = nil
        saveSnapshotQuietly()
        guard !isDemoMode else { return }
        try? await apiClient.deleteNote()
    }

    public func sendFriendRequest(usernameOrID: String) async {
        let cleaned = usernameOrID.trimmingCharacters(in: .whitespacesAndNewlines)
        let handle = cleaned.hasPrefix("@") ? String(cleaned.dropFirst()) : cleaned
        guard !handle.isEmpty else { return }

        if !isDemoMode, let serverItem = try? await apiClient.sendFriendRequest(usernameOrID: handle) {
            contacts.removeAll { $0.user.id == serverItem.user.id }
            contacts.insert(serverItem, at: 0)
            suggestedPeople.removeAll { $0.id == serverItem.user.id || $0.username.caseInsensitiveCompare(handle) == .orderedSame }
            saveSnapshotQuietly()
            return
        }

        if let sIdx = suggestedPeople.firstIndex(where: {
            $0.id == cleaned || $0.username.caseInsensitiveCompare(handle) == .orderedSame
        }) {
            let person = suggestedPeople.remove(at: sIdx)
            contacts.removeAll { $0.user.id == person.id }
            contacts.insert(ContactItem(user: person, status: .pendingOut, mutualNote: "Request sent"), at: 0)
            return
        }

        if !contacts.contains(where: { $0.user.id == cleaned || $0.user.username.caseInsensitiveCompare(handle) == .orderedSame }) {
            let synthetic = CuvenUser(
                id: "u_\(handle.lowercased())",
                username: handle.lowercased(),
                display: handle,
                isOnline: false
            )
            contacts.insert(ContactItem(user: synthetic, status: .pendingOut, mutualNote: "Request sent"), at: 0)
        }
    }

    public func acceptFriendRequest(userID: String) async {
        if let idx = contacts.firstIndex(where: { $0.user.id == userID }) {
            contacts[idx].status = .accepted
            contacts[idx].mutualNote = "Connected"
        }

        guard !isDemoMode else { return }
        if let peer = try? await apiClient.acceptFriendRequest(userID: userID) {
            if let idx = contacts.firstIndex(where: { $0.user.id == peer.id }) {
                contacts[idx].user = peer
                contacts[idx].status = .accepted
            } else {
                contacts.insert(ContactItem(user: peer, status: .accepted), at: 0)
            }
            saveSnapshotQuietly()
        }
    }

    public func dismissSuggestedPerson(userID: String) {
        suggestedPeople.removeAll { $0.id == userID }
        guard !isDemoMode else { return }
        Task {
            try? await apiClient.dismissPerson(userID: userID)
        }
    }

    public func publishMoment(
        text: String,
        media: [MomentMedia],
        audience: String,
        commentPolicy: String,
        taggedUserIDs: [String],
        scheduledAt: Int64?
    ) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty || !media.isEmpty else { return }

        if !isDemoMode {
            var uploadedMedia: [MomentMedia] = []
            for item in media {
                if item.url.hasPrefix("file://") || item.url.hasPrefix("data:"),
                   let rawData = await mediaLoader.loadData(from: item.url, serverBaseURL: serverBaseURL),
                   let uploaded = try? await apiClient.uploadMedia(
                       data: rawData,
                       contentType: item.isVideo ? "video/mp4" : "image/jpeg",
                       kind: item.isVideo ? "video" : "image",
                       width: item.width,
                       height: item.height
                   ) {
                    var nextItem = item
                    nextItem.url = uploaded.url
                    uploadedMedia.append(nextItem)
                } else {
                    uploadedMedia.append(item)
                }
            }

            if let created = try? await apiClient.publishMoment(
                text: trimmedText,
                media: uploadedMedia,
                audience: audience,
                commentPolicy: commentPolicy,
                taggedUserIDs: taggedUserIDs,
                scheduledAt: scheduledAt
            ) {
                moments.removeAll { $0.id == created.id }
                moments.insert(created, at: 0)
                saveSnapshotQuietly()
                return
            }
        }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let author = currentUser ?? CuvenUser(id: "u_tokio", username: "tokio", display: "Tokio", isOnline: true)
        let post = MomentPost(
            id: "mom_\(UUID().uuidString.prefix(10).lowercased())",
            author: author,
            text: trimmedText,
            media: media,
            audience: audience,
            commentPolicy: commentPolicy,
            taggedUserIDs: taggedUserIDs,
            likedUserIDs: [],
            comments: [],
            scheduledAt: scheduledAt,
            createdAt: scheduledAt ?? nowMs
        )
        moments.insert(post, at: 0)
        saveSnapshotQuietly()
    }

    public func toggleMomentLike(momentID: String) async {
        guard let idx = moments.firstIndex(where: { $0.id == momentID }) else { return }
        let uid = currentUser?.id ?? "u_tokio"
        let isCurrentlyLiked = moments[idx].likedUserIDs.contains(uid)
        if isCurrentlyLiked {
            moments[idx].likedUserIDs.removeAll { $0 == uid }
        } else {
            moments[idx].likedUserIDs.append(uid)
        }
        let targetLiked = !isCurrentlyLiked

        guard !isDemoMode else { return }
        if let serverMoment = try? await apiClient.setMomentLike(momentID: momentID, isLiked: targetLiked),
           let sIdx = moments.firstIndex(where: { $0.id == momentID }) {
            moments[sIdx] = serverMoment
            saveSnapshotQuietly()
        }
    }

    public func addMomentComment(momentID: String, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = moments.firstIndex(where: { $0.id == momentID }) else { return }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let me = currentUser ?? CuvenUser(id: "u_tokio", username: "tokio", display: "Tokio")
        let optimistic = MomentComment(
            id: "mc_\(UUID().uuidString.prefix(8).lowercased())",
            authorID: me.id,
            authorDisplay: me.display,
            text: trimmed,
            createdAt: nowMs
        )
        moments[idx].comments.append(optimistic)

        guard !isDemoMode else { return }
        if let serverMoment = try? await apiClient.addMomentComment(momentID: momentID, text: trimmed),
           let sIdx = moments.firstIndex(where: { $0.id == momentID }) {
            moments[sIdx] = serverMoment
            saveSnapshotQuietly()
        }
    }

    public func deleteMoment(momentID: String) async {
        moments.removeAll { $0.id == momentID }
        saveSnapshotQuietly()
        guard !isDemoMode else { return }
        try? await apiClient.deleteMoment(momentID: momentID)
    }

    public func toggleStickerPackInstalled(packName: String) {
        let existingMatch = installedStickerPackNames.first {
            $0.caseInsensitiveCompare(packName) == .orderedSame
        }
        let shouldInstall: Bool
        if let existingMatch {
            installedStickerPackNames.remove(existingMatch)
            shouldInstall = false
        } else {
            installedStickerPackNames.insert(packName)
            shouldInstall = true
        }
        sessionStore.saveInstalledStickerPacks(installedStickerPackNames)
        saveSnapshotQuietly()

        guard !isDemoMode else { return }
        Task {
            if let serverSets = try? await apiClient.updateInstalledStickerPack(packName: packName, install: shouldInstall),
               !serverSets.isEmpty {
                installedStickerPackNames = Set(serverSets.map(\.name))
                sessionStore.saveInstalledStickerPacks(installedStickerPackNames)
            }
        }
    }

    // MARK: - AI Ghost Completion, Voice Dictation & Explain Streaming (`PROJECT.md § 5.2`)

    public func requestGhostSuggestion(for roomID: String, draft: String) async {
        guard prefs.smartAssistEnabled else {
            ghostSuggestionByRoom.removeValue(forKey: roomID)
            return
        }

        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if isDemoMode {
                let seed = DemoSeedFactory.makeDataset().ghostSuggestionByRoom[roomID]
                if let seed {
                    ghostSuggestionByRoom[roomID] = seed
                } else {
                    ghostSuggestionByRoom.removeValue(forKey: roomID)
                }
            } else {
                ghostSuggestionByRoom.removeValue(forKey: roomID)
            }
            return
        }

        if isDemoMode {
            ghostSuggestionByRoom[roomID] = synthesizeContextualCompletion(for: roomID, draft: draft)
            return
        }

        if let suggestion = try? await apiClient.fetchGhostSuggestion(roomID: roomID, draft: draft),
           !suggestion.isEmpty {
            ghostSuggestionByRoom[roomID] = suggestion
        } else {
            ghostSuggestionByRoom.removeValue(forKey: roomID)
        }
    }

    public func streamExplain(
        selectedText: String,
        context: String,
        followUp: String? = nil
    ) -> AsyncThrowingStream<String, Error> {
        let cleanSelection = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let demoActive = isDemoMode
        let streamClientRef = streamClient

        return AsyncThrowingStream { continuation in
            let task = Task {
                if demoActive {
                    let explanation = Self.buildLocalContextualExplanation(
                        selectedText: cleanSelection,
                        context: cleanContext,
                        followUp: followUp
                    )
                    let tokens = explanation.split(separator: " ", omittingEmptySubsequences: false)
                    for (idx, token) in tokens.enumerated() {
                        if Task.isCancelled { break }
                        let piece = idx == 0 ? String(token) : " \(token)"
                        continuation.yield(piece)
                        try? await Task.sleep(nanoseconds: 14_000_000)
                    }
                    continuation.finish()
                    return
                }

                do {
                    var yieldedAny = false
                    for try await event in streamClientRef.streamExplainEvents(
                        selectedText: cleanSelection,
                        context: cleanContext,
                        followUpQuestion: followUp
                    ) {
                        if Task.isCancelled { break }
                        switch event {
                        case .delta(let text) where !text.isEmpty:
                            yieldedAny = true
                            continuation.yield(text)
                        case .error(let message):
                            throw CuvenAPIError(message: message, statusCode: 500)
                        case .done:
                            continuation.finish()
                            return
                        default:
                            break
                        }
                    }
                    if !yieldedAny {
                        continuation.yield(
                            Self.buildLocalContextualExplanation(
                                selectedText: cleanSelection,
                                context: cleanContext,
                                followUp: followUp
                            )
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func streamExplainEvents(
        selectedText: String,
        context: String,
        followUp: String? = nil,
        history: [(question: String, answer: String)] = []
    ) -> AsyncThrowingStream<CuvenExplainStreamEvent, Error> {
        if !isDemoMode {
            return streamClient.streamExplainEvents(
                selectedText: selectedText,
                context: context,
                followUpQuestion: followUp,
                history: history
            )
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.stage("plan"))
                try? await Task.sleep(nanoseconds: 25_000_000)
                continuation.yield(.stage("answer"))
                let full = Self.buildLocalContextualExplanation(
                    selectedText: selectedText,
                    context: context,
                    followUp: followUp
                )
                for chunk in full.split(separator: " ") {
                    if Task.isCancelled { break }
                    continuation.yield(.delta("\(chunk) "))
                    try? await Task.sleep(nanoseconds: 12_000_000)
                }
                continuation.yield(.followups([
                    "How is “\(selectedText.prefix(24))” used in this conversation?",
                    "Give a quick reply suggestion"
                ]))
                continuation.yield(.done)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func transcribeWAV(_ wavData: Data) async throws -> String {
        guard !wavData.isEmpty else {
            throw CuvenAPIError(message: "Empty audio recording", statusCode: 400)
        }
        if !isDemoMode {
            return try await apiClient.transcribeAudioWAV(wavData)
        }
        // Offline / Simulator demo dictation derived from recorded WAV byte length
        let seconds = max(0.5, Double(max(0, wavData.count - 44)) / 32_000.0)
        if seconds >= 3.0 {
            return "On my way to the courtyard now — see you in ten minutes."
        }
        return "Sounds great, see you soon!"
    }

    public func clearAIMemory() async {
        aiMemories = []
        aiRoutineBuckets = (0..<24).map { AIRoutineHourBucket(hour: $0, activityScore: 0) }
        saveSnapshotQuietly()
        guard !isDemoMode else { return }
        try? await apiClient.clearAIMemory()
    }

    // MARK: - Calls & Velocity-Projected PiP (`PROJECT.md § 5.2`)

    public func startCall(in roomID: String, mediaKind: CallMediaKind) {
        let room = rooms.first { $0.id == roomID }
        let peerDisplay = room?.title ?? "Cuven Call"
        let peerAvatar = room?.avatarURL
        let callID = "call_\(UUID().uuidString.prefix(10).lowercased())"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        activeCall = CallSession(
            id: callID,
            roomID: roomID,
            peerDisplay: peerDisplay,
            peerAvatarURL: peerAvatar,
            mediaKind: mediaKind,
            phase: .outgoingRinging,
            isMuted: false,
            isCameraEnabled: mediaKind == .video,
            isSpeakerEnabled: true,
            isMinimizedPiP: false,
            startedAt: nil
        )

        if isDemoMode {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard let self, self.activeCall?.id == callID else { return }
                self.activeCall?.phase = .connected
                self.activeCall?.startedAt = nowMs + 450
            }
            return
        }

        Task {
            await webSocketClient.send(.call(payload: [
                "op": .string("invite"),
                "callId": .string(callID),
                "room": .string(roomID),
                "video": .bool(mediaKind == .video)
            ]))
        }
    }

    /// Peer-compatible parameter alias (`AdaptiveActionBars.swift:603,610`).
    public func startCall(in roomID: String, kind: CallMediaKind) {
        startCall(in: roomID, mediaKind: kind)
    }

    public func simulateIncomingCall(in roomID: String, mediaKind: CallMediaKind = .video) {
        let room = rooms.first { $0.id == roomID }
        activeCall = CallSession(
            id: "call_in_\(UUID().uuidString.prefix(8).lowercased())",
            roomID: roomID,
            peerDisplay: room?.title ?? "Incoming Call",
            peerAvatarURL: room?.avatarURL,
            mediaKind: mediaKind,
            phase: .incomingRinging,
            isMuted: false,
            isCameraEnabled: mediaKind == .video,
            isSpeakerEnabled: true,
            isMinimizedPiP: false,
            startedAt: nil
        )
    }

    public func acceptIncomingCall() {
        guard var call = activeCall else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        call.phase = .connected
        call.startedAt = call.startedAt ?? nowMs
        activeCall = call

        guard !isDemoMode else { return }
        Task {
            await webSocketClient.send(.call(payload: [
                "op": .string("accept"),
                "callId": .string(call.id),
                "room": .string(call.roomID)
            ]))
        }
    }

    public func endActiveCall() {
        guard let ended = activeCall else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let durationSec: Double? = ended.startedAt.map { max(1.0, Double(nowMs - $0) / 1000.0) }
        activeCall = nil

        let summaryText: String
        if let durationSec {
            let mins = Int(durationSec) / 60
            let secs = Int(durationSec) % 60
            summaryText = "\(ended.mediaKind == .video ? "Video" : "Voice") call · \(String(format: "%d:%02d", mins, secs))"
        } else {
            summaryText = "\(ended.mediaKind == .video ? "Video" : "Voice") call ended"
        }

        let callLogMessage = Message(
            id: "callmsg_\(ended.id)",
            roomID: ended.roomID,
            senderID: currentUser?.id ?? "u_tokio",
            senderDisplay: currentUser?.display ?? "You",
            kind: .call,
            text: summaryText,
            durationSeconds: durationSec,
            deliveryState: .sent,
            createdAt: nowMs
        )
        upsertMessage(callLogMessage, in: ended.roomID)
        updateRoomSummary(roomID: ended.roomID, preview: "[Call] \(summaryText)", timestampMs: nowMs)

        guard !isDemoMode else { return }
        Task {
            await webSocketClient.send(.call(payload: [
                "op": .string("hangup"),
                "callId": .string(ended.id),
                "room": .string(ended.roomID)
            ]))
        }
    }

    /// Peer-compatible alias (`CallOverlayContainerView.swift`) ending or declining the active/ringing call.
    public func endOrDeclineCall() {
        endActiveCall()
    }

    public func toggleCallMute() {
        activeCall?.isMuted.toggle()
    }

    public func toggleCallCamera() {
        guard var call = activeCall else { return }
        call.isCameraEnabled.toggle()
        if call.isCameraEnabled {
            call.mediaKind = .video
        }
        activeCall = call
    }

    public func toggleCallSpeaker() {
        activeCall?.isSpeakerEnabled.toggle()
    }

    public func setCallMinimizedPiP(_ minimized: Bool) {
        activeCall?.isMinimizedPiP = minimized
    }

    public func sendCallSignal(_ payload: [String: CuvenJSONValue]) async {
        guard !isDemoMode else { return }
        await webSocketClient.send(.call(payload: payload))
    }

    // MARK: - Profile & Preferences (`PROJECT.md § 5.2`)

    public func updateProfile(
        display: String,
        bio: String,
        avatarData: Data?,
        coverData: Data?,
        dominantTintHex: String?
    ) async {
        let trimmedDisplay = display.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBio = bio.trimmingCharacters(in: .whitespacesAndNewlines)

        var nextAvatarURL = currentUser?.avatarURL
        var nextCoverURL = currentUser?.coverURL

        if let avatarData, !avatarData.isEmpty {
            if let oldAvatar = currentUser?.avatarURL, !oldAvatar.isEmpty {
                recentAvatarURLs.removeAll { $0 == oldAvatar }
                recentAvatarURLs.insert(oldAvatar, at: 0)
                if recentAvatarURLs.count > 8 {
                    recentAvatarURLs = Array(recentAvatarURLs.prefix(8))
                }
            }

            if !isDemoMode,
               let uploaded = try? await apiClient.uploadMedia(
                   data: avatarData,
                   contentType: "image/png",
                   kind: "avatar",
                   width: 512,
                   height: 512
               ),
               !uploaded.url.isEmpty {
                nextAvatarURL = uploaded.url
                if let img = AuthenticatedMediaLoader.decodeImage(from: avatarData, maxPixelDimension: 512) {
                    mediaLoader.storeImage(img, for: uploaded.url, rawData: avatarData)
                }
            } else if let localFile = mediaLoader.persistLocalMediaFile(avatarData, fileExtension: "png") {
                nextAvatarURL = localFile.absoluteString
            }
        }

        if let coverData, !coverData.isEmpty {
            if !isDemoMode,
               let uploaded = try? await apiClient.uploadMedia(
                   data: coverData,
                   contentType: "image/jpeg",
                   kind: "cover",
                   width: 1200,
                   height: 600
               ),
               !uploaded.url.isEmpty {
                nextCoverURL = uploaded.url
                if let img = AuthenticatedMediaLoader.decodeImage(from: coverData, maxPixelDimension: 1600) {
                    mediaLoader.storeImage(img, for: uploaded.url, rawData: coverData)
                }
            } else if let localFile = mediaLoader.persistLocalMediaFile(coverData, fileExtension: "jpg") {
                nextCoverURL = localFile.absoluteString
            }
        }

        if var user = currentUser {
            if !trimmedDisplay.isEmpty {
                user.display = trimmedDisplay
            }
            user.bio = trimmedBio
            user.avatarURL = nextAvatarURL
            user.coverURL = nextCoverURL
            if let dominantTintHex {
                user.dominantTintHex = dominantTintHex
                sessionStore.saveDominantTintHex(dominantTintHex)
            }
            currentUser = user
            if var note = myNote {
                note.userDisplay = user.display
                note.avatarURL = user.avatarURL
                myNote = note
            }
        }

        guard !isDemoMode else { return }
        if let serverUser = try? await apiClient.updateProfile(
            display: trimmedDisplay.isEmpty ? nil : trimmedDisplay,
            bio: trimmedBio,
            avatarPath: nextAvatarURL,
            coverValue: nextCoverURL
        ) {
            var merged = serverUser
            merged.dominantTintHex = dominantTintHex ?? currentUser?.dominantTintHex
            merged.isOnline = true
            currentUser = merged
            if let avatars = try? await apiClient.fetchRecentAvatars(), !avatars.isEmpty {
                recentAvatarURLs = avatars
            }
        }
        saveSnapshotQuietly()
    }

    public func updatePreferences(_ newPrefs: UserPrefs) async {
        let routineChanged = (prefs.routineLearningEnabled != newPrefs.routineLearningEnabled)
        prefs = newPrefs
        sessionStore.saveUserPrefs(newPrefs)
        saveSnapshotQuietly()

        guard !isDemoMode else { return }
        if routineChanged {
            try? await apiClient.setRoutineLearning(enabled: newPrefs.routineLearningEnabled)
        }
        try? await apiClient.syncPreferences(newPrefs, roomBackdrops: currentRoomBackdropsMap())
    }

    public func changePassword(current: String, next: String) async throws {
        guard !current.isEmpty else {
            throw CuvenAPIError(message: "Current password is required.", statusCode: 400)
        }
        guard next.count >= 6 else {
            throw CuvenAPIError(message: "New password must be at least 6 characters.", statusCode: 400)
        }
        guard !isDemoMode else { return }
        try await apiClient.changePassword(current: current, next: next)
    }

    // MARK: - Private Infrastructure, Realtime Events & BootCache Helpers

    private func wireInfrastructureCallbacksIfNeeded() async {
        let storeURL = serverBaseURL
        let sessionStoreRef = sessionStore

        await apiClient.setSessionTokenObserver { newToken in
            sessionStoreRef.saveSessionToken(newToken, for: storeURL)
        }

        await apiClient.setUnauthorizedHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isDemoMode else { return }
                await self.signOut()
            }
        }

        guard !didConnectOutbox else { return }
        didConnectOutbox = true

        let blobStoreRef = blobStore
        let apiClientRef = apiClient

        let deps = PersistentOutbox.Dependencies(
            loadBlob: { cid in
                blobStoreRef.get(cid: cid)
            },
            deleteBlob: { cid in
                blobStoreRef.delete(cid: cid)
            },
            uploadMedia: { entry, data in
                let media = entry.media ?? OutboxMediaDescriptor(
                    kind: "image",
                    contentType: "application/octet-stream",
                    fileName: "\(entry.cid).bin"
                )
                let uploaded = try await apiClientRef.uploadMedia(
                    data: data,
                    contentType: media.contentType,
                    kind: media.kind,
                    roomID: entry.roomID,
                    localID: entry.cid,
                    width: media.width,
                    height: media.height,
                    durationSeconds: media.durationSeconds,
                    fileName: media.fileName
                )
                var meta: [String: CuvenJSONValue] = [:]
                if let w = uploaded.width { meta["w"] = .int(Int64(w)) }
                if let h = uploaded.height { meta["h"] = .int(Int64(h)) }
                if let dur = uploaded.durationSeconds { meta["dur"] = .double(dur) }
                return OutboxUploadedAsset(url: uploaded.url, meta: meta)
            },
            postMessage: { payload in
                let lookup = await MainActor.run { [weak self] in
                    self?.buildDisplayLookup() ?? [:]
                }
                return try await apiClientRef.postMessage(payload: payload, displayLookup: lookup)
            },
            onLanded: { [weak self] entry, serverMessage in
                await MainActor.run {
                    self?.reconcileLandedMessage(entry: entry, serverMessage: serverMessage)
                }
            },
            onFailed: { [weak self] entry, error in
                await MainActor.run {
                    self?.markOptimisticMessageState(cid: entry.cid, roomID: entry.roomID, state: .failed)
                    self?.activeBannerMessage = error.message
                }
            },
            onWaiting: { [weak self] entry, _ in
                await MainActor.run {
                    self?.markOptimisticMessageState(cid: entry.cid, roomID: entry.roomID, state: .queued)
                }
            },
            onRestore: { [weak self] entries in
                await MainActor.run {
                    guard let self, !self.isDemoMode else { return }
                    for entry in entries {
                        if var optimistic = entry.optimisticMessage {
                            optimistic.deliveryState = entry.isFailed ? .failed : .queued
                            self.upsertMessage(optimistic, in: entry.roomID)
                        }
                    }
                }
            }
        )
        await outbox.connect(deps)
    }

    private func refreshAllAuthenticatedData() async {
        do {
            let boot = try await apiClient.fetchBootstrap(basePrefs: prefs)
            currentUser = mergeLocalTintIfNeeded(into: boot.me)
            rooms = sortRooms(boot.rooms)
            contacts = boot.contacts
            prefs = boot.prefs
            sessionStore.saveUserPrefs(prefs)
            if selectedRoomID == nil {
                selectedRoomID = rooms.first(where: { !$0.isHidden })?.id
            }

            let onlineSet = boot.onlineUserIDs
            let meSnapshot = currentUser

            async let notesTask = try? apiClient.fetchNotes(currentUser: meSnapshot)
            async let momentsTask = try? apiClient.fetchMoments(onlineIDs: onlineSet)
            async let memoriesTask = try? apiClient.fetchMemories()
            async let stickersTask = try? apiClient.fetchStickerPacks()
            async let peopleTask = try? apiClient.fetchPeople(onlineIDs: onlineSet)
            async let insightsTask = try? apiClient.fetchInsights()
            async let aiMemTask = try? apiClient.fetchAIMemory()
            async let avatarsTask = try? apiClient.fetchRecentAvatars()

            if let fetchedNotes = await notesTask {
                myNote = fetchedNotes.mine
                notes = fetchedNotes.friends
            }
            if let fetchedMoments = await momentsTask {
                moments = fetchedMoments
            }
            if let fetchedMemories = await memoriesTask {
                memories = fetchedMemories
            }
            if let fetchedStickers = await stickersTask, !fetchedStickers.isEmpty {
                stickerPacks = fetchedStickers
                installedStickerPackNames = Set(fetchedStickers.map(\.name))
            } else if stickerPacks.isEmpty {
                stickerPacks = DemoSeedFactory.buildStickerPacks()
            }
            if let fetchedPeople = await peopleTask {
                suggestedPeople = fetchedPeople.suggested + fetchedPeople.discover
            }
            if let fetchedInsights = await insightsTask {
                insightsByRoom = fetchedInsights
            }
            if let fetchedAI = await aiMemTask {
                aiMemories = fetchedAI.memories
                aiRoutineBuckets = fetchedAI.routineBuckets
            }
            if let fetchedAvatars = await avatarsTask {
                recentAvatarURLs = fetchedAvatars
            }

            if let activeRoom = selectedRoomID {
                await loadMessagesIfNeeded(for: activeRoom)
            }
            saveSnapshotQuietly()
        } catch {
            // Keep existing state if transient network failure occurs
        }
    }

    private func loadMessagesIfNeeded(for roomID: String) async {
        guard !isDemoMode, !roomID.isEmpty else { return }
        if let fetched = try? await apiClient.fetchMessages(
            roomID: roomID,
            limit: 60,
            displayLookup: buildDisplayLookup()
        ) {
            for message in fetched {
                upsertMessage(message, in: roomID)
            }
            saveSnapshotQuietly()
        }
    }

    private func startRealtimeSocket() {
        guard !isDemoMode else { return }
        Task {
            await webSocketClient.start(
                onEvent: { [weak self] event in
                    Task { @MainActor [weak self] in
                        await self?.handleSocketEvent(event)
                    }
                },
                onConnectionStateChange: { [weak self] connected in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.isWebSocketConnected = connected
                        if connected {
                            await self.outbox.resume()
                        }
                    }
                }
            )
        }
    }

    private func handleSocketEvent(_ event: CuvenServerSocketEvent) async {
        switch event {
        case .hello(let me, let onlineIDs):
            if let me {
                currentUser = mergeLocalTintIfNeeded(into: me)
            }
            let onlineSet = Set(onlineIDs)
            for idx in contacts.indices {
                contacts[idx].user.isOnline = onlineSet.contains(contacts[idx].user.id)
            }

        case .pong:
            break

        case .message(let rawMsg, let localID):
            guard let mapped = CuvenWireMapper.mapMessage(
                rawMsg,
                localIDOverride: localID,
                displayLookup: buildDisplayLookup()
            ) else { return }
            upsertMessage(mapped, in: mapped.roomID)
            typingPreviewByRoom.removeValue(forKey: mapped.roomID)
            let preview = CuvenWireMapper.previewText(forWireMessage: rawMsg)
            updateRoomSummary(roomID: mapped.roomID, preview: preview, timestampMs: mapped.createdAt)
            if mapped.senderID != currentUser?.id && selectedRoomID != mapped.roomID {
                if let rIdx = rooms.firstIndex(where: { $0.id == mapped.roomID }) {
                    rooms[rIdx].unreadCount += 1
                    if !rooms[rIdx].isMuted {
                        activeBannerMessage = "\(mapped.senderDisplay): \(preview)"
                    }
                }
            }
            saveSnapshotQuietly()

        case .readReceipt(let roomID, let userID, let timestampMs, _):
            guard userID != currentUser?.id,
                  var list = messagesByRoom[roomID] else { return }
            for i in list.indices where list[i].senderID == currentUser?.id && list[i].createdAt <= timestampMs {
                if list[i].deliveryState != .revoked {
                    list[i].deliveryState = .read
                }
            }
            messagesByRoom[roomID] = list

        case .highlightedKeys(let messageID, let roomID, let keywords):
            guard var list = messagesByRoom[roomID],
                  let idx = list.firstIndex(where: { $0.id == messageID }) else { return }
            list[idx].highlightedKeywords = keywords
            messagesByRoom[roomID] = list

        case .messageEdited(let rawMsg), .reactionUpdated(let rawMsg):
            guard let mapped = CuvenWireMapper.mapMessage(rawMsg, displayLookup: buildDisplayLookup()) else { return }
            upsertMessage(mapped, in: mapped.roomID)

        case .presence(let userID, let isOnline):
            for idx in contacts.indices where contacts[idx].user.id == userID {
                contacts[idx].user.isOnline = isOnline
            }
            for idx in suggestedPeople.indices where suggestedPeople[idx].id == userID {
                suggestedPeople[idx].isOnline = isOnline
            }

        case .typing(let roomID, let userID, let previewText):
            guard userID != currentUser?.id else { return }
            typingClearTasks[roomID]?.cancel()
            if previewText.isEmpty {
                typingPreviewByRoom.removeValue(forKey: roomID)
            } else {
                typingPreviewByRoom[roomID] = previewText
                typingClearTasks[roomID] = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.typingPreviewByRoom.removeValue(forKey: roomID)
                }
            }

        case .profileUpdated(let user):
            if user.id == currentUser?.id {
                currentUser = mergeLocalTintIfNeeded(into: user)
            }
            for idx in contacts.indices where contacts[idx].user.id == user.id {
                contacts[idx].user = user
            }

        case .prefsUpdated(let rawPrefs):
            let (merged, roomBackdrops) = CuvenWireMapper.mergeServerPrefs(rawPrefs, into: prefs)
            prefs = merged
            for idx in rooms.indices {
                if let preset = roomBackdrops[rooms[idx].id] {
                    rooms[idx].backdrop = preset
                }
            }

        case .roomsDirty:
            if let freshRooms = try? await apiClient.fetchRooms(roomBackdrops: currentRoomBackdropsMap()) {
                rooms = sortRooms(freshRooms)
            }

        case .contactsDirty:
            let onlineIDs = Set(contacts.filter(\.user.isOnline).map(\.user.id))
            if let freshContacts = try? await apiClient.fetchContacts(onlineIDs: onlineIDs) {
                contacts = freshContacts
            }

        case .noteUpdated:
            if let freshNotes = try? await apiClient.fetchNotes(currentUser: currentUser) {
                myNote = freshNotes.mine
                notes = freshNotes.friends
            }

        case .callSignal(let rawPayload):
            lastCallSignalPayload = rawPayload
            let op = rawPayload["op"]?.stringValue ?? ""
            let callID = rawPayload["callId"]?.stringValue ?? ""
            let roomID = rawPayload["room"]?.stringValue ?? ""
            if op == "invite", activeCall == nil, !roomID.isEmpty {
                let isVideo = rawPayload["video"]?.boolValue ?? false
                let room = rooms.first { $0.id == roomID }
                activeCall = CallSession(
                    id: callID.isEmpty ? "call_\(UUID().uuidString.prefix(8))" : callID,
                    roomID: roomID,
                    peerDisplay: room?.title ?? "Incoming Call",
                    peerAvatarURL: room?.avatarURL,
                    mediaKind: isVideo ? .video : .audio,
                    phase: .incomingRinging,
                    isCameraEnabled: isVideo
                )
            } else if op == "accept", activeCall?.id == callID {
                activeCall?.phase = .connected
                activeCall?.startedAt = activeCall?.startedAt ?? Int64(Date().timeIntervalSince1970 * 1000)
            } else if op == "hangup" || op == "decline" || op == "busy" {
                if activeCall?.id == callID || callID.isEmpty {
                    activeCall = nil
                }
            }

        case .momentCreated, .momentChanged:
            let onlineIDs = Set(contacts.filter(\.user.isOnline).map(\.user.id))
            if let freshMoments = try? await apiClient.fetchMoments(onlineIDs: onlineIDs) {
                moments = freshMoments
            }

        case .momentDeleted(let momentID):
            moments.removeAll { $0.id == momentID }

        case .unknown:
            break
        }
    }

    // MARK: - Deterministic Helpers

    private func reconcileLandedMessage(entry: OutboxEntry, serverMessage: Message) {
        var list = messagesByRoom[entry.roomID] ?? []
        if let idx = list.firstIndex(where: { $0.localID == entry.cid || $0.id == entry.cid || $0.id == serverMessage.id }) {
            var merged = serverMessage
            merged.localID = entry.cid
            list[idx] = merged
        } else {
            list.append(serverMessage)
        }
        list.sort { $0.createdAt < $1.createdAt }
        messagesByRoom[entry.roomID] = list
        saveSnapshotQuietly()
    }

    private func markOptimisticMessageState(cid: String, roomID: String, state: MessageDeliveryState) {
        guard var list = messagesByRoom[roomID],
              let idx = list.firstIndex(where: { $0.localID == cid || $0.id == cid }) else {
            return
        }
        list[idx].deliveryState = state
        messagesByRoom[roomID] = list
    }

    private func upsertMessage(_ message: Message, in roomID: String) {
        var list = messagesByRoom[roomID] ?? []
        if let idx = list.firstIndex(where: {
            $0.id == message.id ||
            (message.localID != nil && ($0.localID == message.localID || $0.id == message.localID))
        }) {
            list[idx] = message
        } else {
            list.append(message)
        }
        list.sort { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id < rhs.id
        }
        messagesByRoom[roomID] = list
    }

    private func upsertRoom(_ room: Room) {
        if let idx = rooms.firstIndex(where: { $0.id == room.id }) {
            rooms[idx] = room
        } else {
            rooms.insert(room, at: 0)
        }
        rooms = sortRooms(rooms)
    }

    private func updateRoomSummary(roomID: String, preview: String, timestampMs: Int64) {
        guard let idx = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        rooms[idx].lastMessagePreview = preview
        rooms[idx].lastMessageTimestamp = max(rooms[idx].lastMessageTimestamp, timestampMs)
        rooms[idx].isHidden = false
        rooms = sortRooms(rooms)
    }

    private func sortRooms(_ input: [Room]) -> [Room] {
        input.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            if lhs.lastMessageTimestamp != rhs.lastMessageTimestamp {
                return lhs.lastMessageTimestamp > rhs.lastMessageTimestamp
            }
            return lhs.id < rhs.id
        }
    }

    private func scheduleDemoDeliveryProgression(messageID: String, in roomID: String) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard let self,
                  var list = self.messagesByRoom[roomID],
                  let idx = list.firstIndex(where: { $0.id == messageID }),
                  list[idx].deliveryState != .revoked else { return }
            list[idx].deliveryState = .read
            self.messagesByRoom[roomID] = list
        }
    }

    private func recordLocalRoutineActivity(at date: Date) {
        guard prefs.routineLearningEnabled else { return }
        let hour = Calendar.current.component(.hour, from: date)
        if let idx = aiRoutineBuckets.firstIndex(where: { $0.hour == hour }) {
            aiRoutineBuckets[idx].activityScore = min(1.0, aiRoutineBuckets[idx].activityScore + 0.08)
        }
    }

    private func extractMentionedUserIDs(in text: String) -> [String] {
        guard text.contains("@") else { return [] }
        let lower = text.lowercased()
        var found: [String] = []
        for item in contacts {
            let u = item.user
            if lower.contains("@\(u.username.lowercased())") || lower.contains("@\(u.display.lowercased())") {
                found.append(u.id)
            }
        }
        return Array(Set(found))
    }

    private func buildDisplayLookup() -> [String: String] {
        var map: [String: String] = [:]
        if let me = currentUser {
            map[me.id] = me.display
        }
        for c in contacts {
            map[c.user.id] = c.user.display
        }
        for p in suggestedPeople {
            map[p.id] = p.display
        }
        return map
    }

    private func currentRoomBackdropsMap() -> [String: BackdropPreset] {
        var map: [String: BackdropPreset] = [:]
        for r in rooms {
            if let b = r.backdrop {
                map[r.id] = b
            }
        }
        return map
    }

    private func mergeLocalTintIfNeeded(into user: CuvenUser) -> CuvenUser {
        var copy = user
        if copy.dominantTintHex == nil, let savedHex = sessionStore.loadDominantTintHex() {
            copy.dominantTintHex = savedHex
        }
        return copy
    }

    private func applyBootSnapshot(_ snapshot: BootSnapshot) {
        currentUser = snapshot.currentUser
        if currentUser != nil {
            isAuthenticated = true
        }
        rooms = sortRooms(snapshot.rooms)
        messagesByRoom = snapshot.messagesByRoom
        contacts = snapshot.contacts
        suggestedPeople = snapshot.suggestedPeople
        notes = snapshot.notes
        myNote = snapshot.myNote
        moments = snapshot.moments
        memories = snapshot.memories
        stickerPacks = snapshot.stickerPacks.isEmpty ? DemoSeedFactory.buildStickerPacks() : snapshot.stickerPacks
        if !snapshot.installedStickerPackNames.isEmpty {
            installedStickerPackNames = Set(snapshot.installedStickerPackNames)
        }
        insightsByRoom = snapshot.insightsByRoom
        prefs = snapshot.prefs
        if !snapshot.aiMemories.isEmpty {
            aiMemories = snapshot.aiMemories
        }
        if snapshot.aiRoutineBuckets.count == 24 {
            aiRoutineBuckets = snapshot.aiRoutineBuckets
        }
        recentAvatarURLs = snapshot.recentAvatarURLs
        selectedRoomID = rooms.first(where: { !$0.isHidden })?.id
    }

    private func saveSnapshotQuietly() {
        guard !isDemoMode, isAuthenticated else { return }
        let snapshot = BootSnapshot(
            serverBaseURLString: serverBaseURL.absoluteString,
            currentUser: currentUser,
            rooms: rooms,
            messagesByRoom: messagesByRoom,
            contacts: contacts,
            suggestedPeople: suggestedPeople,
            notes: notes,
            myNote: myNote,
            moments: moments,
            memories: memories,
            stickerPacks: stickerPacks,
            installedStickerPackNames: Array(installedStickerPackNames),
            insightsByRoom: insightsByRoom,
            prefs: prefs,
            aiMemories: aiMemories,
            aiRoutineBuckets: aiRoutineBuckets,
            recentAvatarURLs: recentAvatarURLs
        )
        try? bootCache.save(snapshot)
    }

    private func synthesizeContextualCompletion(for roomID: String, draft: String) -> String {
        let lower = draft.lowercased()
        let trailingSpace = draft.hasSuffix(" ") ? "" : " "
        if lower.contains("see you") {
            return "\(trailingSpace)at 3:30 by the courtyard!"
        }
        if lower.contains("coffee") || lower.contains("espresso") {
            return "\(trailingSpace)at the West Lake studio?"
        }
        if lower.contains("on my") {
            return "\(trailingSpace)way right now — be there in 10!"
        }
        let roomTitle = rooms.first(where: { $0.id == roomID })?.title ?? "soon"
        return "\(trailingSpace)— sounds great, talk \(roomTitle == "Design Team" ? "soon" : "with you soon")!"
    }

    private static func buildLocalContextualExplanation(
        selectedText: String,
        context: String,
        followUp: String?
    ) -> String {
        let focus = selectedText.isEmpty ? "this phrase" : "“\(selectedText)”"
        if let followUp, !followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Regarding \(focus) (\(followUp)): in this conversation context, it refers directly to the shared schedule and location details mentioned in the thread (\(String(context.prefix(120))))."
        }
        let lower = selectedText.lowercased()
        if lower.contains("west lake") || lower.contains("hangzhou") || lower.contains("longjing") {
            return "\(focus) refers to Hangzhou's historic West Lake and Longjing tea hills — here used as the meetup landmark for afternoon coffee and weekend ridge walks."
        }
        if lower.contains("525pt") || lower.contains("duorail") || lower.contains("clarinetta") {
            return "\(focus) is part of Cuven's spatial typography and iPhone Duo layout vocabulary — preserving a constant 525pt conversation column across split transitions."
        }
        return "In this conversation, \(focus) highlights a key detail within the surrounding message context: \(String(context.prefix(140)))."
    }

    private static func fileExtension(for mimeType: String, kind: MessageKind) -> String {
        let lower = mimeType.lowercased()
        if lower.contains("png") || kind == .drawing { return "png" }
        if lower.contains("webp") { return "webp" }
        if lower.contains("wav") || kind == .voice { return "wav" }
        if lower.contains("mp4") || kind == .video { return "mp4" }
        return "jpg"
    }
}

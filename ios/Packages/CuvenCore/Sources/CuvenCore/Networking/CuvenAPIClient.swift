import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Pluggable HTTP Transport & CuvenAPIClient (https://wechat.cuven.us)

public protocol CuvenHTTPTransport: Sendable {
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPTransport: CuvenHTTPTransport {
    public init() {}

    public func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        #if canImport(FoundationNetworking)
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: CuvenAPIError(message: error.localizedDescription, statusCode: 0))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: CuvenAPIError(message: "Invalid HTTP response", statusCode: 0))
                    return
                }
                continuation.resume(returning: (data ?? Data(), http))
            }
            task.resume()
        }
        #else
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CuvenAPIError(message: "Invalid HTTP response", statusCode: 0)
            }
            return (data, http)
        } catch let apiError as CuvenAPIError {
            throw apiError
        } catch {
            throw CuvenAPIError(message: error.localizedDescription, statusCode: 0)
        }
        #endif
    }
}

public struct CuvenAuthStatusResponse: Sendable {
    public let configured: Bool
    public let needsInviteCode: Bool
    public let isAuthenticated: Bool
    public let user: CuvenUser?

    public init(configured: Bool, needsInviteCode: Bool, isAuthenticated: Bool, user: CuvenUser?) {
        self.configured = configured
        self.needsInviteCode = needsInviteCode
        self.isAuthenticated = isAuthenticated
        self.user = user
    }
}

public struct CuvenBootstrapPayload: Sendable {
    public let me: CuvenUser
    public let rooms: [Room]
    public let contacts: [ContactItem]
    public let onlineUserIDs: Set<String>
    public let callsEnabled: Bool
    public let assistEnabled: Bool
    public let stickersEnabled: Bool
    public let prefs: UserPrefs

    public init(
        me: CuvenUser,
        rooms: [Room],
        contacts: [ContactItem],
        onlineUserIDs: Set<String>,
        callsEnabled: Bool,
        assistEnabled: Bool,
        stickersEnabled: Bool,
        prefs: UserPrefs
    ) {
        self.me = me
        self.rooms = rooms
        self.contacts = contacts
        self.onlineUserIDs = onlineUserIDs
        self.callsEnabled = callsEnabled
        self.assistEnabled = assistEnabled
        self.stickersEnabled = stickersEnabled
        self.prefs = prefs
    }
}

public struct CuvenMediaUploadResult: Codable, Equatable, Sendable {
    public let key: String
    public let url: String
    public let width: Int?
    public let height: Int?
    public let durationSeconds: Double?

    public init(key: String, url: String, width: Int? = nil, height: Int? = nil, durationSeconds: Double? = nil) {
        self.key = key
        self.url = url
        self.width = width
        self.height = height
        self.durationSeconds = durationSeconds
    }
}

public actor CuvenAPIClient {
    public private(set) var baseURL: URL
    public private(set) var sessionToken: String?
    public var timeZone: TimeZone
    private let transport: CuvenHTTPTransport
    private var unauthorizedHandler: (@Sendable () -> Void)?
    private var sessionTokenObserver: (@Sendable (String?) -> Void)?

    public init(
        baseURL: URL = URL(string: "https://wechat.cuven.us")!,
        sessionToken: String? = nil,
        timeZone: TimeZone = .current,
        transport: CuvenHTTPTransport = URLSessionHTTPTransport()
    ) {
        self.baseURL = baseURL
        self.sessionToken = sessionToken
        self.timeZone = timeZone
        self.transport = transport
    }

    public func setBaseURL(_ url: URL) {
        self.baseURL = url
    }

    public func setSessionToken(_ token: String?) {
        self.sessionToken = token
    }

    public func setUnauthorizedHandler(_ handler: (@Sendable () -> Void)?) {
        self.unauthorizedHandler = handler
    }

    public func setSessionTokenObserver(_ observer: (@Sendable (String?) -> Void)?) {
        self.sessionTokenObserver = observer
    }

    public func buildRequest(
        method: String,
        path: String,
        contentType: String? = nil,
        additionalHeaders: [String: String] = [:],
        body: Data? = nil
    ) throws -> URLRequest {
        try CuvenRequestBuilder.makeHTTPRequest(
            method: method,
            path: path,
            baseURL: baseURL,
            sessionToken: sessionToken,
            timeZone: timeZone,
            contentType: contentType,
            additionalHeaders: additionalHeaders,
            body: body
        )
    }

    public func buildWebSocketRequest() throws -> URLRequest {
        try CuvenRequestBuilder.makeWebSocketRequest(
            baseURL: baseURL,
            sessionToken: sessionToken,
            timeZone: timeZone
        )
    }

    public func performRawRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await transport.execute(request)
        if let cookieUpdate = CuvenRequestBuilder.extractSessionCookie(from: response) {
            switch cookieUpdate {
            case .set(let newToken):
                self.sessionToken = newToken
                self.sessionTokenObserver?(newToken)
            case .cleared:
                self.sessionToken = nil
                self.sessionTokenObserver?(nil)
            }
        }
        return (data, response)
    }

    @discardableResult
    public func requestJSON(
        method: String,
        path: String,
        payload: [String: CuvenJSONValue]? = nil
    ) async throws -> [String: CuvenJSONValue] {
        let bodyData: Data?
        if let payload {
            bodyData = try JSONEncoder().encode(payload)
        } else if method.uppercased() == "POST" || method.uppercased() == "PUT" {
            bodyData = Data("{}".utf8)
        } else {
            bodyData = nil
        }

        let request = try buildRequest(
            method: method,
            path: path,
            contentType: bodyData != nil ? "application/json" : nil,
            body: bodyData
        )
        let (data, response) = try await performRawRequest(request)
        let parsed = (try? JSONDecoder().decode([String: CuvenJSONValue].self, from: data)) ?? [:]

        if response.statusCode == 401 && path.hasPrefix("/api/") {
            unauthorizedHandler?()
        }

        let okFlag = parsed["ok"]?.boolValue ?? (200..<300).contains(response.statusCode)
        if !(200..<300).contains(response.statusCode) || !okFlag {
            let errText = parsed["error"]?.stringValue ?? "Request failed (\(response.statusCode))"
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw CuvenAPIError(message: errText, statusCode: response.statusCode, retryAfterSeconds: retryAfter)
        }
        return parsed
    }

    // MARK: - Auth Endpoints (/auth/*)

    public func fetchAuthStatus() async throws -> CuvenAuthStatusResponse {
        let res = try await requestJSON(method: "GET", path: "/auth/status")
        let configured = res["configured"]?.boolValue ?? true
        let needsCode = res["needsCode"]?.boolValue ?? false
        let authed = res["authed"]?.boolValue ?? false
        let user = res["me"]?.objectValue.flatMap { CuvenWireMapper.mapUser($0) }
        return CuvenAuthStatusResponse(
            configured: configured,
            needsInviteCode: needsCode,
            isAuthenticated: authed,
            user: user
        )
    }

    public func login(username: String, password: String) async throws -> CuvenUser {
        let res = try await requestJSON(
            method: "POST",
            path: "/auth/login",
            payload: [
                "username": .string(username.trimmingCharacters(in: .whitespacesAndNewlines)),
                "password": .string(password)
            ]
        )
        guard let meObj = res["me"]?.objectValue,
              let user = CuvenWireMapper.mapUser(meObj, onlineSet: [meObj["id"]?.stringValue ?? ""]) else {
            throw CuvenAPIError(message: "Invalid user profile returned", statusCode: 500)
        }
        return user
    }

    public func register(username: String, password: String, display: String, inviteCode: String?) async throws -> CuvenUser {
        var payload: [String: CuvenJSONValue] = [
            "username": .string(username.trimmingCharacters(in: .whitespacesAndNewlines)),
            "password": .string(password),
            "display": .string(display.trimmingCharacters(in: .whitespacesAndNewlines))
        ]
        if let code = inviteCode?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty {
            payload["code"] = .string(code)
        }
        let res = try await requestJSON(method: "POST", path: "/auth/register", payload: payload)
        guard let meObj = res["me"]?.objectValue,
              let user = CuvenWireMapper.mapUser(meObj, onlineSet: [meObj["id"]?.stringValue ?? ""]) else {
            throw CuvenAPIError(message: "Invalid user profile returned", statusCode: 500)
        }
        return user
    }

    public func logout() async throws {
        _ = try? await requestJSON(method: "POST", path: "/auth/logout", payload: [:])
        self.sessionToken = nil
        self.sessionTokenObserver?(nil)
    }

    // MARK: - Bootstrap, Self, Profile & Preferences

    public func fetchBootstrap(basePrefs: UserPrefs = UserPrefs()) async throws -> CuvenBootstrapPayload {
        let res = try await requestJSON(method: "GET", path: "/api/bootstrap")
        let onlineIDs = Set(res["presence"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        guard let meObj = res["me"]?.objectValue,
              var me = CuvenWireMapper.mapUser(meObj, onlineSet: onlineIDs) else {
            throw CuvenAPIError(message: "Missing bootstrap profile", statusCode: 500)
        }
        me.isOnline = true

        let wirePrefs = res["prefs"]?.objectValue ?? [:]
        let (mergedPrefs, roomBackdrops) = CuvenWireMapper.mergeServerPrefs(wirePrefs, into: basePrefs)

        let rooms = (res["rooms"]?.arrayValue ?? []).compactMap { val -> Room? in
            guard let obj = val.objectValue else { return nil }
            return CuvenWireMapper.mapRoom(obj, roomBackdrops: roomBackdrops)
        }

        let contacts = (res["contacts"]?.arrayValue ?? []).compactMap { val -> ContactItem? in
            guard let obj = val.objectValue else { return nil }
            return CuvenWireMapper.mapContact(obj, onlineSet: onlineIDs)
        }

        return CuvenBootstrapPayload(
            me: me,
            rooms: rooms,
            contacts: contacts,
            onlineUserIDs: onlineIDs,
            callsEnabled: res["calls"]?.boolValue ?? false,
            assistEnabled: res["assist"]?.boolValue ?? false,
            stickersEnabled: res["stickers"]?.boolValue ?? false,
            prefs: mergedPrefs
        )
    }

    public func updateProfile(
        display: String?,
        bio: String?,
        avatarPath: String? = nil,
        coverValue: String? = nil
    ) async throws -> CuvenUser {
        var payload: [String: CuvenJSONValue] = [:]
        if let display { payload["display"] = .string(display) }
        if let bio { payload["bio"] = .string(bio) }
        if let avatarPath { payload["avatar"] = .string(avatarPath) }
        if let coverValue { payload["cover"] = .string(coverValue) }
        let res = try await requestJSON(method: "POST", path: "/api/profile", payload: payload)
        guard let meObj = res["me"]?.objectValue,
              let user = CuvenWireMapper.mapUser(meObj) else {
            throw CuvenAPIError(message: "Invalid updated profile", statusCode: 500)
        }
        return user
    }

    public func fetchRecentAvatars() async throws -> [String] {
        let res = try await requestJSON(method: "GET", path: "/api/profile/avatars")
        return res["recent"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    public func changePassword(current: String, next: String) async throws {
        _ = try await requestJSON(
            method: "POST",
            path: "/api/password",
            payload: [
                "current": .string(current),
                "next": .string(next)
            ]
        )
    }

    public func syncPreferences(_ prefs: UserPrefs, roomBackdrops: [String: BackdropPreset]? = nil) async throws {
        var payload: [String: CuvenJSONValue] = [
            "chat": .string("preset:\(prefs.defaultBackdrop.rawValue)"),
            "call": .string("preset:\(prefs.callBackdrop.rawValue)"),
            "receipts": .bool(prefs.sendReadReceipts)
        ]
        if let roomBackdrops {
            var roomsMap: [String: CuvenJSONValue] = [:]
            for (roomID, preset) in roomBackdrops {
                roomsMap[roomID] = .string("preset:\(preset.rawValue)")
            }
            payload["rooms"] = .object(roomsMap)
        }
        _ = try await requestJSON(method: "POST", path: "/api/prefs", payload: payload)
    }

    // MARK: - Contacts, People & Notes

    public func searchUsers(query: String) async throws -> [CuvenUser] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let res = try await requestJSON(method: "GET", path: "/api/users/search?q=\(encoded)")
        return (res["users"]?.arrayValue ?? []).compactMap { $0.objectValue.flatMap { CuvenWireMapper.mapUser($0) } }
    }

    public func fetchContacts(onlineIDs: Set<String> = []) async throws -> [ContactItem] {
        let res = try await requestJSON(method: "GET", path: "/api/contacts")
        return (res["contacts"]?.arrayValue ?? []).compactMap { $0.objectValue.flatMap { CuvenWireMapper.mapContact($0, onlineSet: onlineIDs) } }
    }

    public func sendFriendRequest(usernameOrID: String) async throws -> ContactItem? {
        let cleaned = usernameOrID.hasPrefix("@") ? String(usernameOrID.dropFirst()) : usernameOrID
        let res = try await requestJSON(
            method: "POST",
            path: "/api/contacts/add",
            payload: ["user": .string(cleaned), "username": .string(cleaned)]
        )
        guard let peerObj = res["peer"]?.objectValue,
              let user = CuvenWireMapper.mapUser(peerObj) else { return nil }
        let stateStr = res["state"]?.stringValue ?? "pending_out"
        let status: ContactStatus = stateStr == "accepted" ? .accepted : .pendingOut
        return ContactItem(user: user, status: status)
    }

    public func acceptFriendRequest(userID: String) async throws -> CuvenUser? {
        let res = try await requestJSON(
            method: "POST",
            path: "/api/contacts/accept",
            payload: ["user": .string(userID)]
        )
        return res["peer"]?.objectValue.flatMap { CuvenWireMapper.mapUser($0) }
    }

    public func fetchPeople(onlineIDs: Set<String> = []) async throws -> (suggested: [CuvenUser], discover: [CuvenUser]) {
        let res = try await requestJSON(method: "GET", path: "/api/people")
        let suggested = (res["suggested"]?.arrayValue ?? []).compactMap { $0.objectValue.flatMap { CuvenWireMapper.mapUser($0, onlineSet: onlineIDs) } }
        let discover = (res["discover"]?.arrayValue ?? []).compactMap { $0.objectValue.flatMap { CuvenWireMapper.mapUser($0, onlineSet: onlineIDs) } }
        return (suggested, discover)
    }

    public func dismissPerson(userID: String) async throws {
        _ = try await requestJSON(method: "POST", path: "/api/people/dismiss", payload: ["user": .string(userID)])
    }

    public func fetchNotes(currentUser: CuvenUser?) async throws -> (mine: UserNote?, friends: [UserNote]) {
        let res = try await requestJSON(method: "GET", path: "/api/notes")
        let mine = res["mine"]?.objectValue.flatMap { CuvenWireMapper.mapNote($0, fallbackUser: currentUser) }
        let friends = (res["notes"]?.arrayValue ?? []).compactMap { $0.objectValue.flatMap { CuvenWireMapper.mapNote($0) } }
        return (mine, friends)
    }

    public func publishNote(text: String, currentUser: CuvenUser?) async throws -> UserNote? {
        let normalized = EditPolicyValidator.normalizeNoteText(text)
        let res = try await requestJSON(method: "POST", path: "/api/note", payload: ["text": .string(normalized)])
        return res["mine"]?.objectValue.flatMap { CuvenWireMapper.mapNote($0, fallbackUser: currentUser) }
    }

    public func deleteNote() async throws {
        _ = try await requestJSON(method: "DELETE", path: "/api/note")
    }

    // MARK: - Rooms & Messages

    public func fetchRooms(roomBackdrops: [String: BackdropPreset] = [:]) async throws -> [Room] {
        let res = try await requestJSON(method: "GET", path: "/api/rooms")
        return (res["rooms"]?.arrayValue ?? []).compactMap { $0.objectValue.flatMap { CuvenWireMapper.mapRoom($0, roomBackdrops: roomBackdrops) } }
    }

    public func createOrOpenDM(userOrUsername: String) async throws -> Room {
        let res = try await requestJSON(
            method: "POST",
            path: "/api/dm",
            payload: ["user": .string(userOrUsername), "username": .string(userOrUsername)]
        )
        guard let roomObj = res["room"]?.objectValue,
              let room = CuvenWireMapper.mapRoom(roomObj) else {
            throw CuvenAPIError(message: "Failed to open DM", statusCode: 500)
        }
        return room
    }

    public func createGroup(name: String, memberIDs: [String]) async throws -> Room {
        let res = try await requestJSON(
            method: "POST",
            path: "/api/group",
            payload: [
                "name": .string(name),
                "members": .array(memberIDs.map(CuvenJSONValue.string))
            ]
        )
        guard let roomObj = res["room"]?.objectValue,
              let room = CuvenWireMapper.mapRoom(roomObj) else {
            throw CuvenAPIError(message: "Failed to create group", statusCode: 500)
        }
        return room
    }

    public func setRoomFlags(
        roomID: String,
        muted: Bool? = nil,
        pinned: Bool? = nil,
        hidden: Bool? = nil,
        unread: Bool? = nil
    ) async throws {
        var payload: [String: CuvenJSONValue] = [:]
        if let muted { payload["muted"] = .int(muted ? 1 : 0) }
        if let pinned { payload["pinned"] = .int(pinned ? 1 : 0) }
        if let hidden { payload["hidden"] = .int(hidden ? 1 : 0) }
        if let unread { payload["unread"] = .bool(unread) }
        let encodedID = roomID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? roomID
        _ = try await requestJSON(method: "POST", path: "/api/room/\(encodedID)/flags", payload: payload)
    }

    public func markRoomRead(roomID: String, timestampMs: Int64) async throws {
        let encodedID = roomID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? roomID
        _ = try await requestJSON(
            method: "POST",
            path: "/api/room/\(encodedID)/read",
            payload: ["ts": .int(timestampMs)]
        )
    }

    public func fetchMessages(
        roomID: String,
        before: Int64? = nil,
        after: Int64? = nil,
        limit: Int = 50,
        displayLookup: [String: String] = [:]
    ) async throws -> [Message] {
        var comps: [String] = [
            "room=\(roomID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? roomID)",
            "limit=\(min(100, max(1, limit)))"
        ]
        if let before { comps.append("before=\(before)") }
        if let after { comps.append("after=\(after)") }
        let res = try await requestJSON(method: "GET", path: "/api/messages?\(comps.joined(separator: "&"))")
        return (res["messages"]?.arrayValue ?? []).compactMap { val in
            val.objectValue.flatMap { CuvenWireMapper.mapMessage($0, displayLookup: displayLookup) }
        }
    }

    public func postMessage(
        payload: [String: CuvenJSONValue],
        displayLookup: [String: String] = [:]
    ) async throws -> Message {
        let res = try await requestJSON(method: "POST", path: "/api/messages", payload: payload)
        let localId = res["localId"]?.stringValue ?? payload["localId"]?.stringValue
        guard let msgObj = res["msg"]?.objectValue,
              let message = CuvenWireMapper.mapMessage(msgObj, localIDOverride: localId, displayLookup: displayLookup) else {
            throw CuvenAPIError(message: "Invalid message response", statusCode: 500)
        }
        return message
    }

    public func setReaction(messageID: String, emoji: String, displayLookup: [String: String] = [:]) async throws -> Message {
        let res = try await requestJSON(
            method: "POST",
            path: "/api/react",
            payload: ["id": .string(messageID), "emoji": .string(emoji)]
        )
        guard let msgObj = res["msg"]?.objectValue,
              let message = CuvenWireMapper.mapMessage(msgObj, displayLookup: displayLookup) else {
            throw CuvenAPIError(message: "Invalid reaction response", statusCode: 500)
        }
        return message
    }

    public func editMessage(messageID: String, newText: String, displayLookup: [String: String] = [:]) async throws -> Message {
        let res = try await requestJSON(
            method: "POST",
            path: "/api/edit",
            payload: ["id": .string(messageID), "text": .string(newText)]
        )
        guard let msgObj = res["msg"]?.objectValue,
              let message = CuvenWireMapper.mapMessage(msgObj, displayLookup: displayLookup) else {
            throw CuvenAPIError(message: "Invalid edit response", statusCode: 500)
        }
        return message
    }

    public func revokeMessage(messageID: String, displayLookup: [String: String] = [:]) async throws -> Message {
        let res = try await requestJSON(
            method: "POST",
            path: "/api/revoke",
            payload: ["id": .string(messageID)]
        )
        guard let msgObj = res["msg"]?.objectValue,
              let message = CuvenWireMapper.mapMessage(msgObj, displayLookup: displayLookup) else {
            throw CuvenAPIError(message: "Invalid revoke response", statusCode: 500)
        }
        return message
    }

    // MARK: - Media Upload & Authenticated Download (/api/media/*)

    public func uploadMedia(
        data: Data,
        contentType: String,
        kind: String,
        roomID: String? = nil,
        localID: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        durationSeconds: Double? = nil,
        fileName: String? = nil
    ) async throws -> CuvenMediaUploadResult {
        var queryItems: [String] = ["kind=\(kind.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? kind)"]
        if let roomID, !roomID.isEmpty {
            queryItems.append("room=\(roomID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? roomID)")
        }
        if let localID, !localID.isEmpty {
            queryItems.append("localId=\(localID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? localID)")
        }
        if let width, width > 0 { queryItems.append("w=\(width)") }
        if let height, height > 0 { queryItems.append("h=\(height)") }
        if let durationSeconds, durationSeconds > 0 { queryItems.append("dur=\(durationSeconds)") }
        if let fileName, !fileName.isEmpty {
            queryItems.append("name=\(fileName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fileName)")
        }

        let request = try buildRequest(
            method: "POST",
            path: "/api/media/upload?\(queryItems.joined(separator: "&"))",
            contentType: contentType,
            additionalHeaders: ["Content-Length": String(data.count)],
            body: data
        )
        let (resData, response) = try await performRawRequest(request)
        let parsed = (try? JSONDecoder().decode([String: CuvenJSONValue].self, from: resData)) ?? [:]
        if !(200..<300).contains(response.statusCode) || parsed["ok"]?.boolValue == false {
            throw CuvenAPIError(
                message: parsed["error"]?.stringValue ?? "Upload failed (\(response.statusCode))",
                statusCode: response.statusCode
            )
        }
        let meta = parsed["meta"]?.objectValue ?? [:]
        return CuvenMediaUploadResult(
            key: parsed["key"]?.stringValue ?? "",
            url: parsed["url"]?.stringValue ?? "",
            width: meta["w"]?.intValue ?? width,
            height: meta["h"]?.intValue ?? height,
            durationSeconds: meta["dur"]?.doubleValue ?? durationSeconds
        )
    }

    public func downloadMedia(pathOrURL: String, byteRange: Range<Int>? = nil) async throws -> (Data, HTTPURLResponse) {
        var headers: [String: String] = [:]
        if let byteRange {
            headers["Range"] = "bytes=\(byteRange.lowerBound)-\(max(byteRange.lowerBound, byteRange.upperBound - 1))"
        }
        let request = try buildRequest(method: "GET", path: pathOrURL, additionalHeaders: headers)
        let (data, response) = try await performRawRequest(request)
        guard (200..<300).contains(response.statusCode) else {
            throw CuvenAPIError(message: "Media fetch failed (\(response.statusCode))", statusCode: response.statusCode)
        }
        return (data, response)
    }

    // MARK: - Moments, Memories & Stickers

    public func fetchMoments(before: Int64? = nil, limit: Int = 20, onlineIDs: Set<String> = []) async throws -> [MomentPost] {
        var path = "/api/moments?limit=\(min(20, max(1, limit)))"
        if let before { path += "&before=\(before)" }
        let res = try await requestJSON(method: "GET", path: path)
        return (res["moments"]?.arrayValue ?? []).compactMap { $0.objectValue.flatMap { CuvenWireMapper.mapMoment($0, onlineSet: onlineIDs) } }
    }

    public func publishMoment(
        text: String,
        media: [MomentMedia],
        audience: String,
        commentPolicy: String,
        taggedUserIDs: [String],
        scheduledAt: Int64?
    ) async throws -> MomentPost {
        let wireMedia: [CuvenJSONValue] = media.map { m in
            var item: [String: CuvenJSONValue] = [
                "url": .string(m.url),
                "type": .string(m.isVideo ? "video" : "image"),
                "w": .int(Int64(m.width)),
                "h": .int(Int64(m.height))
            ]
            if let alt = m.altText, !alt.isEmpty {
                item["alt"] = .string(alt)
            }
            return .object(item)
        }
        var payload: [String: CuvenJSONValue] = [
            "text": .string(text),
            "media": .array(wireMedia),
            "audience": .string(audience),
            "comments": .string(commentPolicy),
            "tags": .array(taggedUserIDs.map(CuvenJSONValue.string))
        ]
        if let scheduledAt {
            payload["at"] = .int(scheduledAt)
        }
        let res = try await requestJSON(method: "POST", path: "/api/moments", payload: payload)
        guard let mObj = res["moment"]?.objectValue,
              let post = CuvenWireMapper.mapMoment(mObj) else {
            throw CuvenAPIError(message: "Invalid moment response", statusCode: 500)
        }
        return post
    }

    public func setMomentLike(momentID: String, isLiked: Bool) async throws -> MomentPost {
        let encoded = momentID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? momentID
        let res = try await requestJSON(
            method: "POST",
            path: "/api/moments/\(encoded)/like",
            payload: ["on": .bool(isLiked)]
        )
        guard let mObj = res["moment"]?.objectValue,
              let post = CuvenWireMapper.mapMoment(mObj) else {
            throw CuvenAPIError(message: "Invalid moment like response", statusCode: 500)
        }
        return post
    }

    public func addMomentComment(momentID: String, text: String) async throws -> MomentPost {
        let encoded = momentID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? momentID
        let res = try await requestJSON(
            method: "POST",
            path: "/api/moments/\(encoded)/comments",
            payload: ["text": .string(text)]
        )
        guard let mObj = res["moment"]?.objectValue,
              let post = CuvenWireMapper.mapMoment(mObj) else {
            throw CuvenAPIError(message: "Invalid moment comment response", statusCode: 500)
        }
        return post
    }

    public func deleteMoment(momentID: String) async throws {
        let encoded = momentID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? momentID
        _ = try await requestJSON(method: "DELETE", path: "/api/moments/\(encoded)")
    }

    public func fetchMemories(before: Int64? = nil, limit: Int = 60, type: String? = nil) async throws -> [MemoryItem] {
        var q = ["limit=\(min(120, max(1, limit)))"]
        if let before { q.append("before=\(before)") }
        if let type, !type.isEmpty { q.append("type=\(type)") }
        let res = try await requestJSON(method: "GET", path: "/api/memories?\(q.joined(separator: "&"))")
        return (res["memories"]?.arrayValue ?? []).compactMap { $0.objectValue.flatMap { CuvenWireMapper.mapMemory($0) } }
    }

    public func fetchStickerPacks() async throws -> [StickerPack] {
        let res = try await requestJSON(method: "GET", path: "/api/stickers")
        return (res["sets"]?.arrayValue ?? []).compactMap { $0.objectValue.flatMap { CuvenWireMapper.mapStickerPack($0) } }
    }

    public func updateInstalledStickerPack(packName: String, install: Bool) async throws -> [StickerPack] {
        let payload: [String: CuvenJSONValue] = install
            ? ["add": .string(packName)]
            : ["remove": .string(packName)]
        let res = try await requestJSON(method: "POST", path: "/api/stickers/mine", payload: payload)
        return (res["sets"]?.arrayValue ?? []).compactMap { $0.objectValue.flatMap { CuvenWireMapper.mapStickerPack($0) } }
    }

    // MARK: - Smart / Workers AI & Insights (/api/ai/*, /api/insights*)

    public func fetchGhostSuggestion(roomID: String, draft: String) async throws -> String {
        let res = try await requestJSON(
            method: "POST",
            path: "/api/ai/suggest",
            payload: ["room": .string(roomID), "draft": .string(String(draft.prefix(200)))]
        )
        return res["text"]?.stringValue ?? ""
    }

    public func transcribeAudioWAV(_ wav16kMonoData: Data) async throws -> String {
        let b64 = wav16kMonoData.base64EncodedString()
        let res = try await requestJSON(
            method: "POST",
            path: "/api/ai/transcribe",
            payload: ["audio": .string(b64)]
        )
        return res["text"]?.stringValue ?? ""
    }

    public func fetchAIMemory() async throws -> (memories: [AIMemoryItem], routineBuckets: [AIRoutineHourBucket]) {
        let res = try await requestJSON(method: "GET", path: "/api/ai/memory")
        var items: [AIMemoryItem] = []
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        if let style = res["style"]?.objectValue {
            let words = style["words"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let endings = style["endings"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let at = style["at"]?.int64Value ?? nowMs
            if !words.isEmpty {
                items.append(AIMemoryItem(id: "style_words", category: "Writing Style", detail: "Frequent words: \(words.joined(separator: ", "))", updatedAt: at))
            }
            if !endings.isEmpty {
                items.append(AIMemoryItem(id: "style_endings", category: "Tone & Cadence", detail: "Signature endings: \(endings.joined(separator: " · "))", updatedAt: at))
            }
        }
        if let digests = res["digests"]?.arrayValue {
            for (idx, dVal) in digests.enumerated() {
                guard let dObj = dVal.objectValue,
                      let text = dObj["text"]?.stringValue, !text.isEmpty else { continue }
                let room = dObj["room"]?.stringValue ?? "\(idx)"
                items.append(AIMemoryItem(id: "digest_\(room)", category: "Conversation Digest", detail: text, updatedAt: dObj["at"]?.int64Value ?? nowMs))
            }
        }

        var buckets: [AIRoutineHourBucket] = (0..<24).map { AIRoutineHourBucket(hour: $0, activityScore: 0) }
        if let routine = res["routine"]?.objectValue,
           let hours = routine["hours"]?.arrayValue,
           hours.count == 24 {
            let rawValues = hours.map { $0.doubleValue ?? 0 }
            let peak = max(1.0, rawValues.max() ?? 1.0)
            buckets = rawValues.enumerated().map { hour, count in
                AIRoutineHourBucket(hour: hour, activityScore: min(1.0, max(0.0, count / peak)))
            }
        }
        return (items, buckets)
    }

    public func clearAIMemory() async throws {
        _ = try await requestJSON(method: "DELETE", path: "/api/ai/memory")
    }

    public func setRoutineLearning(enabled: Bool) async throws {
        _ = try await requestJSON(
            method: "POST",
            path: "/api/ai/memory/routine",
            payload: ["learn": .bool(enabled)]
        )
    }

    public func fetchInsights(unit: String = "c") async throws -> [String: RoomInsight] {
        let res = try await requestJSON(method: "GET", path: "/api/insights?unit=\(unit)")
        let weatherObj = res["weather"]?.objectValue
        var result: [String: RoomInsight] = [:]
        for item in res["rooms"]?.arrayValue ?? [] {
            guard let row = item.objectValue,
                  let mapped = CuvenWireMapper.mapInsight(row, weatherObj: weatherObj) else { continue }
            result[mapped.roomID] = mapped
        }
        return result
    }

    // MARK: - Cloudflare Realtime SFU Proxy (/rtc/*)

    public func requestRTCTurnCredentials() async throws -> [String: CuvenJSONValue] {
        try await requestJSON(method: "POST", path: "/rtc/turn", payload: [:])
    }

    public func postRTCSession(path: String, method: String = "POST", payload: [String: CuvenJSONValue]) async throws -> [String: CuvenJSONValue] {
        try await requestJSON(method: method, path: path, payload: payload)
    }
}

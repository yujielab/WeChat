import SwiftUI
import UserNotifications

struct ThreadData {
    var messages: [Message] = []
    var hasMore = true
    var loaded = false
    var loading = false
}

struct TypingInfo: Equatable {
    var text: String
    var at: Date
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var isError = false
}

/// The whole app's state: the session, the conversation list, open threads,
/// people and the realtime connection. Views read it from the environment.
@MainActor
@Observable
final class AppModel {
    enum Phase { case launching, signedOut, ready }

    static let defaultServer = URL(string: "https://wechat.cuven.us")!

    var phase: Phase = .launching
    let api: APIClient
    @ObservationIgnored var socket: Socket!
    var connected = false

    var me: User?
    var rooms: [Room] = []
    var contacts: [User] = []
    var presence: Set<String> = []
    var callsEnabled = false
    var assistEnabled = false
    var stickersEnabled = false
    var prefs = Prefs()

    var threads: [String: ThreadData] = [:]
    var typing: [String: [String: TypingInfo]] = [:]
    var members: [String: [Member]] = [:]
    var users: [String: User] = [:]

    var myNote: Note?
    var notes: [FriendNote] = []
    var suggested: [User] = []
    var discover: [User] = []
    var momentsDot = false
    var momentsVersion = 0
    var toast: Toast?

    /// The conversation on screen (read as it arrives), set by the layout.
    var visibleRoom: String?
    var appActive = true
    /// A conversation to open (a notification was tapped).
    var pendingRoom: String?

    // Device-only settings.
    var livePreview: Bool { didSet { UserDefaults.standard.set(livePreview, forKey: "ui:livePreview") } }
    var predictions: Bool { didSet { UserDefaults.standard.set(predictions, forKey: "ui:predictions") } }
    var highlights: Bool { didSet { UserDefaults.standard.set(highlights, forKey: "ui:highlights") } }
    var haptics: Bool { didSet { UserDefaults.standard.set(haptics, forKey: "ui:haptics"); Haptics.enabled = haptics } }
    var appearance: String { didSet { UserDefaults.standard.set(appearance, forKey: "ui:appearance") } }
    var composerGlow: String { didSet { UserDefaults.standard.set(composerGlow, forKey: "ui:glow") } }
    var bookLayout: Bool { didSet { UserDefaults.standard.set(bookLayout, forKey: "ui:book") } }

    /// Messages deleted on this device only ("Delete for me").
    var hiddenMessages: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "hiddenMessages") ?? []) {
        didSet { UserDefaults.standard.set(Array(hiddenMessages.suffix(2000)), forKey: "hiddenMessages") }
    }

    @ObservationIgnored var drafts: [String: String] = [:]
    @ObservationIgnored var outbox: [OutboxItem] = []
    @ObservationIgnored var outboxRunning = false
    @ObservationIgnored var typingSent: [String: (String, Date)] = [:]
    @ObservationIgnored private var typingSweep: Timer?
    @ObservationIgnored var calls: CallManager!

    var serverURL: URL { api.base }

    init() {
        let d = UserDefaults.standard
        let saved = d.string(forKey: "server").flatMap(URL.init(string:)) ?? Self.defaultServer
        api = APIClient(base: saved)
        livePreview = d.object(forKey: "ui:livePreview") as? Bool ?? true
        predictions = d.object(forKey: "ui:predictions") as? Bool ?? true
        highlights = d.object(forKey: "ui:highlights") as? Bool ?? true
        haptics = d.object(forKey: "ui:haptics") as? Bool ?? true
        appearance = d.string(forKey: "ui:appearance") ?? "light"
        composerGlow = d.string(forKey: "ui:glow") ?? "ocean"
        bookLayout = d.bool(forKey: "ui:book")
        Haptics.enabled = haptics
        ImageStore.shared.api = api
        socket = Socket(api: api)
        calls = CallManager(model: self)
        socket.onEvent = { [weak self] e in self?.handle(e) }
        socket.onOpen = { [weak self] in
            self?.connected = true
            self?.catchUp()
            self?.runOutbox()
        }
        socket.onClose = { [weak self] in self?.connected = false }
        api.onUnauthorized = { [weak self] in self?.sessionExpired() }
        typingSweep = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sweepTyping() }
        }
    }

    var colorScheme: ColorScheme? {
        switch appearance {
        case "dark": return .dark
        case "system": return nil
        default: return .light
        }
    }

    // MARK: - Session

    func launch() async {
        if let cached = DiskCache.load(api: api) {
            me = cached.me
            rooms = cached.rooms
            for (k, v) in cached.threads { threads[k] = ThreadData(messages: v, hasMore: true, loaded: false) }
            indexUsers()
        }
        guard api.isSignedIn else {
            phase = .signedOut
            return
        }
        if me != nil { phase = .ready }
        do {
            try await bootstrap()
        } catch let e as APIError where e.status == 401 {
            signOutLocally()
        } catch {
            if me == nil { phase = .signedOut }
            else { show(error.localizedDescription, error: true) }
        }
    }

    func setServer(_ text: String) -> Bool {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = Self.defaultServer.absoluteString }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.host != nil else { return false }
        api.setBase(url)
        UserDefaults.standard.set(url.absoluteString, forKey: "server")
        return true
    }

    func authStatus() async -> AuthStatus? {
        try? await api.get("/auth/status", as: AuthStatus.self)
    }

    func login(username: String, password: String) async throws {
        let _: MeResponse = try await api.post("/auth/login", ["username": username, "password": password])
        try await bootstrap()
    }

    func register(username: String, display: String, password: String, code: String) async throws {
        var body: [String: Any] = ["username": username, "password": password, "display": display]
        if !code.isEmpty { body["code"] = code }
        let _: MeResponse = try await api.post("/auth/register", body)
        try await bootstrap()
    }

    func logout() async {
        try? await api.post("/auth/logout")
        signOutLocally()
    }

    private func sessionExpired() {
        guard phase == .ready else { return }
        signOutLocally()
        show(String(localized: "Signed out. Please sign in again."), error: true)
    }

    func signOutLocally() {
        socket.stop()
        api.clearSession()
        DiskCache.clear(api: api)
        me = nil; rooms = []; contacts = []; threads = [:]; members = [:]; notes = []; myNote = nil
        suggested = []; discover = []; presence = []; outbox = []
        phase = .signedOut
    }

    func bootstrap() async throws {
        let b: Bootstrap = try await api.get("/api/bootstrap")
        me = b.me
        rooms = sortRooms(b.rooms)
        contacts = b.contacts
        presence = Set(b.presence)
        callsEnabled = b.calls?.enabled ?? false
        assistEnabled = b.assist ?? false
        stickersEnabled = b.stickers ?? false
        prefs = b.prefs ?? Prefs()
        indexUsers()
        withAnimation(.smooth(duration: 0.35)) { phase = .ready }
        socket.start()
        if !Automation.active { requestNotifications() }
        persist()
        Task { await loadNotes() }
        Task { await loadPeople() }
    }

    func catchUp() {
        Task {
            await refreshRooms()
            for (room, t) in threads where t.loaded {
                await loadNewer(room)
            }
        }
    }

    func refreshRooms() async {
        guard let r: RoomsResponse = try? await api.get("/api/rooms") else { return }
        withAnimation(.smooth(duration: 0.3)) { rooms = sortRooms(r.rooms) }
        indexUsers()
        persist()
    }

    func refreshContacts() async {
        if let c: ContactsResponse = try? await api.get("/api/contacts") {
            contacts = c.contacts
            indexUsers()
        }
    }

    func sortRooms(_ list: [Room]) -> [Room] {
        list.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.ts > b.ts
        }
    }

    func indexUsers() {
        if let me { users[me.id] = me }
        for c in contacts { users[c.id] = c }
        for r in rooms { if let p = r.peer { users[p.id] = p } }
        for (_, list) in members { for m in list { users[m.id] = m.user } }
    }

    func room(_ id: String?) -> Room? {
        guard let id else { return nil }
        return rooms.first { $0.id == id }
    }

    func roomIndex(_ id: String) -> Int? { rooms.firstIndex { $0.id == id } }

    func user(_ id: String) -> User? { users[id] }

    func name(of uid: String) -> String {
        if uid == me?.id { return String(localized: "You") }
        return users[uid]?.name ?? String(localized: "Someone")
    }

    func isOnline(_ uid: String?) -> Bool {
        guard let uid else { return false }
        return presence.contains(uid)
    }

    var unreadTotal: Int { rooms.filter { !$0.muted }.reduce(0) { $0 + $1.unread } }
    var requests: [User] { contacts.filter { $0.state == "pending_in" } }
    var sentRequests: [User] { contacts.filter { $0.state == "pending_out" } }

    func show(_ text: String, error: Bool = false) {
        withAnimation(.snappy) { toast = Toast(text: text, isError: error) }
        let id = toast?.id
        Task {
            try? await Task.sleep(for: .seconds(2.6))
            if toast?.id == id { withAnimation(.smooth) { toast = nil } }
        }
    }

    func persist() {
        guard let me else { return }
        let snapshot = DiskCache.Snapshot(me: me, rooms: rooms, threads: threads.mapValues { Array($0.messages.filter { !$0.isLocal }.suffix(60)) })
        DiskCache.save(snapshot, api: api)
    }

    // MARK: - Realtime events

    func handle(_ e: [String: Any]) {
        guard let t = e["t"] as? String else { return }
        switch t {
        case "hello":
            if let me: User = decode(e["me"]) { self.me = me; users[me.id] = me }
            if let p = e["presence"] as? [String] { presence = Set(p) }
        case "presence":
            if let uid = e["uid"] as? String {
                if e["online"] as? Bool == true { presence.insert(uid) } else { presence.remove(uid) }
            }
        case "msg":
            if let msg: Message = decode(e["msg"]) { receive(msg, localId: e["localId"] as? String) }
        case "react", "edit":
            if let msg: Message = decode(e["msg"]) { replace(msg) }
        case "keys":
            if let id = e["id"] as? String, let room = e["room"] as? String, let keys = e["keys"] as? [String] {
                updateMessage(room, id) { m in
                    var meta = m.meta ?? MessageMeta()
                    meta.keys = keys
                    m.meta = meta
                }
            }
        case "read":
            if let room = e["room"] as? String, let i = roomIndex(room) {
                rooms[i].peerRead = max(rooms[i].peerRead, (e["ts"] as? NSNumber)?.intValue ?? 0)
                rooms[i].peerReadAt = (e["at"] as? NSNumber)?.intValue ?? rooms[i].peerReadAt
            }
        case "typing":
            if let room = e["room"] as? String, let uid = e["uid"] as? String {
                let text = e["text"] as? String ?? ""
                var map = typing[room] ?? [:]
                if text.isEmpty { map[uid] = nil } else { map[uid] = TypingInfo(text: text, at: Date()) }
                typing[room] = map
            }
        case "rooms-dirty":
            Task { await refreshRooms() }
        case "contacts-dirty":
            Task {
                await refreshContacts()
                await loadPeople()
            }
        case "note":
            Task { await loadNotes() }
        case "moment":
            if (e["user"] as? String) != me?.id { momentsDot = true }
            momentsVersion += 1
        case "moment-changed", "moment-deleted":
            momentsVersion += 1
        case "profile":
            if let u: User = decode(e["user"]) {
                users[u.id] = u
                for i in rooms.indices where rooms[i].peer?.id == u.id {
                    rooms[i].peer = u
                    rooms[i].name = u.display
                    rooms[i].avatar = u.avatar
                }
                if u.id == me?.id { me = u }
            }
        case "prefs":
            if let p: Prefs = decode(e["prefs"]) { prefs = p }
        case "call":
            calls.handle(e)
        default:
            break
        }
    }

    func decode<T: Decodable>(_ any: Any?) -> T? {
        guard let any, JSONSerialization.isValidJSONObject(any) || any is [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: any) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func sweepTyping() {
        let now = Date()
        for (room, map) in typing {
            let alive = map.filter { now.timeIntervalSince($0.value.at) < 8 }
            if alive.count != map.count { typing[room] = alive }
        }
    }

    // MARK: - Notifications (while the app is around; the server only speaks Web Push)

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func notifyIfAway(_ msg: Message) {
        guard !appActive, msg.sender != me?.id, !msg.isSystem, let room = room(msg.room), !room.muted else { return }
        let content = UNMutableNotificationContent()
        content.title = room.isGroup ? room.title : name(of: msg.sender)
        content.body = room.isGroup ? "\(name(of: msg.sender)): \(msg.preview)" : msg.preview
        content.sound = .default
        content.threadIdentifier = room.id
        content.userInfo = ["room": room.id]
        let req = UNNotificationRequest(identifier: msg.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
        UNUserNotificationCenter.current().setBadgeCount(unreadTotal) { _ in }
    }
}

// MARK: - Offline snapshot

enum DiskCache {
    struct Snapshot: Codable {
        var me: User
        var rooms: [Room]
        var threads: [String: [Message]]
    }

    private static func url(api: APIClient) -> URL? {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("snapshot-\(APIClient.account(for: api.base)).json")
    }

    static func load(api: APIClient) -> Snapshot? {
        guard api.isSignedIn, let u = url(api: api), let data = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func save(_ s: Snapshot, api: APIClient) {
        guard let u = url(api: api) else { return }
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(s) { try? data.write(to: u, options: .atomic) }
        }
    }

    static func clear(api: APIClient) {
        guard let u = url(api: api) else { return }
        try? FileManager.default.removeItem(at: u)
    }
}

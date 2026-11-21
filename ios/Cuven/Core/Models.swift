import Foundation

// Data shapes the hub sends (src/store.js, src/hub.js). Decoding is lenient:
// a field that is missing or of an unexpected type falls back to a default
// instead of failing the whole response, so a newer server never breaks an
// older app.

extension KeyedDecodingContainer {
    func v<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
    func o<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

// MARK: - JSON value (free-form payloads)

enum JSONValue: Codable, Hashable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var number: Double? { if case .number(let n) = self { return n }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [JSONValue] { if case .array(let a) = self { return a }; return [] }
}

// MARK: - People

struct User: Codable, Identifiable, Hashable {
    var id: String
    var username: String
    var display: String
    var avatar: String
    var bio: String
    var cover: String
    // Context-dependent extras: contact state, suggestions, members, profiles.
    var state: String?
    var since: Int?
    var reason: String?
    var mutual: Int?
    var role: String?
    var online: Bool?
    var friend: Bool?
    var joined: Int?

    enum CodingKeys: String, CodingKey {
        case id, username, display, avatar, bio, cover, state, since, reason, mutual, role, online, friend, joined
    }

    init(id: String, username: String = "", display: String = "", avatar: String = "", bio: String = "", cover: String = "") {
        self.id = id; self.username = username; self.display = display; self.avatar = avatar; self.bio = bio; self.cover = cover
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.v(.id, "")
        username = c.v(.username, "")
        display = c.v(.display, "")
        avatar = c.v(.avatar, "")
        bio = c.v(.bio, "")
        cover = c.v(.cover, "")
        state = c.o(.state)
        since = c.o(.since)
        reason = c.o(.reason)
        mutual = c.o(.mutual)
        role = c.o(.role)
        online = c.o(.online)
        friend = c.o(.friend)
        joined = c.o(.joined)
    }

    var name: String { display.isEmpty ? (username.isEmpty ? "Someone" : username) : display }
    var initial: String { String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased() }
}

// MARK: - Messages

struct EditVersion: Codable, Hashable {
    var text: String
    var ts: Int
}

struct Reaction: Codable, Hashable {
    var emoji: String
    var users: [String]
}

/// Everything a message's `meta` may hold: media (url, size, dimensions),
/// a sticker reference, a call record, key words, mentions and edits.
struct MessageMeta: Codable, Hashable {
    var url: String?
    var w: Double?
    var h: Double?
    var dur: Double?
    var size: Double?
    var name: String?
    var type: String?
    var keys: [String]?
    var mentions: [String]?
    var history: [EditVersion]?
    var editedAt: Int?
    // sticker
    var id: String?
    var kind: String?
    var emoji: String?
    var set: String?
    // call
    var media: String?
    var duration: Double?
    var missed: Bool?
    var result: String?
    var caller: String?
    // location (name is the place's name)
    var lat: Double?
    var lng: Double?
    var address: String?

    enum CodingKeys: String, CodingKey {
        case url, w, h, dur, size, name, type, keys, mentions, history, editedAt, id, kind, emoji, set, media, duration, missed, result, caller
        case lat, lng, address
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = c.o(.url); w = c.o(.w); h = c.o(.h); dur = c.o(.dur); size = c.o(.size)
        name = c.o(.name); type = c.o(.type); keys = c.o(.keys); mentions = c.o(.mentions)
        history = c.o(.history); editedAt = c.o(.editedAt)
        id = c.o(.id); kind = c.o(.kind); emoji = c.o(.emoji); set = c.o(.set)
        media = c.o(.media); duration = c.o(.duration); missed = c.o(.missed); result = c.o(.result); caller = c.o(.caller)
        lat = c.o(.lat); lng = c.o(.lng); address = c.o(.address)
    }

    var aspect: CGFloat? {
        guard let w, let h, w > 0, h > 0 else { return nil }
        return CGFloat(w / h)
    }
}

struct ReplySnapshot: Codable, Hashable {
    var id: String
    var sender: String
    var ts: Int
    var type: String
    var state: String
    var body: String
    var url: String?
    var emoji: String?

    enum CodingKeys: String, CodingKey { case id, sender, ts, type, state, body, url, emoji }

    init(id: String, sender: String, ts: Int, type: String, state: String, body: String, url: String? = nil, emoji: String? = nil) {
        self.id = id; self.sender = sender; self.ts = ts; self.type = type; self.state = state; self.body = body; self.url = url; self.emoji = emoji
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.v(.id, ""); sender = c.v(.sender, ""); ts = c.v(.ts, 0); type = c.v(.type, "text")
        state = c.v(.state, "sent"); body = c.v(.body, ""); url = c.o(.url); emoji = c.o(.emoji)
    }
}

enum LocalStatus: String, Codable, Hashable { case sending, failed }

struct Message: Codable, Identifiable, Hashable {
    var id: String
    var room: String
    var sender: String
    var ts: Int
    var type: String
    var body: String
    var meta: MessageMeta?
    var replyTo: String?
    var state: String
    var edited: Int
    var reactions: [Reaction]
    var reply: ReplySnapshot?
    // Only on this device: an optimistic message on its way.
    var localId: String?
    var local: LocalStatus?
    var progress: Double?

    enum CodingKeys: String, CodingKey {
        case id, room, sender, ts, type, body, meta, replyTo, state, edited, reactions, reply, localId, local
    }

    init(id: String, room: String, sender: String, ts: Int, type: String, body: String, meta: MessageMeta? = nil,
         replyTo: String? = nil, state: String = "sent", edited: Int = 0, reactions: [Reaction] = [], reply: ReplySnapshot? = nil,
         localId: String? = nil, local: LocalStatus? = nil) {
        self.id = id; self.room = room; self.sender = sender; self.ts = ts; self.type = type; self.body = body; self.meta = meta
        self.replyTo = replyTo; self.state = state; self.edited = edited; self.reactions = reactions; self.reply = reply
        self.localId = localId; self.local = local
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.v(.id, UUID().uuidString)
        room = c.v(.room, "")
        sender = c.v(.sender, "")
        ts = c.v(.ts, 0)
        type = c.v(.type, "text")
        body = c.v(.body, "")
        meta = c.o(.meta)
        replyTo = c.o(.replyTo)
        state = c.v(.state, "sent")
        edited = c.v(.edited, 0)
        reactions = c.v(.reactions, [])
        reply = c.o(.reply)
        localId = c.o(.localId)
        local = c.o(.local)
    }

    var isSystem: Bool { type == "system" }
    var isRevoked: Bool { state == "revoked" }
    var isLocal: Bool { id.hasPrefix("local:") }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(ts) / 1000) }
    var isVisual: Bool { type == "image" || type == "drawing" }

    /// A one-line summary, as the list and replies show it.
    var preview: String {
        if isRevoked { return String(localized: "Message unsent") }
        switch type {
        case "text": return body
        case "image": return String(localized: "Photo")
        case "drawing": return String(localized: "Drawing")
        case "voice": return String(localized: "Voice message")
        case "video": return String(localized: "Video")
        case "file": return meta?.name ?? String(localized: "File")
        case "sticker": return [String(localized: "Sticker"), meta?.emoji ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        case "call": return CallSummary(meta: meta, mine: false).label
        case "location": return "📍 " + (meta?.name.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Location"))
        default: return body
        }
    }

    /// A place someone shared (a "location" message, or, from a server that
    /// doesn't know them yet, a text carrying the place in its meta).
    var isLocation: Bool { meta?.lat != nil && meta?.lng != nil }
}

/// How a call record reads, from either side (public/js/ui/format.js callSummary).
struct CallSummary {
    let media: String
    let text: String
    let missed: Bool
    var label: String { "\(media) · \(text)" }
    var isVideo: Bool

    init(meta: MessageMeta?, mine: Bool) {
        isVideo = meta?.media == "video"
        media = isVideo ? String(localized: "Video call") : String(localized: "Voice call")
        let result = meta?.result ?? ((meta?.missed ?? false) ? "missed" : "completed")
        var missed = false
        switch result {
        case "completed":
            let d = Int(meta?.duration ?? 0)
            text = d >= 1 ? String(format: "%d:%02d", d / 60, d % 60) : String(localized: "Call ended")
        case "failed": text = String(localized: "Connection failed")
        case "declined": text = mine ? String(localized: "Declined") : String(localized: "You declined")
        case "busy" where mine: text = String(localized: "Busy")
        default:
            if mine { text = result == "cancelled" ? String(localized: "Cancelled") : String(localized: "No answer") }
            else { text = String(localized: "Missed call"); missed = true }
        }
        self.missed = missed
    }
}

// MARK: - Rooms

struct Room: Codable, Identifiable, Hashable {
    var id: String
    var kind: String
    var name: String
    var avatar: String
    var pinned: Bool
    var muted: Bool
    var lastRead: Int
    var unread: Int
    var marked: Bool
    var mention: String?
    var last: Message?
    var ts: Int
    var peer: User?
    var peerRead: Int
    var peerReadAt: Int
    var count: Int

    enum CodingKeys: String, CodingKey {
        case id, kind, name, avatar, pinned, muted, lastRead, unread, marked, mention, last, ts, peer, peerRead, peerReadAt, count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.v(.id, "")
        kind = c.v(.kind, "dm")
        name = c.v(.name, "")
        avatar = c.v(.avatar, "")
        pinned = c.v(.pinned, false)
        muted = c.v(.muted, false)
        lastRead = c.v(.lastRead, 0)
        unread = c.v(.unread, 0)
        marked = c.v(.marked, false)
        mention = c.o(.mention)
        last = c.o(.last)
        ts = c.v(.ts, 0)
        peer = c.o(.peer)
        peerRead = c.v(.peerRead, 0)
        peerReadAt = c.v(.peerReadAt, 0)
        count = c.v(.count, 0)
    }

    var isGroup: Bool { kind == "group" }
    var title: String {
        if !name.isEmpty { return name }
        if let peer { return peer.name }
        return isGroup ? String(localized: "Group") : String(localized: "Chat")
    }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(ts) / 1000) }
}

struct Member: Codable, Identifiable, Hashable {
    var id: String
    var username: String
    var display: String
    var avatar: String
    var role: String
    var online: Bool

    enum CodingKeys: String, CodingKey { case id, username, display, avatar, role, online }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.v(.id, ""); username = c.v(.username, ""); display = c.v(.display, ""); avatar = c.v(.avatar, "")
        role = c.v(.role, "member"); online = c.v(.online, false)
    }

    var user: User { User(id: id, username: username, display: display, avatar: avatar) }
}

// MARK: - Notes, people, moments, memories

struct Note: Codable, Hashable {
    var text: String
    var created: Int
    var expires: Int
}

struct FriendNote: Codable, Hashable, Identifiable {
    var user: User
    var text: String
    var created: Int
    var expires: Int
    var id: String { user.id }
}

struct MomentMedia: Codable, Hashable {
    var url: String
    var type: String
    var w: Double?
    var h: Double?
    var alt: String?

    enum CodingKeys: String, CodingKey { case url, type, w, h, alt }

    init(url: String, type: String, w: Double?, h: Double?, alt: String? = nil) {
        self.url = url; self.type = type; self.w = w; self.h = h; self.alt = alt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = c.v(.url, ""); type = c.v(.type, "image"); w = c.o(.w); h = c.o(.h); alt = c.o(.alt)
    }

    var isVideo: Bool { type.hasPrefix("video") }
    var aspect: CGFloat {
        guard let w, let h, w > 0, h > 0 else { return 1 }
        return CGFloat(w / h)
    }
}

struct MomentComment: Codable, Hashable, Identifiable {
    var id: String
    var user: User
    var text: String
    var created: Int
    var mine: Bool
}

struct Moment: Codable, Hashable, Identifiable {
    var id: String
    var user: User
    var text: String
    var media: [MomentMedia]
    var created: Int
    var audience: String
    var tags: [User]
    var commenting: String
    var canComment: Bool
    var scheduled: Bool
    var mine: Bool
    var liked: Bool
    var likes: [User]
    var comments: [MomentComment]

    enum CodingKeys: String, CodingKey {
        case id, user, text, media, created, audience, tags, commenting, canComment, scheduled, mine, liked, likes, comments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.v(.id, "")
        user = c.v(.user, User(id: ""))
        text = c.v(.text, "")
        media = c.v(.media, [])
        created = c.v(.created, 0)
        audience = c.v(.audience, "everyone")
        tags = c.v(.tags, [])
        commenting = c.v(.commenting, "everyone")
        canComment = c.v(.canComment, true)
        scheduled = c.v(.scheduled, false)
        mine = c.v(.mine, false)
        liked = c.v(.liked, false)
        likes = c.v(.likes, [])
        comments = c.v(.comments, [])
    }

    var date: Date { Date(timeIntervalSince1970: TimeInterval(created) / 1000) }
}

struct MemoryChat: Codable, Hashable {
    var name: String
    var avatar: String
    var kind: String
}

struct MemoryItem: Codable, Hashable, Identifiable {
    var id: String
    var room: String
    var chat: MemoryChat?
    var from: User?
    var mine: Bool
    var ts: Int
    var type: String
    var url: String
    var w: Double
    var h: Double
    var dur: Double

    enum CodingKeys: String, CodingKey { case id, room, chat, from, mine, ts, type, url, w, h, dur }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.v(.id, ""); room = c.v(.room, ""); chat = c.o(.chat); from = c.o(.from); mine = c.v(.mine, false)
        ts = c.v(.ts, 0); type = c.v(.type, "photo"); url = c.v(.url, ""); w = c.v(.w, 0); h = c.v(.h, 0); dur = c.v(.dur, 0)
    }

    var date: Date { Date(timeIntervalSince1970: TimeInterval(ts) / 1000) }
}

// MARK: - Stickers

struct Sticker: Codable, Hashable, Identifiable {
    var id: String
    var emoji: String
    var kind: String   // static | animated | video
    var nt: Bool       // no still picture of its own

    enum CodingKeys: String, CodingKey { case id, emoji, kind, nt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.v(.id, ""); emoji = c.v(.emoji, ""); kind = c.v(.kind, "static"); nt = c.v(.nt, false)
    }

    init(id: String, emoji: String, kind: String) {
        self.id = id; self.emoji = emoji; self.kind = kind; self.nt = false
    }
}

struct StickerSet: Codable, Hashable, Identifiable {
    var name: String
    var title: String
    var stickers: [Sticker]
    var id: String { name }
}

struct StickerPack: Codable, Hashable, Identifiable {
    var name: String
    var title: String
    var count: Int
    var cover: Sticker?
    var added: Bool
    var id: String { name }
}

// MARK: - Settings shared across devices (src/prefs.js)

struct Prefs: Codable, Hashable {
    var receipts: Bool
    var call: String

    enum CodingKeys: String, CodingKey { case receipts, call }

    init() { receipts = true; call = "" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        receipts = c.v(.receipts, true)
        call = c.v(.call, "")
    }
}

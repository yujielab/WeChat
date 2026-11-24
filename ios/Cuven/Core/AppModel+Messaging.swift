import SwiftUI
import UIKit

struct PendingMedia {
    var data: Data
    var contentType: String
    var kind: String          // upload kind: image | voice | video | file
    var name: String
    var w: Double?
    var h: Double?
    var dur: Double?
    var uploaded: UploadResult?
}

/// A message on its way (public/js/outbox.js): sent in order, waiting out a
/// lost connection; a retry carries the same localId, so the hub never keeps two.
struct OutboxItem {
    let cid: String
    let room: String
    var body: [String: Any]
    var media: PendingMedia?
    var attempts = 0
}

extension AppModel {
    static func newCid() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<12).map { _ in alphabet.randomElement()! })
    }

    // MARK: - Threads

    func messages(_ room: String) -> [Message] {
        let all = threads[room]?.messages ?? []
        return hiddenMessages.isEmpty ? all : all.filter { !hiddenMessages.contains($0.id) }
    }

    /// Delete for me: gone from this device; they'll still see it.
    func deleteLocally(_ m: Message) {
        if m.local == .failed { discardFailed(m); return }
        withAnimation(Motion.ui) { _ = hiddenMessages.insert(m.id) }
        // Only on this device, so it comes straight back with Undo.
        show(String(localized: "Deleted for you"), undo: { [weak self] in
            withAnimation(Motion.ui) { _ = self?.hiddenMessages.remove(m.id) }
        })
    }

    func loadThread(_ room: String) async {
        var t = threads[room] ?? ThreadData()
        if t.loading { return }
        if t.loaded {
            await loadNewer(room)
            return
        }
        t.loading = true
        t.failed = false
        threads[room] = t
        do {
            let r: MessagesResponse = try await api.get("/api/messages", query: ["room": room, "limit": "40"])
            var cur = threads[room] ?? ThreadData()
            let locals = cur.messages.filter { $0.isLocal }
            cur.messages = merge(r.messages, locals)
            cur.hasMore = r.messages.count >= 40
            cur.loaded = true
            cur.loading = false
            threads[room] = cur
            persist()
        } catch {
            threads[room]?.loading = false
            threads[room]?.failed = true
        }
        if let r = self.room(room), r.isGroup, members[room] == nil { await loadMembers(room) }
    }

    func loadOlder(_ room: String) async {
        guard var t = threads[room], t.hasMore, !t.loading, let first = t.messages.first(where: { !$0.isLocal }) else { return }
        t.loading = true
        threads[room] = t
        do {
            let r: MessagesResponse = try await api.get("/api/messages", query: ["room": room, "before": String(first.ts), "limit": "40"])
            var cur = threads[room] ?? ThreadData()
            cur.messages = merge(r.messages + cur.messages, [])
            cur.hasMore = r.messages.count >= 40
            cur.loading = false
            threads[room] = cur
        } catch {
            threads[room]?.loading = false
        }
    }

    func loadNewer(_ room: String) async {
        guard let t = threads[room], let last = t.messages.last(where: { !$0.isLocal }) else { return }
        guard let r: MessagesResponse = try? await api.get("/api/messages", query: ["room": room, "after": String(last.ts), "limit": "100"]) else { return }
        guard !r.messages.isEmpty else { return }
        var cur = threads[room] ?? ThreadData()
        cur.messages = merge(cur.messages + r.messages, [])
        threads[room] = cur
    }

    /// Server messages (deduplicated by id, newest copy wins) plus local ones, in time order.
    private func merge(_ list: [Message], _ locals: [Message]) -> [Message] {
        var seen: [String: Int] = [:]
        var out: [Message] = []
        for m in list {
            if let i = seen[m.id] { out[i] = m } else { seen[m.id] = out.count; out.append(m) }
        }
        let landed = Set(out.compactMap { $0.localId })
        out += locals.filter { !landed.contains($0.localId ?? "") }
        return out.sorted { $0.ts == $1.ts ? $0.id < $1.id : $0.ts < $1.ts }
    }

    func loadMembers(_ room: String) async {
        guard let r: RoomResponse = try? await api.get("/api/room/\(room)") else { return }
        if let m = r.members { members[room] = m }
        if let fresh = r.room, let i = roomIndex(room) { rooms[i] = fresh }
        indexUsers()
    }

    // MARK: - Incoming

    func receive(_ msg: Message, localId: String?) {
        var t = threads[msg.room] ?? ThreadData()
        if let localId, let i = t.messages.firstIndex(where: { $0.localId == localId && $0.isLocal }) {
            t.messages.remove(at: i)
        }
        if let i = t.messages.firstIndex(where: { $0.id == msg.id }) {
            t.messages[i] = msg
        } else {
            t.messages.append(msg)
            t.messages.sort { $0.ts == $1.ts ? $0.id < $1.id : $0.ts < $1.ts }
        }
        if threads[msg.room] != nil || t.loaded { threads[msg.room] = t }

        let mine = msg.sender == me?.id
        typing[msg.room]?[msg.sender] = nil

        guard let i = roomIndex(msg.room) else {
            Task { await refreshRooms() }
            return
        }
        var r = rooms[i]
        let isNew = (r.last?.id != msg.id) && msg.ts >= (r.last?.ts ?? 0)
        if msg.ts >= (r.last?.ts ?? 0) || r.last?.id == msg.id { r.last = msg }
        r.ts = max(r.ts, msg.ts)
        if isNew && !mine && !msg.isSystem && !msg.isRevoked {
            if visibleRoom == msg.room && appActive {
                r.lastRead = msg.ts
                socket.send(["t": "read", "room": msg.room, "ts": msg.ts])
            } else {
                r.unread += 1
                r.marked = false
                if let mentions = msg.meta?.mentions, let me, mentions.contains(me.id), r.mention == nil { r.mention = msg.id }
                Haptics.soft()
            }
            notifyIfAway(msg)
        }
        if mine { r.unread = 0; r.marked = false }
        rooms[i] = r
        if isNew {
            withAnimation(.smooth(duration: 0.32)) { rooms = sortRooms(rooms) }
        }
    }

    func replace(_ msg: Message) {
        updateMessage(msg.room, msg.id) { m in
            let local = m.local
            m = msg
            m.local = local
        }
        if let i = roomIndex(msg.room), rooms[i].last?.id == msg.id { rooms[i].last = msg }
    }

    func updateMessage(_ room: String, _ id: String, _ change: (inout Message) -> Void) {
        guard var t = threads[room], let i = t.messages.firstIndex(where: { $0.id == id }) else { return }
        change(&t.messages[i])
        threads[room] = t
    }

    func markRead(_ room: String) {
        guard let i = roomIndex(room) else { return }
        let last = threads[room]?.messages.last(where: { !$0.isLocal })?.ts ?? rooms[i].last?.ts ?? 0
        if rooms[i].unread > 0 || rooms[i].marked || rooms[i].mention != nil {
            rooms[i].unread = 0
            rooms[i].marked = false
            rooms[i].mention = nil
        }
        if last > rooms[i].lastRead || last == 0 {
            rooms[i].lastRead = max(rooms[i].lastRead, last)
            socket.send(["t": "read", "room": room, "ts": last > 0 ? last : Int(Date().timeIntervalSince1970 * 1000)])
        }
    }

    // MARK: - Sending

    private func optimistic(_ room: String, type: String, text: String = "", meta: MessageMeta? = nil, replyTo: Message? = nil) -> Message {
        let cid = Self.newCid()
        var m = Message(id: "local:\(cid)", room: room, sender: me?.id ?? "", ts: Int(Date().timeIntervalSince1970 * 1000),
                        type: type, body: text, meta: meta, replyTo: replyTo?.id, localId: cid, local: .sending)
        if let replyTo {
            m.reply = ReplySnapshot(id: replyTo.id, sender: replyTo.sender, ts: replyTo.ts, type: replyTo.type,
                                    state: replyTo.state, body: replyTo.body, url: replyTo.meta?.url, emoji: replyTo.meta?.emoji)
        }
        var t = threads[room] ?? ThreadData()
        t.messages.append(m)
        threads[room] = t
        if let i = roomIndex(room) {
            rooms[i].last = m
            rooms[i].ts = m.ts
            rooms[i].unread = 0
            withAnimation(.smooth(duration: 0.32)) { rooms = sortRooms(rooms) }
        }
        return m
    }

    func sendText(_ text: String, room: String, replyTo: Message? = nil, mentions: [String] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var meta: MessageMeta?
        if !mentions.isEmpty { meta = MessageMeta(); meta?.mentions = mentions }
        let m = optimistic(room, type: "text", text: text, meta: meta, replyTo: replyTo)
        var body: [String: Any] = ["room": room, "type": "text", "text": text]
        if let replyTo { body["replyTo"] = replyTo.id }
        if !mentions.isEmpty { body["mentions"] = mentions }
        enqueue(OutboxItem(cid: m.localId!, room: room, body: body))
        sendTyping("", room: room, force: true)
        Haptics.tap()
    }

    func sendSticker(_ s: Sticker, set: String?, room: String, replyTo: Message? = nil) {
        var meta = MessageMeta()
        meta.id = s.id; meta.kind = s.kind; meta.emoji = s.emoji; meta.set = set
        let m = optimistic(room, type: "sticker", meta: meta, replyTo: replyTo)
        var metaDict: [String: Any] = ["id": s.id, "kind": s.kind, "emoji": s.emoji]
        if let set { metaDict["set"] = set }
        var body: [String: Any] = ["room": room, "type": "sticker", "meta": metaDict]
        if let replyTo { body["replyTo"] = replyTo.id }
        enqueue(OutboxItem(cid: m.localId!, room: room, body: body))
        Haptics.tap()
    }

    /// A place: its point, name and address. It goes with a line of text
    /// and an Apple Maps link too, so a server or web page that doesn't know
    /// places yet still shows something you can open.
    func sendLocation(latitude: Double, longitude: Double, name: String, address: String, room: String, replyTo: Message? = nil) {
        var meta = MessageMeta()
        meta.lat = latitude; meta.lng = longitude; meta.name = name; meta.address = address
        let text = Self.locationText(latitude: latitude, longitude: longitude, name: name, address: address)
        let m = optimistic(room, type: "location", text: text, meta: meta, replyTo: replyTo)
        let metaDict: [String: Any] = ["lat": latitude, "lng": longitude, "name": name, "address": address]
        var body: [String: Any] = ["room": room, "type": "location", "meta": metaDict, "text": text, "caption": text]
        if let replyTo { body["replyTo"] = replyTo.id }
        enqueue(OutboxItem(cid: m.localId!, room: room, body: body))
        Haptics.success()
    }

    static func locationText(latitude: Double, longitude: Double, name: String, address: String) -> String {
        var q = URLComponents(string: "https://maps.apple.com/")!
        q.queryItems = [URLQueryItem(name: "ll", value: String(format: "%.6f,%.6f", latitude, longitude)),
                        URLQueryItem(name: "q", value: name.isEmpty ? String(localized: "Location") : name)]
        return ["📍 " + (name.isEmpty ? String(localized: "Location") : name), address, q.url?.absoluteString ?? ""]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// A photo or drawing: shown at once from the device, then uploaded and sent.
    func sendPicture(_ image: UIImage, room: String, drawing: Bool = false, replyTo: Message? = nil) {
        let prepared = Media.prepare(image, maxSide: 2048, png: drawing)
        var meta = MessageMeta()
        meta.w = Double(prepared.size.width); meta.h = Double(prepared.size.height)
        let type = drawing ? "drawing" : "image"
        let m = optimistic(room, type: type, meta: meta, replyTo: replyTo)
        meta.url = "local:\(m.localId!)"
        updateMessage(room, m.id) { $0.meta = meta }
        ImageStore.shared.put(prepared.image, for: "local:\(m.localId!)")
        var body: [String: Any] = ["room": room, "type": type]
        if let replyTo { body["replyTo"] = replyTo.id }
        let media = PendingMedia(data: prepared.data, contentType: drawing ? "image/png" : "image/jpeg", kind: "image",
                                 name: drawing ? "drawing.png" : "photo.jpg", w: meta.w, h: meta.h)
        enqueue(OutboxItem(cid: m.localId!, room: room, body: body, media: media))
        Haptics.tap()
    }

    func sendVoice(_ data: Data, duration: Double, room: String) {
        var meta = MessageMeta()
        meta.dur = duration
        let m = optimistic(room, type: "voice", meta: meta)
        let media = PendingMedia(data: data, contentType: "audio/mp4", kind: "voice", name: "voice.m4a", dur: duration)
        enqueue(OutboxItem(cid: m.localId!, room: room, body: ["room": room, "type": "voice"], media: media))
    }

    func sendVideo(_ data: Data, size: CGSize, duration: Double, room: String) {
        var meta = MessageMeta()
        meta.w = Double(size.width); meta.h = Double(size.height); meta.dur = duration
        let m = optimistic(room, type: "video", meta: meta)
        let media = PendingMedia(data: data, contentType: "video/mp4", kind: "video", name: "video.mp4",
                                 w: meta.w, h: meta.h, dur: duration)
        enqueue(OutboxItem(cid: m.localId!, room: room, body: ["room": room, "type": "video"], media: media))
    }

    func sendFile(_ data: Data, name: String, contentType: String, room: String) {
        var meta = MessageMeta()
        meta.name = name; meta.size = Double(data.count)
        let m = optimistic(room, type: "file", meta: meta)
        let media = PendingMedia(data: data, contentType: contentType, kind: "file", name: name)
        enqueue(OutboxItem(cid: m.localId!, room: room, body: ["room": room, "type": "file"], media: media))
    }

    private static var failedItems: [String: OutboxItem] = [:]

    func retry(_ m: Message) {
        guard let cid = m.localId, let item = Self.failedItems.removeValue(forKey: cid) else { return }
        updateMessage(m.room, m.id) { $0.local = .sending }
        var again = item
        again.attempts = 0
        enqueue(again)
    }

    func discardFailed(_ m: Message) {
        if let cid = m.localId { Self.failedItems[cid] = nil }
        threads[m.room]?.messages.removeAll { $0.id == m.id }
    }

    private func enqueue(_ item: OutboxItem) {
        outbox.append(item)
        runOutbox()
    }

    func runOutbox() {
        guard !outboxRunning else { return }
        outboxRunning = true
        Task {
            while !outbox.isEmpty {
                var item = outbox[0]
                do {
                    if var media = item.media, media.uploaded == nil {
                        let localMsgId = "local:\(item.cid)"
                        let roomId = item.room
                        let up = try await api.upload(kind: media.kind, data: media.data, contentType: media.contentType,
                                                      room: item.room, name: media.name, width: media.w, height: media.h,
                                                      duration: media.dur, localId: item.cid) { [weak self] p in
                            self?.updateMessage(roomId, localMsgId) { $0.progress = p }
                        }
                        media.uploaded = up
                        item.media = media
                        outbox[0] = item
                    }
                    var body = item.body
                    body["localId"] = item.cid
                    if let up = item.media?.uploaded {
                        var meta: [String: Any] = ["url": up.url]
                        if let t = up.meta.type { meta["type"] = t }
                        if let s = up.meta.size { meta["size"] = s }
                        if let n = up.meta.name { meta["name"] = n }
                        if let w = up.meta.w { meta["w"] = w }
                        if let h = up.meta.h { meta["h"] = h }
                        if let d = up.meta.dur { meta["dur"] = d }
                        body["meta"] = meta
                    }
                    let r: SendResponse = try await api.post("/api/messages", body)
                    outbox.removeFirst()
                    landed(r.msg, cid: item.cid)
                } catch let e as APIError {
                    if e.status == 0 && item.attempts < 4 {
                        item.attempts += 1
                        outbox[0] = item
                        try? await Task.sleep(for: .seconds(Double(item.attempts) * 1.5))
                        continue
                    }
                    outbox.removeFirst()
                    Self.failedItems[item.cid] = item
                    updateMessage(item.room, "local:\(item.cid)") { $0.local = .failed; $0.progress = nil }
                    show(e.message, error: true)
                    Haptics.error()
                } catch {
                    outbox.removeFirst()
                }
            }
            outboxRunning = false
        }
    }

    private func landed(_ msg: Message, cid: String) {
        // Keep the decoded local picture under the server address too, so the bubble doesn't flash.
        if let url = msg.meta?.url, let img = ImageStore.shared.cached("local:\(cid)", maxPixel: 0) {
            ImageStore.shared.put(img, for: url)
        }
        receive(msg, localId: cid)
    }

    // MARK: - Message actions

    func react(_ m: Message, _ emoji: String) async {
        let mine = m.reactions.first { $0.users.contains(me?.id ?? "") }?.emoji
        let next = mine == emoji ? "" : emoji
        // Show it at once; the hub's answer replaces it.
        updateMessage(m.room, m.id) { msg in
            for i in msg.reactions.indices { msg.reactions[i].users.removeAll { $0 == self.me?.id } }
            msg.reactions.removeAll { $0.users.isEmpty }
            if !next.isEmpty, let uid = self.me?.id {
                if let i = msg.reactions.firstIndex(where: { $0.emoji == next }) { msg.reactions[i].users.append(uid) }
                else { msg.reactions.append(Reaction(emoji: next, users: [uid])) }
            }
        }
        do {
            let r: MsgResponse = try await api.post("/api/react", ["id": m.id, "emoji": next])
            replace(r.msg)
        } catch {
            show(error.userMessage, error: true)
        }
    }

    func edit(_ m: Message, text: String) async {
        do {
            let r: MsgResponse = try await api.post("/api/edit", ["id": m.id, "text": text])
            replace(r.msg)
        } catch {
            show(error.userMessage, error: true)
        }
    }

    func revoke(_ m: Message) async {
        do {
            let r: MsgResponse = try await api.post("/api/revoke", ["id": m.id])
            replace(r.msg)
        } catch {
            show(error.userMessage, error: true)
        }
    }

    func canEdit(_ m: Message) -> Bool {
        m.sender == me?.id && m.type == "text" && !m.isRevoked && !m.isLocal &&
            Date().timeIntervalSince(m.date) < 15 * 60 && m.edited < 5
    }

    func canUnsend(_ m: Message) -> Bool {
        m.sender == me?.id && !m.isRevoked && !m.isLocal && !m.isSystem && Date().timeIntervalSince(m.date) < 2 * 60
    }

    /// Live typing (Honk style): what you're writing reaches the others as you write it.
    func sendTyping(_ text: String, room: String, force: Bool = false) {
        let out = livePreview ? String(text.prefix(500)) : (text.isEmpty ? "" : "…")
        if let prev = typingSent[room], !force {
            if prev.0 == out { return }
            if Date().timeIntervalSince(prev.1) < 0.12, !out.isEmpty { return }
        }
        typingSent[room] = (out, Date())
        socket.send(["t": "typing", "room": room, "text": out])
    }

    // MARK: - Room flags

    func setFlag(_ room: String, pinned: Bool? = nil, muted: Bool? = nil, unread: Bool? = nil) async {
        guard let i = roomIndex(room) else { return }
        var body: [String: Any] = [:]
        withAnimation(.smooth(duration: 0.3)) {
            if let pinned { rooms[i].pinned = pinned; body["pinned"] = pinned }
            if let muted { rooms[i].muted = muted; body["muted"] = muted }
            if let unread {
                body["unread"] = unread
                rooms[i].marked = unread
                if !unread { rooms[i].unread = 0; markRead(room) } else if rooms[i].unread == 0 { rooms[i].unread = 1 }
            }
            rooms = sortRooms(rooms)
        }
        do { try await api.post("/api/room/\(room)/flags", body) } catch { show(error.userMessage, error: true) }
    }

    func deleteChat(_ room: String) async {
        let index = rooms.firstIndex { $0.id == room }
        let kept = index.map { rooms[$0] }
        withAnimation(.smooth(duration: 0.3)) { rooms.removeAll { $0.id == room } }
        do { try await api.post("/api/room/\(room)/flags", ["hidden": true]) } catch {
            show(error.userMessage, error: true)
            await refreshRooms()
            return
        }
        // Gone at once, and put back with one tap.
        show(String(localized: "Chat deleted"), undo: { [weak self] in
            guard let self else { return }
            if let kept, !self.rooms.contains(where: { $0.id == room }) {
                withAnimation(.smooth(duration: 0.3)) { self.rooms.insert(kept, at: min(index ?? 0, self.rooms.count)) }
            }
            Task {
                try? await self.api.post("/api/room/\(room)/flags", ["hidden": false])
                await self.refreshRooms()
            }
        })
    }

    func leaveGroup(_ room: String) async {
        do {
            try await api.post("/api/room/\(room)/leave")
            withAnimation { rooms.removeAll { $0.id == room } }
        } catch { show(error.userMessage, error: true) }
    }

    func invite(_ users: [String], to room: String) async {
        do {
            try await api.post("/api/room/\(room)/invite", ["members": users])
            await loadMembers(room)
        } catch { show(error.userMessage, error: true) }
    }

    // MARK: - Writing help (Workers AI)

    func suggest(room: String, draft: String) async -> String {
        guard assistEnabled, predictions else { return "" }
        let r: SuggestResponse? = try? await api.post("/api/ai/suggest", ["room": room, "draft": draft])
        return r?.text ?? ""
    }

    func transcribe(wav: Data) async throws -> String {
        let r: TranscribeResponse = try await api.post("/api/ai/transcribe", ["audio": wav.base64EncodedString()])
        return r.text ?? ""
    }
}

/// Image preparation: scaled to fit, JPEG (photos) or PNG (drawings).
enum Media {
    struct Prepared { var image: UIImage; var data: Data; var size: CGSize }

    static func prepare(_ image: UIImage, maxSide: CGFloat, png: Bool) -> Prepared {
        let src = image.size
        let scale = min(1, maxSide / max(src.width, src.height))
        let target = CGSize(width: (src.width * scale).rounded(), height: (src.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !png
        let out = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        let data = png ? (out.pngData() ?? Data()) : (out.jpegData(compressionQuality: 0.84) ?? Data())
        return Prepared(image: out, data: data, size: target)
    }
}

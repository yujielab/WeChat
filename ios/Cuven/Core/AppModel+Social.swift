import SwiftUI
import UIKit

extension AppModel {
    // MARK: - Contacts and rooms

    func searchUsers(_ q: String) async -> [User] {
        guard !q.isEmpty, let r: UsersResponse = try? await api.get("/api/users/search", query: ["q": q]) else { return [] }
        return r.users
    }

    @discardableResult
    func addContact(_ user: User) async -> String? {
        do {
            let r: ContactAddResponse = try await api.post("/api/contacts/add", ["user": user.id])
            await refreshContacts()
            Haptics.success()
            return r.state
        } catch {
            show(error.userMessage, error: true)
            return nil
        }
    }

    func acceptContact(_ user: User) async {
        do {
            try await api.post("/api/contacts/accept", ["user": user.id])
            await refreshContacts()
            Haptics.success()
        } catch { show(error.userMessage, error: true) }
    }

    func removeContact(_ user: User) async {
        do {
            try await api.post("/api/contacts/remove", ["user": user.id])
            await refreshContacts()
        } catch { show(error.userMessage, error: true) }
    }

    /// Opens (or creates) the one-to-one chat with someone; returns its id.
    func openDM(_ user: User) async -> String? {
        if let existing = rooms.first(where: { !$0.isGroup && $0.peer?.id == user.id }) { return existing.id }
        do {
            let r: RoomResponse = try await api.post("/api/dm", ["user": user.id])
            guard let room = r.room else { return nil }
            if roomIndex(room.id) == nil { withAnimation { rooms = sortRooms(rooms + [room]) } }
            indexUsers()
            return room.id
        } catch {
            show(error.userMessage, error: true)
            return nil
        }
    }

    func createGroup(name: String, members: [String]) async -> String? {
        do {
            let r: RoomResponse = try await api.post("/api/group", ["name": name, "members": members])
            guard let room = r.room else { return nil }
            if roomIndex(room.id) == nil { withAnimation { rooms = sortRooms(rooms + [room]) } }
            return room.id
        } catch {
            show(error.userMessage, error: true)
            return nil
        }
    }

    // MARK: - Notes and people

    func loadNotes() async {
        guard let r: NotesResponse = try? await api.get("/api/notes") else { return }
        withAnimation(.smooth) {
            myNote = r.mine
            notes = r.notes
        }
    }

    func setNote(_ text: String) async {
        do {
            let r: NoteResponse = try await api.post("/api/note", ["text": text])
            withAnimation(.smooth) { myNote = r.mine }
            Haptics.success()
        } catch { show(error.userMessage, error: true) }
    }

    func clearNote() async {
        do {
            try await api.delete("/api/note")
            withAnimation(.smooth) { myNote = nil }
        } catch { show(error.userMessage, error: true) }
    }

    func replyToNote(_ note: FriendNote, text: String) async -> String? {
        guard let room = await openDM(note.user) else { return nil }
        sendText("Replied to your note “\(note.text)”\n\(text)", room: room)
        return room
    }

    func loadPeople() async {
        guard let r: PeopleResponse = try? await api.get("/api/people") else { return }
        withAnimation(.smooth) {
            suggested = r.suggested ?? []
            discover = r.discover ?? []
        }
    }

    func dismissPerson(_ user: User) async {
        withAnimation(.smooth) {
            discover.removeAll { $0.id == user.id }
            suggested.removeAll { $0.id == user.id }
        }
        try? await api.post("/api/people/dismiss", ["user": user.id])
    }

    func friends() async -> [User] {
        (try? await api.get("/api/friends", as: FriendsResponse.self))?.friends ?? []
    }

    // MARK: - Moments

    func feed(before: Int? = nil) async throws -> [Moment] {
        var q: [String: String] = [:]
        if let before { q["before"] = String(before) }
        return try await api.get("/api/moments", query: q, as: MomentsResponse.self).moments
    }

    func profilePage(_ uid: String, before: Int? = nil) async throws -> ProfilePage {
        var q: [String: String] = [:]
        if let before { q["before"] = String(before) }
        return try await api.get("/api/moments/user/\(uid)", query: q)
    }

    func like(_ m: Moment, on: Bool) async -> Moment? {
        Haptics.tap()
        return try? await api.post("/api/moments/\(m.id)/like", ["on": on], as: MomentResponse.self).moment
    }

    func comment(_ m: Moment, text: String) async -> Moment? {
        do {
            return try await api.post("/api/moments/\(m.id)/comments", ["text": text], as: MomentResponse.self).moment
        } catch {
            show(error.userMessage, error: true)
            return nil
        }
    }

    func deleteComment(_ m: Moment, _ c: MomentComment) async -> Moment? {
        let data = try? await api.raw("DELETE", "/api/moments/\(m.id)/comments/\(c.id)")
        return data.flatMap { try? api.decode(MomentResponse.self, $0).moment }
    }

    func deleteMoment(_ m: Moment) async -> Bool {
        do {
            try await api.delete("/api/moments/\(m.id)")
            momentsVersion += 1
            return true
        } catch {
            show(error.userMessage, error: true)
            return false
        }
    }

    struct MomentDraftItem {
        var image: UIImage?
        var videoData: Data?
        var size: CGSize
        var alt: String = ""
    }

    func postMoment(text: String, items: [MomentDraftItem], audience: String, comments: String, tags: [String], at: Date?) async -> Bool {
        do {
            var media: [[String: Any]] = []
            for item in items {
                if let img = item.image {
                    let p = Media.prepare(img, maxSide: 2048, png: false)
                    let up = try await api.upload(kind: "moment", data: p.data, contentType: "image/jpeg", name: "moment",
                                                  width: Double(p.size.width), height: Double(p.size.height))
                    // The server takes "image" or "video" here (hub.js momentMedia), not a MIME type.
                    var m: [String: Any] = ["url": up.url, "type": "image", "w": Int(p.size.width), "h": Int(p.size.height)]
                    if !item.alt.isEmpty { m["alt"] = item.alt }
                    media.append(m)
                } else if let v = item.videoData {
                    let up = try await api.upload(kind: "moment", data: v, contentType: "video/mp4", name: "moment",
                                                  width: Double(item.size.width), height: Double(item.size.height))
                    media.append(["url": up.url, "type": "video", "w": Int(item.size.width), "h": Int(item.size.height)])
                }
            }
            var body: [String: Any] = ["text": text, "media": media, "audience": audience, "comments": comments, "tags": tags]
            if let at { body["at"] = Int(at.timeIntervalSince1970 * 1000) }
            let _: MomentResponse = try await api.post("/api/moments", body)
            momentsVersion += 1
            Haptics.success()
            return true
        } catch {
            show(error.userMessage, error: true)
            return false
        }
    }

    // MARK: - Memories

    func memories(before: Int? = nil, type: String? = nil) async -> MemoriesResponse? {
        var q: [String: String] = ["limit": "60"]
        if let before { q["before"] = String(before) }
        if let type { q["type"] = type }
        return try? await api.get("/api/memories", query: q)
    }

    // MARK: - Profile

    func updateProfile(display: String? = nil, bio: String? = nil, avatar: String? = nil, cover: String? = nil) async -> Bool {
        var body: [String: Any] = [:]
        if let display { body["display"] = display }
        if let bio { body["bio"] = bio }
        if let avatar { body["avatar"] = avatar }
        if let cover { body["cover"] = cover }
        do {
            let r: MeResponse = try await api.post("/api/profile", body)
            withAnimation(.smooth) { me = r.me }
            users[r.me.id] = r.me
            persist()
            return true
        } catch {
            show(error.userMessage, error: true)
            return false
        }
    }

    func uploadAvatar(_ image: UIImage) async -> Bool {
        let square = Media.squareCrop(image, side: 512)
        guard let data = square.jpegData(compressionQuality: 0.88) else { return false }
        do {
            let up = try await api.upload(kind: "avatar", data: data, contentType: "image/jpeg", name: "avatar", width: 512, height: 512)
            ImageStore.shared.put(square, for: up.url)
            return await updateProfile(avatar: up.url)
        } catch {
            show(error.userMessage, error: true)
            return false
        }
    }

    func uploadCover(_ image: UIImage) async -> Bool {
        let p = Media.prepare(image, maxSide: 2048, png: false)
        do {
            let up = try await api.upload(kind: "cover", data: p.data, contentType: "image/jpeg", name: "cover",
                                          width: Double(p.size.width), height: Double(p.size.height))
            ImageStore.shared.put(p.image, for: up.url)
            return await updateProfile(cover: up.url)
        } catch {
            show(error.userMessage, error: true)
            return false
        }
    }

    func recentAvatars() async -> [String] {
        (try? await api.get("/api/profile/avatars", as: AvatarsResponse.self))?.recent ?? []
    }

    func changePassword(current: String, next: String) async -> Bool {
        do {
            let _: MeResponse = try await api.post("/api/password", ["current": current, "next": next])
            Haptics.success()
            show(String(localized: "Password changed"))
            return true
        } catch {
            show(error.userMessage, error: true)
            return false
        }
    }

    func setReceipts(_ on: Bool) async {
        prefs.receipts = on
        if let r: PrefsResponse = try? await api.post("/api/prefs", ["receipts": on]) { prefs = r.prefs }
    }

    // MARK: - Stickers

    func stickerSets() async -> [StickerSet] {
        (try? await api.get("/api/stickers", as: StickersResponse.self))?.sets ?? []
    }

    func stickerCatalog() async -> [StickerPack] {
        (try? await api.get("/api/stickers/catalog", as: CatalogResponse.self))?.packs ?? []
    }

    func setPack(_ name: String, added: Bool) async -> [StickerSet]? {
        do {
            return try await api.post("/api/stickers/mine", added ? ["add": name] : ["remove": name], as: StickersResponse.self).sets
        } catch {
            show(error.userMessage, error: true)
            return nil
        }
    }

    static func stickerPath(_ id: String, set: String?, thumb: Bool = false, anim: Bool = false) -> String {
        let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
        var q: [String] = []
        if let set, !set.isEmpty { q.append("set=\(set)") }
        if thumb { q.append("thumb=1") }
        return "/api/stickers/\(anim ? "anim" : "img")/\(enc)" + (q.isEmpty ? "" : "?" + q.joined(separator: "&"))
    }
}

extension Media {
    static func squareCrop(_ image: UIImage, side: CGFloat) -> UIImage {
        let s = image.size
        let edge = min(s.width, s.height)
        let scale = side / edge
        let drawSize = CGSize(width: s.width * scale, height: s.height * scale)
        let origin = CGPoint(x: (side - drawSize.width) / 2, y: (side - drawSize.height) / 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
    }
}

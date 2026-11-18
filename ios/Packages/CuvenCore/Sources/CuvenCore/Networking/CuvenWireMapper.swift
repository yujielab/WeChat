import Foundation

// MARK: - Wire JSON <-> CuvenCore Domain Normalization (src/store.js, src/hub.js, src/stickers.js)

public enum CuvenJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([CuvenJSONValue])
    case object([String: CuvenJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([CuvenJSONValue].self) {
            self = .array(arr)
        } else if let dict = try? container.decode([String: CuvenJSONValue].self) {
            self = .object(dict)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let b):
            try container.encode(b)
        case .int(let i):
            try container.encode(i)
        case .double(let d):
            try container.encode(d)
        case .string(let s):
            try container.encode(s)
        case .array(let arr):
            try container.encode(arr)
        case .object(let dict):
            try container.encode(dict)
        }
    }

    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        default: return nil
        }
    }

    public var int64Value: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int64(d)
        case .string(let s): return Int64(s)
        default: return nil
        }
    }

    public var intValue: Int? {
        int64Value.map(Int.init)
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .int(let i): return i != 0
        default: return nil
        }
    }

    public var objectValue: [String: CuvenJSONValue]? {
        if case .object(let dict) = self { return dict }
        return nil
    }

    public var arrayValue: [CuvenJSONValue]? {
        if case .array(let arr) = self { return arr }
        return nil
    }

    public subscript(key: String) -> CuvenJSONValue? {
        objectValue?[key]
    }
}

public enum CuvenWireMapper {
    public static func mapUser(_ obj: [String: CuvenJSONValue], onlineSet: Set<String> = []) -> CuvenUser? {
        guard let id = obj["id"]?.stringValue, !id.isEmpty else { return nil }
        let username = obj["username"]?.stringValue ?? id
        let display = obj["display"]?.stringValue ?? username
        let bio = obj["bio"]?.stringValue ?? ""
        let rawAvatar = obj["avatar"]?.stringValue ?? obj["avatarURL"]?.stringValue
        let rawCover = obj["cover"]?.stringValue ?? obj["coverURL"]?.stringValue
        let online = obj["online"]?.boolValue ?? obj["isOnline"]?.boolValue ?? onlineSet.contains(id)
        return CuvenUser(
            id: id,
            username: username,
            display: display.isEmpty ? username : display,
            bio: bio,
            avatarURL: nonEmpty(rawAvatar),
            coverURL: nonEmpty(rawCover),
            dominantTintHex: nonEmpty(obj["dominantTintHex"]?.stringValue),
            isOnline: online
        )
    }

    public static func mapRoom(
        _ obj: [String: CuvenJSONValue],
        roomBackdrops: [String: BackdropPreset] = [:]
    ) -> Room? {
        guard let id = obj["id"]?.stringValue, !id.isEmpty else { return nil }
        let kindStr = obj["kind"]?.stringValue ?? "dm"
        let kind = RoomKind(rawValue: kindStr) ?? .dm
        let peerObj = obj["peer"]?.objectValue
        let peerID = peerObj?["id"]?.stringValue ?? obj["peerUserID"]?.stringValue
        let rawTitle = obj["name"]?.stringValue ?? obj["title"]?.stringValue ?? peerObj?["display"]?.stringValue ?? "Chat"
        let avatar = obj["avatar"]?.stringValue ?? obj["avatarURL"]?.stringValue ?? peerObj?["avatar"]?.stringValue
        let lastObj = obj["last"]?.objectValue
        let lastPreview: String
        if let explicitPreview = obj["lastMessagePreview"]?.stringValue {
            lastPreview = explicitPreview
        } else if let lastObj {
            lastPreview = previewText(forWireMessage: lastObj)
        } else {
            lastPreview = ""
        }
        let ts = obj["ts"]?.int64Value ?? lastObj?["ts"]?.int64Value ?? obj["lastMessageTimestamp"]?.int64Value ?? 0
        let unread = obj["unread"]?.intValue ?? obj["unreadCount"]?.intValue ?? 0
        let pinned = obj["pinned"]?.boolValue ?? obj["isPinned"]?.boolValue ?? false
        let muted = obj["muted"]?.boolValue ?? obj["isMuted"]?.boolValue ?? false
        let marked = obj["marked"]?.boolValue ?? obj["isMarkedUnread"]?.boolValue ?? false
        let hidden = obj["hidden"]?.boolValue ?? obj["isHidden"]?.boolValue ?? false

        let subtitle: String
        if let explicitSub = obj["subtitle"]?.stringValue, !explicitSub.isEmpty {
            subtitle = explicitSub
        } else if kind == .group, let count = obj["count"]?.intValue {
            subtitle = "\(count) members"
        } else if let peerUsername = peerObj?["username"]?.stringValue, !peerUsername.isEmpty {
            subtitle = "@\(peerUsername)"
        } else {
            subtitle = ""
        }

        var memberIDs = obj["memberIDs"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if memberIDs.isEmpty, let peerID {
            memberIDs = [peerID]
        }

        return Room(
            id: id,
            kind: kind,
            title: rawTitle.isEmpty ? "Chat" : rawTitle,
            subtitle: subtitle,
            avatarURL: nonEmpty(avatar),
            peerUserID: nonEmpty(peerID),
            memberIDs: memberIDs,
            lastMessagePreview: lastPreview,
            lastMessageTimestamp: ts,
            unreadCount: unread,
            isPinned: pinned,
            isMuted: muted,
            isMarkedUnread: marked,
            isHidden: hidden,
            backdrop: roomBackdrops[id]
        )
    }

    public static func mapMessage(
        _ obj: [String: CuvenJSONValue],
        localIDOverride: String? = nil,
        displayLookup: [String: String] = [:]
    ) -> Message? {
        guard let id = obj["id"]?.stringValue, !id.isEmpty else { return nil }
        let roomID = obj["room"]?.stringValue ?? obj["roomID"]?.stringValue ?? ""
        let senderID = obj["sender"]?.stringValue ?? obj["senderID"]?.stringValue ?? ""
        let senderDisplay = obj["senderDisplay"]?.stringValue
            ?? displayLookup[senderID]
            ?? (senderID.isEmpty ? "System" : senderID)
        let typeStr = obj["type"]?.stringValue ?? obj["kind"]?.stringValue ?? "text"
        let kind = MessageKind(rawValue: typeStr) ?? .text
        let text = obj["body"]?.stringValue ?? obj["text"]?.stringValue ?? ""
        let meta = obj["meta"]?.objectValue ?? [:]

        var mediaURLs: [String] = obj["mediaURLs"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if mediaURLs.isEmpty {
            if let urls = meta["urls"]?.arrayValue?.compactMap(\.stringValue), !urls.isEmpty {
                mediaURLs = urls
            } else if let singleURL = nonEmpty(meta["url"]?.stringValue) {
                mediaURLs = [singleURL]
            }
        }

        let mediaWidth = obj["mediaWidth"]?.intValue ?? meta["w"]?.intValue
        let mediaHeight = obj["mediaHeight"]?.intValue ?? meta["h"]?.intValue
        let durationSeconds = obj["durationSeconds"]?.doubleValue ?? meta["dur"]?.doubleValue

        var stickerID = nonEmpty(obj["stickerID"]?.stringValue)
        var stickerSet = nonEmpty(obj["stickerSet"]?.stringValue)
        var stickerFormat: StickerFormat? = obj["stickerFormat"]?.stringValue.flatMap(StickerFormat.init(rawValue:))
        if kind == .sticker {
            stickerID = stickerID ?? nonEmpty(meta["id"]?.stringValue)
            stickerSet = stickerSet ?? nonEmpty(meta["set"]?.stringValue)
            if stickerFormat == nil, let rawKind = meta["kind"]?.stringValue {
                stickerFormat = mapStickerFormat(rawKind)
            }
        }

        let replyTo = nonEmpty(obj["replyTo"]?.stringValue ?? obj["replyToMessageID"]?.stringValue)
        let keys = obj["highlightedKeywords"]?.arrayValue?.compactMap(\.stringValue)
            ?? meta["keys"]?.arrayValue?.compactMap(\.stringValue)
            ?? []
        let mentions = obj["mentions"]?.arrayValue?.compactMap(\.stringValue)
            ?? meta["mentions"]?.arrayValue?.compactMap(\.stringValue)
            ?? []

        var reactions: [MessageReaction] = []
        if let rawReactions = obj["reactions"]?.arrayValue {
            for item in rawReactions {
                guard let rObj = item.objectValue,
                      let emoji = rObj["emoji"]?.stringValue else { continue }
                if let users = rObj["users"]?.arrayValue?.compactMap(\.stringValue) {
                    for uid in users {
                        reactions.append(MessageReaction(userID: uid, emoji: emoji))
                    }
                } else if let uid = rObj["userID"]?.stringValue ?? rObj["user"]?.stringValue {
                    reactions.append(MessageReaction(userID: uid, emoji: emoji))
                }
            }
        }

        let editCount = obj["edited"]?.intValue ?? obj["editCount"]?.intValue ?? 0
        var editHistory: [MessageEditEntry] = []
        if let rawHistory = (obj["editHistory"]?.arrayValue ?? meta["history"]?.arrayValue) {
            for entry in rawHistory {
                guard let eObj = entry.objectValue,
                      let eText = eObj["text"]?.stringValue else { continue }
                let editedAt = eObj["editedAt"]?.int64Value ?? eObj["ts"]?.int64Value ?? 0
                editHistory.append(MessageEditEntry(text: eText, editedAt: editedAt))
            }
        }

        let stateStr = obj["state"]?.stringValue ?? obj["deliveryState"]?.stringValue ?? "sent"
        let deliveryState = MessageDeliveryState(rawValue: stateStr) ?? .sent
        let createdAt = obj["ts"]?.int64Value ?? obj["createdAt"]?.int64Value ?? 0

        return Message(
            id: id,
            localID: localIDOverride ?? nonEmpty(obj["localID"]?.stringValue ?? obj["localId"]?.stringValue),
            roomID: roomID,
            senderID: senderID,
            senderDisplay: senderDisplay,
            kind: kind,
            text: text,
            mediaURLs: mediaURLs,
            mediaWidth: mediaWidth,
            mediaHeight: mediaHeight,
            durationSeconds: durationSeconds,
            stickerID: stickerID,
            stickerSet: stickerSet,
            stickerFormat: stickerFormat,
            replyToMessageID: replyTo,
            highlightedKeywords: keys,
            mentions: mentions,
            reactions: reactions,
            editCount: editCount,
            editHistory: editHistory,
            deliveryState: deliveryState,
            createdAt: createdAt
        )
    }

    public static func mapContact(_ obj: [String: CuvenJSONValue], onlineSet: Set<String> = []) -> ContactItem? {
        let userObj = obj["user"]?.objectValue ?? obj
        guard let user = mapUser(userObj, onlineSet: onlineSet) else { return nil }
        let rawState = obj["state"]?.stringValue ?? obj["status"]?.stringValue ?? "accepted"
        let status: ContactStatus
        switch rawState {
        case "pending_out", "pendingOut": status = .pendingOut
        case "pending_in", "pendingIn": status = .pendingIn
        case "blocked": status = .blocked
        case "suggested": status = .suggested
        default: status = .accepted
        }
        return ContactItem(
            user: user,
            status: status,
            mutualNote: nonEmpty(obj["reason"]?.stringValue ?? obj["mutualNote"]?.stringValue)
        )
    }

    public static func mapNote(_ obj: [String: CuvenJSONValue], fallbackUser: CuvenUser? = nil) -> UserNote? {
        guard let text = obj["text"]?.stringValue, !text.isEmpty else { return nil }
        let createdAt = obj["created"]?.int64Value ?? obj["createdAt"]?.int64Value ?? Int64(Date().timeIntervalSince1970 * 1000)
        if let userObj = obj["user"]?.objectValue, let mappedUser = mapUser(userObj) {
            return UserNote(
                userID: mappedUser.id,
                userDisplay: mappedUser.display,
                avatarURL: mappedUser.avatarURL,
                text: text,
                createdAt: createdAt
            )
        }
        if let fallbackUser {
            return UserNote(
                userID: fallbackUser.id,
                userDisplay: fallbackUser.display,
                avatarURL: fallbackUser.avatarURL,
                text: text,
                createdAt: createdAt
            )
        }
        guard let userID = obj["userID"]?.stringValue else { return nil }
        return UserNote(
            userID: userID,
            userDisplay: obj["userDisplay"]?.stringValue ?? userID,
            avatarURL: nonEmpty(obj["avatarURL"]?.stringValue),
            text: text,
            createdAt: createdAt
        )
    }

    public static func mapMoment(_ obj: [String: CuvenJSONValue], onlineSet: Set<String> = []) -> MomentPost? {
        guard let id = obj["id"]?.stringValue, !id.isEmpty else { return nil }
        let authorObj = obj["user"]?.objectValue ?? obj["author"]?.objectValue ?? [:]
        let author = mapUser(authorObj, onlineSet: onlineSet) ?? CuvenUser(
            id: authorObj["id"]?.stringValue ?? "unknown",
            username: authorObj["username"]?.stringValue ?? "user",
            display: authorObj["display"]?.stringValue ?? "User"
        )
        let text = obj["text"]?.stringValue ?? ""
        let createdAt = obj["created"]?.int64Value ?? obj["createdAt"]?.int64Value ?? 0
        let isScheduled = obj["scheduled"]?.boolValue ?? false

        var mediaItems: [MomentMedia] = []
        if let rawMedia = obj["media"]?.arrayValue {
            for (idx, item) in rawMedia.enumerated() {
                guard let mObj = item.objectValue,
                      let url = mObj["url"]?.stringValue, !url.isEmpty else { continue }
                let mType = mObj["type"]?.stringValue ?? "image"
                let isVideo = mObj["isVideo"]?.boolValue ?? (mType == "video")
                mediaItems.append(
                    MomentMedia(
                        id: mObj["id"]?.stringValue ?? "\(id)_m\(idx)",
                        url: url,
                        isVideo: isVideo,
                        width: mObj["w"]?.intValue ?? mObj["width"]?.intValue ?? 1200,
                        height: mObj["h"]?.intValue ?? mObj["height"]?.intValue ?? 1200,
                        altText: nonEmpty(mObj["alt"]?.stringValue ?? mObj["altText"]?.stringValue),
                        filterName: nonEmpty(mObj["filterName"]?.stringValue)
                    )
                )
            }
        }

        let taggedIDs: [String] = (obj["tags"]?.arrayValue ?? []).compactMap { val in
            val.stringValue ?? val.objectValue?["id"]?.stringValue
        }
        let likedIDs: [String] = (obj["likes"]?.arrayValue ?? []).compactMap { val in
            val.stringValue ?? val.objectValue?["id"]?.stringValue
        }
        var comments: [MomentComment] = []
        if let rawComments = obj["comments"]?.arrayValue {
            for cVal in rawComments {
                guard let cObj = cVal.objectValue,
                      let cID = cObj["id"]?.stringValue,
                      let cText = cObj["text"]?.stringValue else { continue }
                let cUser = cObj["user"]?.objectValue
                let authorID = cUser?["id"]?.stringValue ?? cObj["authorID"]?.stringValue ?? ""
                let authorDisplay = cUser?["display"]?.stringValue ?? cObj["authorDisplay"]?.stringValue ?? "User"
                let cCreated = cObj["created"]?.int64Value ?? cObj["createdAt"]?.int64Value ?? createdAt
                comments.append(
                    MomentComment(
                        id: cID,
                        authorID: authorID,
                        authorDisplay: authorDisplay,
                        text: cText,
                        createdAt: cCreated
                    )
                )
            }
        }

        return MomentPost(
            id: id,
            author: author,
            text: text,
            media: mediaItems,
            audience: obj["audience"]?.stringValue ?? "everyone",
            commentPolicy: obj["commenting"]?.stringValue ?? obj["commentPolicy"]?.stringValue ?? "everyone",
            taggedUserIDs: taggedIDs,
            likedUserIDs: likedIDs,
            comments: comments,
            scheduledAt: isScheduled ? createdAt : obj["scheduledAt"]?.int64Value,
            createdAt: createdAt
        )
    }

    public static func mapMemory(_ obj: [String: CuvenJSONValue]) -> MemoryItem? {
        guard let id = obj["id"]?.stringValue,
              let url = obj["url"]?.stringValue ?? obj["mediaURL"]?.stringValue,
              !url.isEmpty else { return nil }
        let rawType = obj["type"]?.stringValue ?? obj["kind"]?.stringValue ?? "photo"
        let kind: MessageKind
        switch rawType {
        case "video": kind = .video
        case "drawing": kind = .drawing
        default: kind = .image
        }
        let createdAt = obj["ts"]?.int64Value ?? obj["createdAt"]?.int64Value ?? 0
        let roomTitle = obj["chat"]?.objectValue?["name"]?.stringValue
            ?? obj["roomTitle"]?.stringValue
            ?? obj["from"]?.objectValue?["display"]?.stringValue
            ?? "Chat"
        let monthKey = obj["monthKey"]?.stringValue ?? monthKeyFromTimestamp(createdAt)
        return MemoryItem(
            id: id,
            kind: kind,
            mediaURL: url,
            caption: obj["caption"]?.stringValue ?? "",
            roomTitle: roomTitle,
            monthKey: monthKey,
            createdAt: createdAt
        )
    }

    public static func mapStickerPack(_ obj: [String: CuvenJSONValue]) -> StickerPack? {
        guard let name = obj["name"]?.stringValue, !name.isEmpty else { return nil }
        let title = obj["title"]?.stringValue ?? name
        let rawStickers = obj["stickers"]?.arrayValue ?? []
        var items: [StickerItem] = []
        for sVal in rawStickers {
            guard let sObj = sVal.objectValue,
                  let id = sObj["id"]?.stringValue else { continue }
            let emoji = sObj["emoji"]?.stringValue ?? "✨"
            let format = mapStickerFormat(sObj["kind"]?.stringValue ?? "static")
            let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
            let encodedSet = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
            let thumbURL = "/api/stickers/img/\(encodedID)?set=\(encodedSet)&thumb=1"
            let assetURL = format == .animatedLottie
                ? "/api/stickers/anim/\(encodedID)?set=\(encodedSet)"
                : "/api/stickers/img/\(encodedID)?set=\(encodedSet)"
            items.append(
                StickerItem(
                    id: id,
                    setName: name,
                    emoji: emoji,
                    format: format,
                    thumbURL: thumbURL,
                    assetURL: assetURL
                )
            )
        }
        let dominantFormat = items.first?.format ?? .staticWebP
        return StickerPack(name: name, title: title, format: dominantFormat, stickers: items)
    }

    public static func mapStickerFormat(_ wireKind: String) -> StickerFormat {
        switch wireKind {
        case "video", "videoWebM":
            return .videoWebM
        case "animated", "animatedLottie":
            return .animatedLottie
        default:
            return .staticWebP
        }
    }

    public static func wireStickerKind(_ format: StickerFormat) -> String {
        switch format {
        case .staticWebP: return "static"
        case .videoWebM: return "video"
        case .animatedLottie: return "animated"
        }
    }

    public static func parseBackdropPreset(_ raw: String?) -> BackdropPreset? {
        guard let raw, !raw.isEmpty else { return nil }
        let cleaned = raw.hasPrefix("preset:") ? String(raw.dropFirst("preset:".count)) : raw
        return BackdropPreset(rawValue: cleaned)
    }

    public static func mergeServerPrefs(_ wirePrefs: [String: CuvenJSONValue], into current: UserPrefs) -> (UserPrefs, [String: BackdropPreset]) {
        var next = current
        if let chatPreset = parseBackdropPreset(wirePrefs["chat"]?.stringValue) {
            next.defaultBackdrop = chatPreset
        }
        if let callPreset = parseBackdropPreset(wirePrefs["call"]?.stringValue) {
            next.callBackdrop = callPreset
        }
        if let receipts = wirePrefs["receipts"]?.boolValue {
            next.sendReadReceipts = receipts
        }
        var roomBackdrops: [String: BackdropPreset] = [:]
        if let roomsObj = wirePrefs["rooms"]?.objectValue {
            for (roomID, val) in roomsObj {
                if let preset = parseBackdropPreset(val.stringValue) {
                    roomBackdrops[roomID] = preset
                }
            }
        }
        return (next, roomBackdrops)
    }

    public static func mapInsight(
        _ row: [String: CuvenJSONValue],
        weatherObj: [String: CuvenJSONValue]? = nil
    ) -> RoomInsight? {
        guard let roomID = row["room"]?.stringValue, !roomID.isEmpty else { return nil }
        guard let insight = row["insight"]?.objectValue else { return nil }
        let summary = insight["summary"]?.stringValue
            ?? insight["ongoing"]?.stringValue
            ?? insight["mood"]?.stringValue
            ?? "Active conversation"
        let actionChip = nonEmpty(
            insight["meetup"]?.objectValue?["where"]?.stringValue
            ?? insight["ride"]?.objectValue?["plate"]?.stringValue
            ?? insight["upcoming"]?.stringValue
        )
        let peerCity = nonEmpty(insight["city"]?.stringValue)
        let weatherMatchesRoom = weatherObj?["room"]?.stringValue == roomID || weatherObj?["room"]?.stringValue == ""
        let weatherSummary: String?
        let temperatureText: String?
        if weatherMatchesRoom, let w = weatherObj {
            let condition = w["label"]?.stringValue ?? w["summary"]?.stringValue ?? "Clear"
            let place = w["place"]?.stringValue ?? peerCity ?? ""
            weatherSummary = place.isEmpty ? condition : "\(place) · \(condition)"
            if let temp = w["temp"]?.intValue {
                let unit = (w["unit"]?.stringValue ?? "c").uppercased()
                temperatureText = "\(temp)°\(unit)"
            } else {
                temperatureText = nil
            }
        } else {
            weatherSummary = peerCity
            temperatureText = nil
        }

        return RoomInsight(
            id: "insight_\(roomID)",
            roomID: roomID,
            summary: summary,
            actionChip: actionChip,
            peerLocalTime: nonEmpty(insight["localTime"]?.stringValue),
            weatherSummary: weatherSummary,
            temperatureText: temperatureText
        )
    }

    public static func monthKeyFromTimestamp(_ timestampMs: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let comps = calendar.dateComponents([.year, .month], from: date)
        let year = comps.year ?? 2026
        let month = comps.month ?? 11
        return String(format: "%04d-%02d", year, month)
    }

    public static func previewText(forWireMessage msg: [String: CuvenJSONValue]) -> String {
        if msg["state"]?.stringValue == "revoked" {
            return "Message unsent"
        }
        let type = msg["type"]?.stringValue ?? "text"
        let body = msg["body"]?.stringValue ?? ""
        switch type {
        case "text", "system":
            return String(body.prefix(120))
        case "image":
            return body.isEmpty ? "[Photo]" : body
        case "drawing":
            return "[Drawing]"
        case "voice":
            return "[Voice]"
        case "video":
            return "[Video]"
        case "file":
            return "[File]"
        case "call":
            return "[Call]"
        case "sticker":
            let emoji = msg["meta"]?.objectValue?["emoji"]?.stringValue ?? ""
            return emoji.isEmpty ? "[Sticker]" : "[Sticker] \(emoji)"
        default:
            return "[Message]"
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

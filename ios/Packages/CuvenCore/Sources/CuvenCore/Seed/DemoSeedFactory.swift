import Foundation

// MARK: - Canonical Cuven Rich Demo Seed Dataset (spec_miner_survey_2 § 4.3.C & src/stickers.js)

public struct DemoSeedDataset: Codable, Equatable, Sendable {
    public var currentUser: CuvenUser
    public var rooms: [Room]
    public var messagesByRoom: [String: [Message]]
    public var typingPreviewByRoom: [String: String]
    public var ghostSuggestionByRoom: [String: String]
    public var contacts: [ContactItem]
    public var suggestedPeople: [CuvenUser]
    public var myNote: UserNote
    public var notes: [UserNote]
    public var moments: [MomentPost]
    public var memories: [MemoryItem]
    public var stickerPacks: [StickerPack]
    public var installedStickerPackNames: Set<String>
    public var insightsByRoom: [String: RoomInsight]
    public var prefs: UserPrefs
    public var aiMemories: [AIMemoryItem]
    public var aiRoutineBuckets: [AIRoutineHourBucket]
    public var recentAvatarURLs: [String]

    public init(
        currentUser: CuvenUser,
        rooms: [Room],
        messagesByRoom: [String: [Message]],
        typingPreviewByRoom: [String: String],
        ghostSuggestionByRoom: [String: String],
        contacts: [ContactItem],
        suggestedPeople: [CuvenUser],
        myNote: UserNote,
        notes: [UserNote],
        moments: [MomentPost],
        memories: [MemoryItem],
        stickerPacks: [StickerPack],
        installedStickerPackNames: Set<String>,
        insightsByRoom: [String: RoomInsight],
        prefs: UserPrefs,
        aiMemories: [AIMemoryItem],
        aiRoutineBuckets: [AIRoutineHourBucket],
        recentAvatarURLs: [String]
    ) {
        self.currentUser = currentUser
        self.rooms = rooms
        self.messagesByRoom = messagesByRoom
        self.typingPreviewByRoom = typingPreviewByRoom
        self.ghostSuggestionByRoom = ghostSuggestionByRoom
        self.contacts = contacts
        self.suggestedPeople = suggestedPeople
        self.myNote = myNote
        self.notes = notes
        self.moments = moments
        self.memories = memories
        self.stickerPacks = stickerPacks
        self.installedStickerPackNames = installedStickerPackNames
        self.insightsByRoom = insightsByRoom
        self.prefs = prefs
        self.aiMemories = aiMemories
        self.aiRoutineBuckets = aiRoutineBuckets
        self.recentAvatarURLs = recentAvatarURLs
    }
}

public enum DemoSeedFactory {
    /// Canonical 14 Telegram sticker pack presets (`src/stickers.js:35-50`).
    public static let presetStickerCatalog: [(name: String, title: String, format: StickerFormat, emojis: [String])] = [
        ("HandDrawnEmoji", "Hand-drawn", .staticWebP, ["😊", "😂", "❤️", "👍", "✨", "🤔", "🥳", "🙏"]),
        ("GameEmoji", "Games", .staticWebP, ["🎮", "🕹️", "🏆", "🎲", "🎯", "⚡", "🔥", "👾"]),
        ("ParisOlympicEmoji", "Paris Olympics", .animatedLottie, ["🥇", "🏃", "🏊", "🚴", "🎾", "⚽", "🤸", "🏅"]),
        ("UtyaDuck", "Little Duck", .animatedLottie, ["🦆", "💛", "👋", "☕", "🎉", "😴", "💻", "😎"]),
        ("HotCherry", "Hot Cherry", .animatedLottie, ["🍒", "😍", "💃", "😘", "✨", "🙈", "💢", "🥰"]),
        ("AnimatedEmojies", "Animated Emoji", .animatedLottie, ["😂", "❤️", "😮", "😢", "👍", "🔥", "🎉", "🤩"]),
        ("LadyCat", "Lady Cat", .staticWebP, ["🐱", "💅", "🎀", "😸", "🐾", "💤", "🍵", "🌸"]),
        ("MottyEmojiAnim", "Motty Cat", .animatedLottie, ["😺", "🫶", "🍡", "✨", "😭", "🤗", "🎈", "🌟"]),
        ("SiameseCatLive", "Siamese Cat", .videoWebM, ["🐈", "👀", "🐟", "🛋️", "😼", "🧶", "🌙", "💙"]),
        ("LINE_Mochi_Mochi_Peach_Cat", "Peach Cat", .staticWebP, ["🍑", "🐱", "💕", "🥰", "🍰", "🌸", "😴", "🙌"]),
        ("CAT_CAT_CAT111", "Kiang Cat", .staticWebP, ["😹", "🐟", "📦", "🐾", "😼", "⚡", "🍜", "🎵"]),
        ("Pusheen_3", "Pusheen", .staticWebP, ["🍩", "🍕", "🐱", "🍪", "💻", "🛋️", "🎂", "✨"]),
        ("utya_vk", "Utya Duck", .staticWebP, ["🦆", "🧢", "📱", "🎧", "🍕", "👍", "😂", "🚀"]),
        ("AngryDuck", "Angry Duck", .animatedLottie, ["🦆", "😤", "💢", "🔥", "🤨", "📢", "⚡", "😎"])
    ]

    public static func buildStickerPacks() -> [StickerPack] {
        presetStickerCatalog.map { entry in
            let items: [StickerItem] = entry.emojis.enumerated().map { idx, emoji in
                let stickerID = "\(entry.name.lowercased())_\(String(format: "%02d", idx + 1))"
                let thumbURL = "cuven-demo://sticker/\(entry.name)/\(stickerID)?thumb=1&emoji=\(emoji.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
                let assetURL = "cuven-demo://sticker/\(entry.name)/\(stickerID)?format=\(entry.format.rawValue)"
                return StickerItem(
                    id: stickerID,
                    setName: entry.name,
                    emoji: emoji,
                    format: entry.format,
                    thumbURL: thumbURL,
                    assetURL: assetURL
                )
            }
            return StickerPack(
                name: entry.name,
                title: entry.title,
                format: entry.format,
                stickers: items
            )
        }
    }

    public static func makeDataset(
        anchorTimestampMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> DemoSeedDataset {
        let minute: Int64 = 60_000
        let hour: Int64 = 3_600_000
        let day: Int64 = 86_400_000

        // MARK: Personas
        let tokio = CuvenUser(
            id: "u_tokio",
            username: "tokio",
            display: "Tokio",
            bio: "Designing quiet tools for folded glass · Hangzhou / Tokyo",
            avatarURL: "cuven-demo://avatar/tokio",
            coverURL: "cuven-demo://cover/mist",
            dominantTintHex: "#1877F2",
            isOnline: true
        )

        let coisini = CuvenUser(
            id: "u_coisini",
            username: "coisini",
            display: "Coisini",
            bio: "Alpine light, analog film & mountain trails",
            avatarURL: "cuven-demo://avatar/coisini",
            coverURL: "cuven-demo://cover/dawn",
            dominantTintHex: "#E07A5F",
            isOnline: true
        )

        let hong = CuvenUser(
            id: "u_hong",
            username: "hong",
            display: "Hong",
            bio: "West Lake walks · hotpot & espresso",
            avatarURL: "cuven-demo://avatar/hong",
            coverURL: "cuven-demo://cover/ocean",
            dominantTintHex: "#26808C",
            isOnline: true
        )

        let gang = CuvenUser(
            id: "u_gang",
            username: "gang",
            display: "Gang",
            bio: "Weekend ridge runner · Longjing tea",
            avatarURL: "cuven-demo://avatar/gang",
            coverURL: "cuven-demo://cover/mint",
            dominantTintHex: "#00AD59",
            isOnline: false
        )

        let alani = CuvenUser(
            id: "u_alani",
            username: "alani",
            display: "Alani",
            bio: "Industrial & material research",
            avatarURL: "cuven-demo://avatar/alani",
            coverURL: "cuven-demo://cover/sand",
            dominantTintHex: "#C97A40",
            isOnline: true
        )

        let sofie = CuvenUser(
            id: "u_sofie",
            username: "sofie",
            display: "Sofie",
            bio: "Type foundry & editorial specimens",
            avatarURL: "cuven-demo://avatar/sofie",
            coverURL: "cuven-demo://cover/dusk",
            dominantTintHex: "#665AFF",
            isOnline: true
        )

        let mira = CuvenUser(
            id: "u_mira",
            username: "mira",
            display: "Mira",
            bio: "Landscape notes across high passes",
            avatarURL: "cuven-demo://avatar/mira",
            coverURL: "cuven-demo://cover/night",
            dominantTintHex: "#4CC2FF",
            isOnline: false
        )

        let yueee = CuvenUser(
            id: "u_yueee",
            username: "yueee",
            display: "Yueee",
            bio: "Sound synthesis & tactile interfaces",
            avatarURL: "cuven-demo://avatar/yueee",
            coverURL: "cuven-demo://cover/dots",
            dominantTintHex: "#FF6B8B",
            isOnline: true
        )

        // MARK: Thread 1 — Coisini (Pinned, Curved-Tail Runs, PhotoStack, Drawing, Voice, Sticker, Edit, Reply, Reactions)
        let coisiniMessages: [Message] = [
            Message(
                id: "m_coi_1",
                roomID: "room_coisini",
                senderID: coisini.id,
                senderDisplay: coisini.display,
                kind: .text,
                text: "Reached the upper hut just before dawn.",
                createdAt: anchorTimestampMs - 55 * minute
            ),
            Message(
                id: "m_coi_2",
                roomID: "room_coisini",
                senderID: coisini.id,
                senderDisplay: coisini.display,
                kind: .text,
                text: "The cloud sea over the valley looks unreal — bringing film rolls back on Sunday for our West Lake walk!",
                highlightedKeywords: ["Sunday", "West Lake"],
                reactions: [MessageReaction(userID: tokio.id, emoji: "❤️")],
                createdAt: anchorTimestampMs - 54 * minute
            ),
            Message(
                id: "m_coi_3",
                roomID: "room_coisini",
                senderID: coisini.id,
                senderDisplay: coisini.display,
                kind: .image,
                text: "Morning ridge frames",
                mediaURLs: [
                    "cuven-demo://photo/ridge_sunrise_1",
                    "cuven-demo://photo/ridge_sunrise_2",
                    "cuven-demo://photo/ridge_sunrise_3"
                ],
                mediaWidth: 1600,
                mediaHeight: 1200,
                reactions: [
                    MessageReaction(userID: tokio.id, emoji: "😮"),
                    MessageReaction(userID: coisini.id, emoji: "❤️")
                ],
                createdAt: anchorTimestampMs - 50 * minute
            ),
            Message(
                id: "m_coi_4",
                roomID: "room_coisini",
                senderID: tokio.id,
                senderDisplay: tokio.display,
                kind: .text,
                text: "Those three frames fan out like real silver-gelatin prints.",
                replyToMessageID: "m_coi_3",
                deliveryState: .read,
                createdAt: anchorTimestampMs - 45 * minute
            ),
            Message(
                id: "m_coi_5",
                roomID: "room_coisini",
                senderID: tokio.id,
                senderDisplay: tokio.display,
                kind: .text,
                text: "Let's meet at 3:30pm by the Clarinetta studio courtyard on Sunday.",
                highlightedKeywords: ["3:30pm", "Clarinetta", "Sunday"],
                reactions: [MessageReaction(userID: coisini.id, emoji: "👍")],
                editCount: 1,
                editHistory: [
                    MessageEditEntry(
                        text: "Let's meet at 3:00pm by the studio courtyard on Sunday.",
                        editedAt: anchorTimestampMs - 43 * minute
                    )
                ],
                deliveryState: .read,
                createdAt: anchorTimestampMs - 44 * minute
            ),
            Message(
                id: "m_coi_6",
                roomID: "room_coisini",
                senderID: coisini.id,
                senderDisplay: coisini.display,
                kind: .voice,
                text: "Wind on the ridge + espresso order",
                mediaURLs: ["cuven-demo://voice/coisini_ridge_note.wav"],
                durationSeconds: 14.5,
                createdAt: anchorTimestampMs - 32 * minute
            ),
            Message(
                id: "m_coi_7",
                roomID: "room_coisini",
                senderID: tokio.id,
                senderDisplay: tokio.display,
                kind: .drawing,
                text: "Trail map sketch",
                mediaURLs: ["cuven-demo://drawing/west_lake_route.png"],
                mediaWidth: 1024,
                mediaHeight: 768,
                deliveryState: .read,
                createdAt: anchorTimestampMs - 20 * minute
            ),
            Message(
                id: "m_coi_8",
                roomID: "room_coisini",
                senderID: coisini.id,
                senderDisplay: coisini.display,
                kind: .sticker,
                text: "🦆",
                stickerID: "utyaduck_04",
                stickerSet: "UtyaDuck",
                stickerFormat: .animatedLottie,
                createdAt: anchorTimestampMs - 12 * minute
            )
        ]

        // MARK: Thread 2 — Hong (Hangzhou For You Insights: Ride, Meetup, Photo, Weather)
        let hongMessages: [Message] = [
            Message(
                id: "m_hong_1",
                roomID: "room_hong",
                senderID: hong.id,
                senderDisplay: hong.display,
                kind: .image,
                text: "The beach · Sand at sunset before boarding",
                mediaURLs: ["cuven-demo://photo/beach_sunset"],
                mediaWidth: 1440,
                mediaHeight: 1080,
                createdAt: anchorTimestampMs - 28 * minute
            ),
            Message(
                id: "m_hong_2",
                roomID: "room_hong",
                senderID: hong.id,
                senderDisplay: hong.display,
                kind: .text,
                text: "Landed in Hangzhou! Car ZA·12345 (White BYD) arrives in 8 min — see you at Starbucks West Lake at 15:30, craving hotpot tonight.",
                highlightedKeywords: ["Hangzhou", "ZA·12345", "Starbucks West Lake", "15:30"],
                createdAt: anchorTimestampMs - 6 * minute
            )
        ]

        // MARK: Thread 3 — Gang (Unread Badge = 2)
        let gangMessages: [Message] = [
            Message(
                id: "m_gang_1",
                roomID: "room_gang",
                senderID: gang.id,
                senderDisplay: gang.display,
                kind: .text,
                text: "Hiking this weekend?",
                createdAt: anchorTimestampMs - 40 * minute
            ),
            Message(
                id: "m_gang_2",
                roomID: "room_gang",
                senderID: gang.id,
                senderDisplay: gang.display,
                kind: .text,
                text: "Nine Creeks to Longjing ridge looks crystal clear Saturday morning.",
                highlightedKeywords: ["Saturday morning", "Longjing"],
                createdAt: anchorTimestampMs - 39 * minute
            )
        ]

        // MARK: Thread 4 — Design Team Group (@Mentions, Multi-sender runs, System Event)
        let designTeamMessages: [Message] = [
            Message(
                id: "m_dt_0",
                roomID: "room_design_team",
                senderID: "",
                senderDisplay: "System",
                kind: .system,
                text: "Tokio created Design Team",
                createdAt: anchorTimestampMs - 6 * hour
            ),
            Message(
                id: "m_dt_1",
                roomID: "room_design_team",
                senderID: coisini.id,
                senderDisplay: coisini.display,
                kind: .text,
                text: "Checked the 52pt vertical DuoRail spacing on Closed portrait (170pt top reserve) — clears the camera & silent ring cleanly.",
                highlightedKeywords: ["52pt", "170pt"],
                createdAt: anchorTimestampMs - 95 * minute
            ),
            Message(
                id: "m_dt_2",
                roomID: "room_design_team",
                senderID: mira.id,
                senderDisplay: mira.display,
                kind: .image,
                text: "Clarinetta specimen sheet",
                mediaURLs: ["cuven-demo://photo/clarinetta_specimen"],
                mediaWidth: 1500,
                mediaHeight: 1125,
                createdAt: anchorTimestampMs - 70 * minute
            ),
            Message(
                id: "m_dt_3",
                roomID: "room_design_team",
                senderID: hong.id,
                senderDisplay: hong.display,
                kind: .text,
                text: "@Tokio verified the 525pt zero-reflow thread width when sliding between List|Thread (342|609) and Thread|Details (525|426)!",
                highlightedKeywords: ["525pt", "342|609", "525|426"],
                mentions: [tokio.id],
                reactions: [
                    MessageReaction(userID: tokio.id, emoji: "🙏"),
                    MessageReaction(userID: coisini.id, emoji: "❤️")
                ],
                createdAt: anchorTimestampMs - 15 * minute
            )
        ]

        // MARK: Rooms
        let rooms: [Room] = [
            Room(
                id: "room_coisini",
                kind: .dm,
                title: coisini.display,
                subtitle: "@\(coisini.username)",
                avatarURL: coisini.avatarURL,
                peerUserID: coisini.id,
                memberIDs: [tokio.id, coisini.id],
                lastMessagePreview: "[Sticker] 🦆",
                lastMessageTimestamp: anchorTimestampMs - 12 * minute,
                unreadCount: 0,
                isPinned: true,
                isMuted: false,
                isMarkedUnread: false,
                isHidden: false,
                backdrop: .mist
            ),
            Room(
                id: "room_design_team",
                kind: .group,
                title: "Design Team",
                subtitle: "4 members · Mentioned you",
                avatarURL: "cuven-demo://avatar/design_team",
                peerUserID: nil,
                memberIDs: [tokio.id, coisini.id, hong.id, mira.id],
                lastMessagePreview: "Hong: @Tokio verified the 525pt zero-reflow thread width…",
                lastMessageTimestamp: anchorTimestampMs - 15 * minute,
                unreadCount: 1,
                isPinned: true,
                isMuted: false,
                isMarkedUnread: false,
                isHidden: false,
                backdrop: .ocean
            ),
            Room(
                id: "room_hong",
                kind: .dm,
                title: hong.display,
                subtitle: "@\(hong.username)",
                avatarURL: hong.avatarURL,
                peerUserID: hong.id,
                memberIDs: [tokio.id, hong.id],
                lastMessagePreview: "Landed in Hangzhou! Car ZA·12345 (White BYD) arrives in 8 min…",
                lastMessageTimestamp: anchorTimestampMs - 6 * minute,
                unreadCount: 1,
                isPinned: false,
                isMuted: false,
                isMarkedUnread: false,
                isHidden: false,
                backdrop: .dawn
            ),
            Room(
                id: "room_gang",
                kind: .dm,
                title: gang.display,
                subtitle: "@\(gang.username)",
                avatarURL: gang.avatarURL,
                peerUserID: gang.id,
                memberIDs: [tokio.id, gang.id],
                lastMessagePreview: "Nine Creeks to Longjing ridge looks crystal clear Saturday morning.",
                lastMessageTimestamp: anchorTimestampMs - 39 * minute,
                unreadCount: 2,
                isPinned: false,
                isMuted: false,
                isMarkedUnread: false,
                isHidden: false,
                backdrop: .mint
            )
        ]

        // MARK: Contacts & Suggested People
        let contacts: [ContactItem] = [
            ContactItem(user: alani, status: .pendingIn, mutualNote: "Wants to add you · 2 mutual friends"),
            ContactItem(user: coisini, status: .accepted, mutualNote: "Off to the mountains 🏔️"),
            ContactItem(user: hong, status: .accepted, mutualNote: "Hangzhou · West Lake"),
            ContactItem(user: gang, status: .accepted, mutualNote: "Longjing trail crew"),
            ContactItem(user: sofie, status: .accepted, mutualNote: "Tap to chat")
        ]

        let suggestedPeople: [CuvenUser] = [sofie, mira, yueee]

        // MARK: 24-Hour Notes
        let myNote = UserNote(
            userID: tokio.id,
            userDisplay: tokio.display,
            avatarURL: tokio.avatarURL,
            text: "Coffee anyone? ☕️",
            createdAt: anchorTimestampMs - 2 * hour
        )

        let notes: [UserNote] = [
            UserNote(
                userID: coisini.id,
                userDisplay: coisini.display,
                avatarURL: coisini.avatarURL,
                text: "Off to the mountains 🏔️ back Sunday",
                createdAt: anchorTimestampMs - 45 * minute
            ),
            UserNote(
                userID: hong.id,
                userDisplay: hong.display,
                avatarURL: hong.avatarURL,
                text: "Landed in Hangzhou 🌿",
                createdAt: anchorTimestampMs - 10 * minute
            ),
            UserNote(
                userID: sofie.id,
                userDisplay: sofie.display,
                avatarURL: sofie.avatarURL,
                text: "Typesetting Clarinetta specimens ✨",
                createdAt: anchorTimestampMs - 3 * hour
            )
        ]

        // MARK: Moments Feed (Coisini photo + video, Mira 3-photo public carousel, Tokio post)
        let moments: [MomentPost] = [
            MomentPost(
                id: "mom_coisini_1",
                author: coisini,
                text: "Sunrise on the ridge this morning ☀️",
                media: [
                    MomentMedia(
                        id: "mom_m_1",
                        url: "cuven-demo://photo/ridge_sunrise_1",
                        isVideo: false,
                        width: 1600,
                        height: 1000,
                        altText: "Golden alpine ridge above morning sea of clouds",
                        filterName: "Warm"
                    )
                ],
                audience: "friends",
                commentPolicy: "everyone",
                taggedUserIDs: [tokio.id],
                likedUserIDs: [tokio.id, hong.id],
                comments: [
                    MomentComment(
                        id: "mc_1",
                        authorID: tokio.id,
                        authorDisplay: tokio.display,
                        text: "That horizon glow is pure magic.",
                        createdAt: anchorTimestampMs - 35 * minute
                    )
                ],
                scheduledAt: nil,
                createdAt: anchorTimestampMs - 48 * minute
            ),
            MomentPost(
                id: "mom_mira_public",
                author: mira,
                text: "Three days in the mountains — the light up there is something else entirely.",
                media: [
                    MomentMedia(
                        id: "mom_m_2a",
                        url: "cuven-demo://photo/mira_pass_1",
                        isVideo: false,
                        width: 1200,
                        height: 1500,
                        altText: "Granite ridge trail under crisp cobalt sky",
                        filterName: "Vivid"
                    ),
                    MomentMedia(
                        id: "mom_m_2b",
                        url: "cuven-demo://photo/mira_pass_2",
                        isVideo: false,
                        width: 1200,
                        height: 1500,
                        altText: "Alpine lake reflecting late afternoon amber light",
                        filterName: "Warm"
                    ),
                    MomentMedia(
                        id: "mom_m_2c",
                        url: "cuven-demo://photo/mira_pass_3",
                        isVideo: false,
                        width: 1200,
                        height: 1500,
                        altText: "Camp lantern beside frost-dusted pine needles",
                        filterName: "Fade"
                    )
                ],
                audience: "everyone",
                commentPolicy: "everyone",
                taggedUserIDs: [],
                likedUserIDs: [coisini.id],
                comments: [],
                scheduledAt: nil,
                createdAt: anchorTimestampMs - 3 * hour
            ),
            MomentPost(
                id: "mom_coisini_clip",
                author: coisini,
                text: "Clip from the trail 🌲",
                media: [
                    MomentMedia(
                        id: "mom_m_3",
                        url: "cuven-demo://video/trail_breeze.mp4",
                        isVideo: true,
                        width: 1080,
                        height: 1920,
                        altText: "Morning wind moving across high pine ridge",
                        filterName: "Vivid"
                    )
                ],
                audience: "friends",
                commentPolicy: "friends",
                taggedUserIDs: [],
                likedUserIDs: [tokio.id],
                comments: [],
                scheduledAt: nil,
                createdAt: anchorTimestampMs - 5 * hour
            ),
            MomentPost(
                id: "mom_tokio_1",
                author: tokio,
                text: "Dialing in Liquid Glass rim refraction and zero-reflow 525pt transitions on iPhone Duo.",
                media: [
                    MomentMedia(
                        id: "mom_m_4",
                        url: "cuven-demo://photo/duo_desk_study",
                        isVideo: false,
                        width: 1500,
                        height: 1125,
                        altText: "iPhone Duo unfolded beside espresso cup and grid notebook",
                        filterName: "Cool"
                    )
                ],
                audience: "everyone",
                commentPolicy: "everyone",
                taggedUserIDs: [hong.id],
                likedUserIDs: [coisini.id, hong.id, sofie.id],
                comments: [
                    MomentComment(
                        id: "mc_2",
                        authorID: hong.id,
                        authorDisplay: hong.display,
                        text: "Feels effortlessly native at 120Hz!",
                        createdAt: anchorTimestampMs - 7 * hour
                    )
                ],
                scheduledAt: nil,
                createdAt: anchorTimestampMs - 8 * hour
            )
        ]

        // MARK: Memories Across Months (Photos, Videos, Drawings)
        let currentMonth = CuvenWireMapper.monthKeyFromTimestamp(anchorTimestampMs)
        let prevMonth = CuvenWireMapper.monthKeyFromTimestamp(anchorTimestampMs - 32 * day)
        let twoMonthsAgo = CuvenWireMapper.monthKeyFromTimestamp(anchorTimestampMs - 63 * day)

        let memories: [MemoryItem] = [
            MemoryItem(
                id: "mem_1",
                kind: .image,
                mediaURL: "cuven-demo://photo/ridge_sunrise_1",
                caption: "Morning ridge frames",
                roomTitle: "Coisini",
                monthKey: currentMonth,
                createdAt: anchorTimestampMs - 50 * minute
            ),
            MemoryItem(
                id: "mem_2",
                kind: .drawing,
                mediaURL: "cuven-demo://drawing/west_lake_route.png",
                caption: "Trail map sketch",
                roomTitle: "Coisini",
                monthKey: currentMonth,
                createdAt: anchorTimestampMs - 20 * minute
            ),
            MemoryItem(
                id: "mem_3",
                kind: .image,
                mediaURL: "cuven-demo://photo/beach_sunset",
                caption: "Sand at sunset",
                roomTitle: "Hong",
                monthKey: currentMonth,
                createdAt: anchorTimestampMs - 28 * minute
            ),
            MemoryItem(
                id: "mem_4",
                kind: .image,
                mediaURL: "cuven-demo://photo/clarinetta_specimen",
                caption: "Clarinetta specimen sheet",
                roomTitle: "Design Team",
                monthKey: currentMonth,
                createdAt: anchorTimestampMs - 70 * minute
            ),
            MemoryItem(
                id: "mem_5",
                kind: .video,
                mediaURL: "cuven-demo://video/trail_breeze.mp4",
                caption: "Pine ridge wind",
                roomTitle: "Coisini",
                monthKey: prevMonth,
                createdAt: anchorTimestampMs - 32 * day
            ),
            MemoryItem(
                id: "mem_6",
                kind: .image,
                mediaURL: "cuven-demo://photo/ridge_sunrise_2",
                caption: "Autumn valley mist",
                roomTitle: "Coisini",
                monthKey: prevMonth,
                createdAt: anchorTimestampMs - 35 * day
            ),
            MemoryItem(
                id: "mem_7",
                kind: .drawing,
                mediaURL: "cuven-demo://drawing/hinge_geometry_notes.png",
                caption: "Duo 342|609 -> 525|426 sketch",
                roomTitle: "Design Team",
                monthKey: twoMonthsAgo,
                createdAt: anchorTimestampMs - 63 * day
            ),
            MemoryItem(
                id: "mem_8",
                kind: .image,
                mediaURL: "cuven-demo://photo/duo_desk_study",
                caption: "Late studio prototype",
                roomTitle: "Hong",
                monthKey: twoMonthsAgo,
                createdAt: anchorTimestampMs - 65 * day
            )
        ]

        // MARK: For You Smart Insights (Hangzhou Weather, Ride, Meetup, Photo)
        let insightsByRoom: [String: RoomInsight] = [
            "room_hong": RoomInsight(
                id: "insight_room_hong",
                roomID: "room_hong",
                summary: "Ride ZA·12345 (White BYD · in 8 min) · Meetup at Starbucks West Lake 15:30 · Photo: Sand at sunset · Mood: Tired · Likes hotpot, cats",
                actionChip: "Starbucks West Lake · 15:30",
                peerLocalTime: "15:22 CST",
                weatherSummary: "Hangzhou · Clear · Sunset 17:28",
                temperatureText: "24°C"
            ),
            "room_coisini": RoomInsight(
                id: "insight_room_coisini",
                roomID: "room_coisini",
                summary: "Returning from mountain ridge Sunday · Bringing film rolls for 15:30 courtyard coffee",
                actionChip: "Sunday · 15:30",
                peerLocalTime: "15:22 CST",
                weatherSummary: "Alpine Ridge · Crisp Sun",
                temperatureText: "11°C"
            ),
            "room_gang": RoomInsight(
                id: "insight_room_gang",
                roomID: "room_gang",
                summary: "Saturday morning hike from Nine Creeks to Longjing ridge",
                actionChip: "Reply about Saturday",
                peerLocalTime: "15:22 CST",
                weatherSummary: "Hangzhou · Morning Mist",
                temperatureText: "19°C"
            )
        ]

        // MARK: Stickers, Routine & AI Memory
        let stickerPacks = buildStickerPacks()
        let installedPacks: Set<String> = [
            "HandDrawnEmoji",
            "GameEmoji",
            "UtyaDuck",
            "AnimatedEmojies",
            "LINE_Mochi_Mochi_Peach_Cat"
        ]

        // Tokio's 24-hour routine curve (wakes ~07:40, peaks 10-11, 15-16, 21-22, sleeps ~00:30)
        let hourlyScores: [Double] = [
            0.34, 0.08, 0.02, 0.00, 0.00, 0.01,
            0.05, 0.38, 0.62, 0.78, 0.91, 0.84,
            0.56, 0.49, 0.72, 0.95, 0.88, 0.64,
            0.52, 0.68, 0.86, 1.00, 0.89, 0.58
        ]
        let routineBuckets = hourlyScores.enumerated().map { hourIdx, score in
            AIRoutineHourBucket(hour: hourIdx, activityScore: score)
        }

        let aiMemories: [AIMemoryItem] = [
            AIMemoryItem(
                id: "mem_style_1",
                category: "Writing Style",
                detail: "courtyard, espresso, crisp, Sunday, ridge, Clarinetta",
                updatedAt: anchorTimestampMs - 20 * minute
            ),
            AIMemoryItem(
                id: "mem_endings_1",
                category: "Phrase Endings",
                detail: "see you soon! · sounds great · save me a dark roast!",
                updatedAt: anchorTimestampMs - 18 * minute
            ),
            AIMemoryItem(
                id: "mem_routine_1",
                category: "Daily Routine",
                detail: "Usually active 07:40–00:30 · Fastest replies between 15:00–17:00 and 21:00–22:30",
                updatedAt: anchorTimestampMs - 15 * minute
            ),
            AIMemoryItem(
                id: "mem_digest_coisini",
                category: "Conversation Digest · Coisini",
                detail: "Planning Sunday 15:30 West Lake / Clarinetta courtyard meetup to review alpine film rolls",
                updatedAt: anchorTimestampMs - 12 * minute
            ),
            AIMemoryItem(
                id: "mem_digest_hong",
                category: "Conversation Digest · Hong",
                detail: "Just landed in Hangzhou (24°C Clear); meeting at Starbucks West Lake at 15:30, dinner hotpot",
                updatedAt: anchorTimestampMs - 6 * minute
            )
        ]

        let recentAvatars: [String] = [
            "cuven-demo://avatar/tokio_film",
            "cuven-demo://avatar/tokio_studio",
            "cuven-demo://avatar/tokio_sketch",
            "cuven-demo://avatar/tokio_mono"
        ]

        return DemoSeedDataset(
            currentUser: tokio,
            rooms: rooms,
            messagesByRoom: [
                "room_coisini": coisiniMessages,
                "room_hong": hongMessages,
                "room_gang": gangMessages,
                "room_design_team": designTeamMessages
            ],
            typingPreviewByRoom: [
                "room_hong": "Ordering two flat whites right now…"
            ],
            ghostSuggestionByRoom: [
                "room_coisini": "See you Sunday at 3:30 — save me a dark roast!",
                "room_hong": "On my way to West Lake now, see you in 10!",
                "room_gang": "Count me in for Saturday morning!"
            ],
            contacts: contacts,
            suggestedPeople: suggestedPeople,
            myNote: myNote,
            notes: notes,
            moments: moments,
            memories: memories,
            stickerPacks: stickerPacks,
            installedStickerPackNames: installedPacks,
            insightsByRoom: insightsByRoom,
            prefs: UserPrefs(),
            aiMemories: aiMemories,
            aiRoutineBuckets: routineBuckets,
            recentAvatarURLs: recentAvatars
        )
    }
}

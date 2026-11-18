import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Spatial & Appearance Enumerations (PROJECT.md § 5.1)

public enum DuoPosture: String, Codable, CaseIterable, Hashable, Sendable {
    case iPhoneCompact      // <700pt, symmetric safe area -> 1-col stack + 56pt horizontal bottom dock
    case iPhoneSplit        // >=700pt, symmetric safe area (e.g., Pro Max 956x440) -> 2-col split + horizontal docks
    case duoClosed          // 466x678pt outer display, safeRight >= 64pt (~91pt, 170pt top reserve) -> 1-col + 52pt vertical DuoRail
    case duoHalfBook        // Book fold: left 462pt | 28..40pt hinge division | right 461pt + right DuoRail
    case duoHalfLaptop      // Tabletop fold: top display pane | hinge division | bottom controls/composer pane
    case duoOpen            // 951x669pt inner display, safeRight >= 64pt (84pt, 118pt top reserve) -> 2-col split (342|609 or 525|426) + hybrid bars
}

public enum NavigationPage: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case chats, moments, memories, friends, you, menu
    public var id: String { rawValue }
}

public enum SidebarScope: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case all, unread, direct, groups
    public var id: String { rawValue }
}

public enum ArtifactMode: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case roomInfo
    case drawingBoard
}

public enum GlassAppearanceMode: String, Codable, CaseIterable, Hashable, Sendable {
    case clear, tinted
}

public enum ComposerGlowStyle: String, Codable, CaseIterable, Hashable, Sendable {
    case ocean, dawn, aurora, off
}

public enum BackdropPreset: String, Codable, CaseIterable, Hashable, Sendable {
    case mist, dawn, mint, sand, ocean, dusk, dots, night
}

public enum AppThemePreference: String, Codable, CaseIterable, Hashable, Sendable {
    case system, light, dark
}

// MARK: - User & Room Models (PROJECT.md § 5.1)

public struct CuvenUser: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var username: String
    public var display: String
    public var bio: String
    public var avatarURL: String?
    public var coverURL: String?
    public var dominantTintHex: String?
    public var isOnline: Bool

    public init(
        id: String,
        username: String,
        display: String,
        bio: String = "",
        avatarURL: String? = nil,
        coverURL: String? = nil,
        dominantTintHex: String? = nil,
        isOnline: Bool = false
    ) {
        self.id = id
        self.username = username
        self.display = display
        self.bio = bio
        self.avatarURL = avatarURL
        self.coverURL = coverURL
        self.dominantTintHex = dominantTintHex
        self.isOnline = isOnline
    }
}

public enum RoomKind: String, Codable, CaseIterable, Hashable, Sendable {
    case dm, group
}

public struct Room: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: RoomKind
    public var title: String
    public var subtitle: String
    public var avatarURL: String?
    public var peerUserID: String?
    public var memberIDs: [String]
    public var lastMessagePreview: String
    public var lastMessageTimestamp: Int64
    public var unreadCount: Int
    public var isPinned: Bool
    public var isMuted: Bool
    public var isMarkedUnread: Bool
    public var isHidden: Bool
    public var backdrop: BackdropPreset?

    public init(
        id: String,
        kind: RoomKind,
        title: String,
        subtitle: String = "",
        avatarURL: String? = nil,
        peerUserID: String? = nil,
        memberIDs: [String] = [],
        lastMessagePreview: String = "",
        lastMessageTimestamp: Int64 = 0,
        unreadCount: Int = 0,
        isPinned: Bool = false,
        isMuted: Bool = false,
        isMarkedUnread: Bool = false,
        isHidden: Bool = false,
        backdrop: BackdropPreset? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.avatarURL = avatarURL
        self.peerUserID = peerUserID
        self.memberIDs = memberIDs
        self.lastMessagePreview = lastMessagePreview
        self.lastMessageTimestamp = lastMessageTimestamp
        self.unreadCount = unreadCount
        self.isPinned = isPinned
        self.isMuted = isMuted
        self.isMarkedUnread = isMarkedUnread
        self.isHidden = isHidden
        self.backdrop = backdrop
    }
}

// MARK: - Messaging Models (PROJECT.md § 5.1)

public enum MessageKind: String, Codable, CaseIterable, Hashable, Sendable {
    case text, image, drawing, sticker, voice, video, file, call, system
}

public enum MessageDeliveryState: String, Codable, CaseIterable, Hashable, Sendable {
    case queued, sending, sent, delivered, read, revoked, failed
}

public struct MessageReaction: Codable, Hashable, Sendable {
    public var userID: String
    public var emoji: String // One of ["❤️", "😂", "👍", "😮", "😢", "🙏"]

    public init(userID: String, emoji: String) {
        self.userID = userID
        self.emoji = emoji
    }
}

public struct MessageEditEntry: Codable, Hashable, Sendable {
    public var text: String
    public var editedAt: Int64

    public init(text: String, editedAt: Int64) {
        self.text = text
        self.editedAt = editedAt
    }
}

public struct Message: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var localID: String?
    public var roomID: String
    public var senderID: String
    public var senderDisplay: String
    public var kind: MessageKind
    public var text: String
    public var mediaURLs: [String]
    public var mediaWidth: Int?
    public var mediaHeight: Int?
    public var durationSeconds: Double?
    public var stickerID: String?
    public var stickerSet: String?
    public var stickerFormat: StickerFormat?
    public var replyToMessageID: String?
    public var highlightedKeywords: [String]
    public var mentions: [String]
    public var reactions: [MessageReaction]
    public var editCount: Int
    public var editHistory: [MessageEditEntry]
    public var deliveryState: MessageDeliveryState
    public var createdAt: Int64

    public init(
        id: String,
        localID: String? = nil,
        roomID: String,
        senderID: String,
        senderDisplay: String,
        kind: MessageKind = .text,
        text: String = "",
        mediaURLs: [String] = [],
        mediaWidth: Int? = nil,
        mediaHeight: Int? = nil,
        durationSeconds: Double? = nil,
        stickerID: String? = nil,
        stickerSet: String? = nil,
        stickerFormat: StickerFormat? = nil,
        replyToMessageID: String? = nil,
        highlightedKeywords: [String] = [],
        mentions: [String] = [],
        reactions: [MessageReaction] = [],
        editCount: Int = 0,
        editHistory: [MessageEditEntry] = [],
        deliveryState: MessageDeliveryState = .sent,
        createdAt: Int64
    ) {
        self.id = id
        self.localID = localID
        self.roomID = roomID
        self.senderID = senderID
        self.senderDisplay = senderDisplay
        self.kind = kind
        self.text = text
        self.mediaURLs = mediaURLs
        self.mediaWidth = mediaWidth
        self.mediaHeight = mediaHeight
        self.durationSeconds = durationSeconds
        self.stickerID = stickerID
        self.stickerSet = stickerSet
        self.stickerFormat = stickerFormat
        self.replyToMessageID = replyToMessageID
        self.highlightedKeywords = highlightedKeywords
        self.mentions = mentions
        self.reactions = reactions
        self.editCount = editCount
        self.editHistory = editHistory
        self.deliveryState = deliveryState
        self.createdAt = createdAt
    }
}

// MARK: - Contacts, Notes, Moments & Memories (PROJECT.md § 5.1)

public enum ContactStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case pendingOut, pendingIn, accepted, blocked, suggested
}

public struct ContactItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String { user.id }
    public var user: CuvenUser
    public var status: ContactStatus
    public var mutualNote: String?

    public init(user: CuvenUser, status: ContactStatus, mutualNote: String? = nil) {
        self.user = user
        self.status = status
        self.mutualNote = mutualNote
    }
}

public struct UserNote: Codable, Identifiable, Hashable, Sendable {
    public var id: String { userID }
    public var userID: String
    public var userDisplay: String
    public var avatarURL: String?
    public var text: String        // <= 60 chars, 24h TTL
    public var createdAt: Int64

    public init(
        userID: String,
        userDisplay: String,
        avatarURL: String? = nil,
        text: String,
        createdAt: Int64
    ) {
        self.userID = userID
        self.userDisplay = userDisplay
        self.avatarURL = avatarURL
        self.text = text
        self.createdAt = createdAt
    }
}

public struct MomentMedia: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var url: String
    public var isVideo: Bool
    public var width: Int
    public var height: Int
    public var altText: String?
    public var filterName: String?

    public init(
        id: String,
        url: String,
        isVideo: Bool = false,
        width: Int = 1200,
        height: Int = 1200,
        altText: String? = nil,
        filterName: String? = nil
    ) {
        self.id = id
        self.url = url
        self.isVideo = isVideo
        self.width = width
        self.height = height
        self.altText = altText
        self.filterName = filterName
    }
}

public struct MomentComment: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var authorID: String
    public var authorDisplay: String
    public var text: String
    public var createdAt: Int64

    public init(
        id: String,
        authorID: String,
        authorDisplay: String,
        text: String,
        createdAt: Int64
    ) {
        self.id = id
        self.authorID = authorID
        self.authorDisplay = authorDisplay
        self.text = text
        self.createdAt = createdAt
    }
}

public struct MomentPost: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var author: CuvenUser
    public var text: String
    public var media: [MomentMedia]
    public var audience: String          // "everyone" | "friends"
    public var commentPolicy: String     // "everyone" | "friends" | "off"
    public var taggedUserIDs: [String]
    public var likedUserIDs: [String]
    public var comments: [MomentComment]
    public var scheduledAt: Int64?
    public var createdAt: Int64

    public init(
        id: String,
        author: CuvenUser,
        text: String,
        media: [MomentMedia] = [],
        audience: String = "everyone",
        commentPolicy: String = "everyone",
        taggedUserIDs: [String] = [],
        likedUserIDs: [String] = [],
        comments: [MomentComment] = [],
        scheduledAt: Int64? = nil,
        createdAt: Int64
    ) {
        self.id = id
        self.author = author
        self.text = text
        self.media = media
        self.audience = audience
        self.commentPolicy = commentPolicy
        self.taggedUserIDs = taggedUserIDs
        self.likedUserIDs = likedUserIDs
        self.comments = comments
        self.scheduledAt = scheduledAt
        self.createdAt = createdAt
    }
}

public struct MemoryItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: MessageKind         // .image, .video, .drawing
    public var mediaURL: String
    public var caption: String
    public var roomTitle: String
    public var monthKey: String          // e.g. "2026-11"
    public var createdAt: Int64

    public init(
        id: String,
        kind: MessageKind,
        mediaURL: String,
        caption: String = "",
        roomTitle: String,
        monthKey: String,
        createdAt: Int64
    ) {
        self.id = id
        self.kind = kind
        self.mediaURL = mediaURL
        self.caption = caption
        self.roomTitle = roomTitle
        self.monthKey = monthKey
        self.createdAt = createdAt
    }
}

// MARK: - Stickers, Insights, Calls, Preferences & AI (PROJECT.md § 5.1)

public enum StickerFormat: String, Codable, CaseIterable, Hashable, Sendable {
    case staticWebP, videoWebM, animatedLottie
}

public struct StickerItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var setName: String
    public var emoji: String
    public var format: StickerFormat
    public var thumbURL: String
    public var assetURL: String

    public init(
        id: String,
        setName: String,
        emoji: String,
        format: StickerFormat,
        thumbURL: String,
        assetURL: String
    ) {
        self.id = id
        self.setName = setName
        self.emoji = emoji
        self.format = format
        self.thumbURL = thumbURL
        self.assetURL = assetURL
    }
}

public struct StickerPack: Codable, Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var title: String
    public var format: StickerFormat
    public var stickers: [StickerItem]

    public init(
        name: String,
        title: String,
        format: StickerFormat,
        stickers: [StickerItem]
    ) {
        self.name = name
        self.title = title
        self.format = format
        self.stickers = stickers
    }
}

public struct RoomInsight: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var roomID: String
    public var summary: String
    public var actionChip: String?
    public var peerLocalTime: String?
    public var weatherSummary: String?
    public var temperatureText: String?

    public init(
        id: String,
        roomID: String,
        summary: String,
        actionChip: String? = nil,
        peerLocalTime: String? = nil,
        weatherSummary: String? = nil,
        temperatureText: String? = nil
    ) {
        self.id = id
        self.roomID = roomID
        self.summary = summary
        self.actionChip = actionChip
        self.peerLocalTime = peerLocalTime
        self.weatherSummary = weatherSummary
        self.temperatureText = temperatureText
    }
}

public enum CallPhase: String, Codable, CaseIterable, Hashable, Sendable {
    case idle, outgoingRinging, incomingRinging, connecting, connected, unstable, ended
}

public enum CallMediaKind: String, Codable, CaseIterable, Hashable, Sendable {
    case audio, video
}

public struct CallSession: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var roomID: String
    public var peerDisplay: String
    public var peerAvatarURL: String?
    public var mediaKind: CallMediaKind
    public var phase: CallPhase
    public var isMuted: Bool
    public var isCameraEnabled: Bool
    public var isSpeakerEnabled: Bool
    public var isMinimizedPiP: Bool
    public var startedAt: Int64?

    public init(
        id: String,
        roomID: String,
        peerDisplay: String,
        peerAvatarURL: String? = nil,
        mediaKind: CallMediaKind = .audio,
        phase: CallPhase = .outgoingRinging,
        isMuted: Bool = false,
        isCameraEnabled: Bool = false,
        isSpeakerEnabled: Bool = true,
        isMinimizedPiP: Bool = false,
        startedAt: Int64? = nil
    ) {
        self.id = id
        self.roomID = roomID
        self.peerDisplay = peerDisplay
        self.peerAvatarURL = peerAvatarURL
        self.mediaKind = mediaKind
        self.phase = phase
        self.isMuted = isMuted
        self.isCameraEnabled = isCameraEnabled
        self.isSpeakerEnabled = isSpeakerEnabled
        self.isMinimizedPiP = isMinimizedPiP
        self.startedAt = startedAt
    }
}

public struct UserPrefs: Codable, Hashable, Sendable {
    public var theme: AppThemePreference
    public var glassMode: GlassAppearanceMode
    public var composerGlow: ComposerGlowStyle
    public var defaultBackdrop: BackdropPreset
    public var callBackdrop: BackdropPreset
    public var sendReadReceipts: Bool
    public var smartAssistEnabled: Bool
    public var routineLearningEnabled: Bool
    public var use24HourTime: Bool

    public init(
        theme: AppThemePreference = .system,
        glassMode: GlassAppearanceMode = .clear,
        composerGlow: ComposerGlowStyle = .ocean,
        defaultBackdrop: BackdropPreset = .mist,
        callBackdrop: BackdropPreset = .dusk,
        sendReadReceipts: Bool = true,
        smartAssistEnabled: Bool = true,
        routineLearningEnabled: Bool = true,
        use24HourTime: Bool = true
    ) {
        self.theme = theme
        self.glassMode = glassMode
        self.composerGlow = composerGlow
        self.defaultBackdrop = defaultBackdrop
        self.callBackdrop = callBackdrop
        self.sendReadReceipts = sendReadReceipts
        self.smartAssistEnabled = smartAssistEnabled
        self.routineLearningEnabled = routineLearningEnabled
        self.use24HourTime = use24HourTime
    }
}

public struct AIRoutineHourBucket: Codable, Identifiable, Hashable, Sendable {
    public var hour: Int // 0..<24
    public var id: Int { hour }
    public var activityScore: Double // 0.0...1.0

    public init(hour: Int, activityScore: Double) {
        self.hour = hour
        self.activityScore = activityScore
    }
}

public struct AIMemoryItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var category: String
    public var detail: String
    public var updatedAt: Int64

    public init(
        id: String,
        category: String,
        detail: String,
        updatedAt: Int64
    ) {
        self.id = id
        self.category = category
        self.detail = detail
        self.updatedAt = updatedAt
    }
}

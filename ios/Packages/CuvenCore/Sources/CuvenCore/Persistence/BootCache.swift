import Foundation

// MARK: - Instant Cold-Start Boot Cache (Stale-While-Revalidate snap:v1, public/js/main.js:65-160)

public struct BootSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: Int = 1

    public var schemaVersion: Int
    public var savedAtMs: Int64
    public var serverBaseURLString: String
    public var currentUser: CuvenUser?
    public var rooms: [Room]
    public var messagesByRoom: [String: [Message]]
    public var contacts: [ContactItem]
    public var suggestedPeople: [CuvenUser]
    public var notes: [UserNote]
    public var myNote: UserNote?
    public var moments: [MomentPost]
    public var memories: [MemoryItem]
    public var stickerPacks: [StickerPack]
    public var installedStickerPackNames: [String]
    public var insightsByRoom: [String: RoomInsight]
    public var prefs: UserPrefs
    public var aiMemories: [AIMemoryItem]
    public var aiRoutineBuckets: [AIRoutineHourBucket]
    public var recentAvatarURLs: [String]

    public init(
        schemaVersion: Int = BootSnapshot.currentSchemaVersion,
        savedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        serverBaseURLString: String = "https://wechat.cuven.us",
        currentUser: CuvenUser? = nil,
        rooms: [Room] = [],
        messagesByRoom: [String: [Message]] = [:],
        contacts: [ContactItem] = [],
        suggestedPeople: [CuvenUser] = [],
        notes: [UserNote] = [],
        myNote: UserNote? = nil,
        moments: [MomentPost] = [],
        memories: [MemoryItem] = [],
        stickerPacks: [StickerPack] = [],
        installedStickerPackNames: [String] = [],
        insightsByRoom: [String: RoomInsight] = [:],
        prefs: UserPrefs = UserPrefs(),
        aiMemories: [AIMemoryItem] = [],
        aiRoutineBuckets: [AIRoutineHourBucket] = [],
        recentAvatarURLs: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.savedAtMs = savedAtMs
        self.serverBaseURLString = serverBaseURLString
        self.currentUser = currentUser
        self.rooms = rooms
        self.messagesByRoom = messagesByRoom
        self.contacts = contacts
        self.suggestedPeople = suggestedPeople
        self.notes = notes
        self.myNote = myNote
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

public final class BootCache: @unchecked Sendable {
    public let directoryURL: URL
    public let snapshotFileURL: URL
    private let lock = NSLock()

    public init(directoryURL: URL? = nil) {
        let resolvedDir: URL
        if let directoryURL {
            resolvedDir = directoryURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            resolvedDir = base.appendingPathComponent("Cuven/BootCache", isDirectory: true)
        }
        self.directoryURL = resolvedDir
        self.snapshotFileURL = resolvedDir.appendingPathComponent("snap_v1.json", isDirectory: false)
    }

    /// Synchronous read for `0ms` frame-1 hydration on cold app launch.
    public func loadSynchronously() -> BootSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: snapshotFileURL.path),
              let data = try? Data(contentsOf: snapshotFileURL),
              let decoded = try? JSONDecoder().decode(BootSnapshot.self, from: data),
              decoded.schemaVersion == BootSnapshot.currentSchemaVersion else {
            return nil
        }
        return decoded
    }

    /// Atomic write so power loss or app kill never leaves a half-written JSON snapshot.
    public func save(_ snapshot: BootSnapshot) throws {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        let data = try encoder.encode(snapshot)
        try data.write(to: snapshotFileURL, options: [.atomic])
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: snapshotFileURL)
    }
}

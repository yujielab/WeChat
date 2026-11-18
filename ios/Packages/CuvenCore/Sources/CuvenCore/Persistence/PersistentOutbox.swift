import Foundation

// MARK: - Persistent FIFO Outbox & Blob Store (Exact Port of public/js/outbox.js & test/outbox.test.js)

public struct OutboxMediaDescriptor: Codable, Equatable, Sendable {
    public var kind: String             // "image" | "drawing" | "voice" | "video" | "file"
    public var contentType: String      // e.g. "image/jpeg", "image/png", "audio/wav"
    public var fileName: String
    public var width: Int?
    public var height: Int?
    public var durationSeconds: Double?
    public var uploadKey: String?

    public init(
        kind: String,
        contentType: String,
        fileName: String,
        width: Int? = nil,
        height: Int? = nil,
        durationSeconds: Double? = nil,
        uploadKey: String? = nil
    ) {
        self.kind = kind
        self.contentType = contentType
        self.fileName = fileName
        self.width = width
        self.height = height
        self.durationSeconds = durationSeconds
        self.uploadKey = uploadKey
    }
}

public struct OutboxUploadedAsset: Codable, Equatable, Sendable {
    public var url: String
    public var meta: [String: CuvenJSONValue]

    public init(url: String, meta: [String: CuvenJSONValue] = [:]) {
        self.url = url
        self.meta = meta
    }
}

public struct OutboxEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: String { cid }
    public var cid: String                              // Client localId (idempotency key)
    public var roomID: String
    public var body: [String: CuvenJSONValue]           // POST /api/messages body (without localId)
    public var optimisticMessage: Message?
    public var enqueuedAtMs: Int64
    public var media: OutboxMediaDescriptor?
    public var uploaded: OutboxUploadedAsset?
    public var isFailed: Bool
    public var errorText: String?
    public var isBlobLost: Bool

    public init(
        cid: String,
        roomID: String,
        body: [String: CuvenJSONValue],
        optimisticMessage: Message? = nil,
        enqueuedAtMs: Int64,
        media: OutboxMediaDescriptor? = nil,
        uploaded: OutboxUploadedAsset? = nil,
        isFailed: Bool = false,
        errorText: String? = nil,
        isBlobLost: Bool = false
    ) {
        self.cid = cid
        self.roomID = roomID
        self.body = body
        self.optimisticMessage = optimisticMessage
        self.enqueuedAtMs = enqueuedAtMs
        self.media = media
        self.uploaded = uploaded
        self.isFailed = isFailed
        self.errorText = errorText
        self.isBlobLost = isBlobLost
    }
}

public final class OutboxBlobStore: @unchecked Sendable {
    public let directoryURL: URL
    private let lock = NSLock()
    private var memoryCache: [String: Data] = [:]

    public init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directoryURL = base.appendingPathComponent("Cuven/OutboxBlobs", isDirectory: true)
        }
    }

    @discardableResult
    public func put(cid: String, data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        memoryCache[cid] = data
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: fileURL(for: cid), options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    public func get(cid: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = memoryCache[cid] {
            return cached
        }
        let url = fileURL(for: cid)
        guard let disk = try? Data(contentsOf: url) else { return nil }
        memoryCache[cid] = disk
        return disk
    }

    public func delete(cid: String) {
        lock.lock()
        defer { lock.unlock() }
        memoryCache.removeValue(forKey: cid)
        try? FileManager.default.removeItem(at: fileURL(for: cid))
    }

    private func fileURL(for cid: String) -> URL {
        let safe = cid.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return directoryURL.appendingPathComponent("\(safe).bin", isDirectory: false)
    }
}

public actor PersistentOutbox {
    public struct Dependencies: Sendable {
        public var loadBlob: @Sendable (String) async -> Data?
        public var deleteBlob: @Sendable (String) async -> Void
        public var uploadMedia: @Sendable (OutboxEntry, Data) async throws -> OutboxUploadedAsset
        public var postMessage: @Sendable ([String: CuvenJSONValue]) async throws -> Message
        public var onLanded: @Sendable (OutboxEntry, Message) async -> Void
        public var onFailed: @Sendable (OutboxEntry, CuvenAPIError) async -> Void
        public var onWaiting: (@Sendable (OutboxEntry, CuvenAPIError) async -> Void)?
        public var onRestore: (@Sendable ([OutboxEntry]) async -> Void)?

        public init(
            loadBlob: @escaping @Sendable (String) async -> Data?,
            deleteBlob: @escaping @Sendable (String) async -> Void,
            uploadMedia: @escaping @Sendable (OutboxEntry, Data) async throws -> OutboxUploadedAsset,
            postMessage: @escaping @Sendable ([String: CuvenJSONValue]) async throws -> Message,
            onLanded: @escaping @Sendable (OutboxEntry, Message) async -> Void,
            onFailed: @escaping @Sendable (OutboxEntry, CuvenAPIError) async -> Void,
            onWaiting: (@Sendable (OutboxEntry, CuvenAPIError) async -> Void)? = nil,
            onRestore: (@Sendable ([OutboxEntry]) async -> Void)? = nil
        ) {
            self.loadBlob = loadBlob
            self.deleteBlob = deleteBlob
            self.uploadMedia = uploadMedia
            self.postMessage = postMessage
            self.onLanded = onLanded
            self.onFailed = onFailed
            self.onWaiting = onWaiting
            self.onRestore = onRestore
        }
    }

    /// 24 hours max queue age (`public/js/outbox.js:24`).
    public static let defaultMaxAgeMs: Int64 = 24 * 60 * 60 * 1000

    /// Exponential retry backoff (`Math.min(30000, 2000 * 2 ** backoff)`, `public/js/outbox.js:78`).
    public static func retryBackoffMilliseconds(forAttempt attempt: Int) -> Int {
        let clamped = max(0, min(10, attempt))
        return min(30_000, 2_000 * (1 << clamped))
    }

    /// Matches `transient(err)` in `public/js/outbox.js:21`.
    public static func isTransientError(_ error: Error) -> Bool {
        if let apiError = error as? CuvenAPIError {
            return apiError.isTransient
        }
        return true
    }

    public let manifestFileURL: URL
    public let maxAgeMs: Int64
    private let nowProvider: @Sendable () -> Int64
    private let autoScheduleRetry: Bool

    private var dependencies: Dependencies?
    private var queue: [OutboxEntry] = []
    private var failed: [OutboxEntry] = []
    private var isPumping: Bool = false
    private var backoffAttempt: Int = 0
    private var retryTask: Task<Void, Never>?
    public private(set) var lastScheduledBackoffMs: Int?

    public init(
        directoryURL: URL? = nil,
        maxAgeMs: Int64 = PersistentOutbox.defaultMaxAgeMs,
        autoScheduleRetry: Bool = true,
        nowProvider: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        let dir: URL
        if let directoryURL {
            dir = directoryURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            dir = base.appendingPathComponent("Cuven/Outbox", isDirectory: true)
        }
        self.manifestFileURL = dir.appendingPathComponent("outbox_queue.json", isDirectory: false)
        self.maxAgeMs = maxAgeMs
        self.autoScheduleRetry = autoScheduleRetry
        self.nowProvider = nowProvider
    }

    public var pendingCount: Int { queue.count }
    public var failedCount: Int { failed.count }

    public func hasPending(cid: String) -> Bool {
        queue.contains { $0.cid == cid }
    }

    public func isFailed(cid: String) -> Bool {
        failed.contains { $0.cid == cid }
    }

    public func keptMediaCIDs() -> [String] {
        (queue + failed).filter { $0.media != nil }.map(\.cid)
    }

    public func snapshotEntries() -> [OutboxEntry] {
        queue + failed
    }

    /// Connects transport callbacks, restores persisted entries from disk, and immediately pumps pending items.
    public func connect(_ deps: Dependencies) async {
        self.dependencies = deps
        let saved = loadManifestFromDisk()
        self.queue = saved.filter { !$0.isFailed }
        self.failed = saved.filter { $0.isFailed }
        if !saved.isEmpty {
            await deps.onRestore?(saved)
        }
        await pump()
    }

    /// Adds a message/media item to the FIFO tail (deduplicating repeated `cid` and replacing any failed copy).
    public func enqueue(
        cid: String,
        roomID: String,
        body: [String: CuvenJSONValue],
        optimisticMessage: Message? = nil,
        media: OutboxMediaDescriptor? = nil
    ) async {
        guard !queue.contains(where: { $0.cid == cid }) else { return }
        failed.removeAll { $0.cid == cid }
        let entry = OutboxEntry(
            cid: cid,
            roomID: roomID,
            body: body,
            optimisticMessage: optimisticMessage,
            enqueuedAtMs: nowProvider(),
            media: media
        )
        queue.append(entry)
        persistManifestToDisk()
        await pump()
    }

    /// Re-queues a failed entry with its original `cid` (preserving any already-completed media upload!).
    @discardableResult
    public func retry(cid: String, updatedOptimisticMessage: Message? = nil) async -> Bool {
        guard let idx = failed.firstIndex(where: { $0.cid == cid }),
              !queue.contains(where: { $0.cid == cid }) else {
            return false
        }
        var entry = failed.remove(at: idx)
        entry.isFailed = false
        entry.errorText = nil
        entry.isBlobLost = false
        entry.enqueuedAtMs = nowProvider()
        if let updatedOptimisticMessage {
            entry.optimisticMessage = updatedOptimisticMessage
        }
        queue.append(entry)
        persistManifestToDisk()
        await pump()
        return true
    }

    /// Resumes immediately when WebSocket reconnects or network returns.
    public func resume() async {
        backoffAttempt = 0
        retryTask?.cancel()
        retryTask = nil
        await pump()
    }

    /// Drops a queued or failed entry (refuses to drop the head entry while actively in-flight).
    @discardableResult
    public func drop(cid: String) async -> Bool {
        if let fIdx = failed.firstIndex(where: { $0.cid == cid }) {
            let removed = failed.remove(at: fIdx)
            persistManifestToDisk()
            if removed.media != nil {
                await dependencies?.deleteBlob(removed.cid)
            }
            return true
        }
        guard let qIdx = queue.firstIndex(where: { $0.cid == cid }) else {
            return false
        }
        if qIdx == 0 && isPumping {
            return false
        }
        let removed = queue.remove(at: qIdx)
        persistManifestToDisk()
        if removed.media != nil {
            await dependencies?.deleteBlob(removed.cid)
        }
        return true
    }

    public func pump() async {
        guard !isPumping, let deps = dependencies else { return }
        isPumping = true
        retryTask?.cancel()
        retryTask = nil
        defer { isPumping = false }

        while let head = queue.first {
            let age = nowProvider() - head.enqueuedAtMs
            if age > maxAgeMs {
                await markHeadFailed(
                    error: CuvenAPIError(message: "Send timed out", statusCode: 408),
                    isBlobLost: false,
                    deps: deps
                )
                continue
            }

            var activeHead = head
            do {
                if activeHead.media != nil && activeHead.uploaded == nil {
                    guard let blob = await deps.loadBlob(activeHead.cid) else {
                        await markHeadFailed(
                            error: CuvenAPIError(message: "Please choose this photo again", statusCode: 410),
                            isBlobLost: true,
                            deps: deps
                        )
                        continue
                    }
                    let uploadedAsset = try await deps.uploadMedia(activeHead, blob)
                    activeHead.uploaded = uploadedAsset
                    if !queue.isEmpty && queue[0].cid == activeHead.cid {
                        queue[0] = activeHead
                        persistManifestToDisk()
                    }
                }

                var postBody = activeHead.body
                if let uploaded = activeHead.uploaded {
                    var mergedMeta = postBody["meta"]?.objectValue ?? [:]
                    for (k, v) in uploaded.meta {
                        mergedMeta[k] = v
                    }
                    mergedMeta["url"] = .string(uploaded.url)
                    postBody["meta"] = .object(mergedMeta)
                }
                postBody["localId"] = .string(activeHead.cid)

                let landedMessage = try await deps.postMessage(postBody)

                if !queue.isEmpty && queue[0].cid == activeHead.cid {
                    queue.removeFirst()
                }
                persistManifestToDisk()
                if activeHead.media != nil {
                    await deps.deleteBlob(activeHead.cid)
                }
                backoffAttempt = 0
                lastScheduledBackoffMs = nil
                await deps.onLanded(activeHead, landedMessage)
            } catch {
                let apiErr = (error as? CuvenAPIError) ?? CuvenAPIError(message: error.localizedDescription, statusCode: 0)
                if Self.isTransientError(apiErr) {
                    await deps.onWaiting?(activeHead, apiErr)
                    let delayMs = Self.retryBackoffMilliseconds(forAttempt: backoffAttempt)
                    backoffAttempt += 1
                    lastScheduledBackoffMs = delayMs
                    if autoScheduleRetry {
                        retryTask = Task { [weak self] in
                            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                            guard !Task.isCancelled else { return }
                            await self?.pump()
                        }
                    }
                    return
                } else {
                    await markHeadFailed(error: apiErr, isBlobLost: false, deps: deps)
                    continue
                }
            }
        }
    }

    private func markHeadFailed(
        error: CuvenAPIError,
        isBlobLost: Bool,
        deps: Dependencies
    ) async {
        guard !queue.isEmpty else { return }
        var entry = queue.removeFirst()
        entry.isFailed = true
        entry.errorText = error.message
        entry.isBlobLost = isBlobLost
        failed.append(entry)
        persistManifestToDisk()
        await deps.onFailed(entry, error)
    }

    private func loadManifestFromDisk() -> [OutboxEntry] {
        guard FileManager.default.fileExists(atPath: manifestFileURL.path),
              let data = try? Data(contentsOf: manifestFileURL),
              let decoded = try? JSONDecoder().decode([OutboxEntry].self, from: data) else {
            return []
        }
        return decoded.filter { !$0.cid.isEmpty && !$0.roomID.isEmpty }
    }

    private func persistManifestToDisk() {
        let all = queue + failed
        do {
            let dir = manifestFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(all)
            try data.write(to: manifestFileURL, options: [.atomic])
        } catch {
            // Non-fatal; in-memory queue remains authoritative for active session.
        }
    }
}

import XCTest
@testable import CuvenCore

private actor OutboxRecorder {
    var landedIDs: [String] = []
    var failedEntries: [(String, Int)] = []
    var waitingCIDs: [String] = []
    var uploadCalls: [String] = []
    var postedPayloads: [[String: CuvenJSONValue]] = []
    var restoredCount: Int = 0

    func recordUpload(_ cid: String) { uploadCalls.append(cid) }
    func recordPost(_ payload: [String: CuvenJSONValue]) { postedPayloads.append(payload) }
    func recordLanded(_ id: String) { landedIDs.append(id) }
    func recordFailed(_ cid: String, status: Int) { failedEntries.append((cid, status)) }
    func recordWaiting(_ cid: String) { waitingCIDs.append(cid) }
    func recordRestored(_ count: Int) { restoredCount = count }
}

final class PersistenceAndOutboxTests: XCTestCase {

    private func makeScratchDir(_ name: String) throws -> URL {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("CuvenCoreTests_\(name)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: base)
        }
        return base
    }

    func testBootCacheAtomicSaveSynchronousLoadAndSchemaValidation() throws {
        let dir = try makeScratchDir("bootcache")
        let cache = BootCache(directoryURL: dir)
        XCTAssertNil(cache.loadSynchronously())

        let seed = DemoSeedFactory.makeDataset(anchorTimestampMs: 1_763_400_000_000)
        let snap = BootSnapshot(
            savedAtMs: 1_763_400_000_000,
            serverBaseURLString: "https://wechat.cuven.us",
            currentUser: seed.currentUser,
            rooms: seed.rooms,
            messagesByRoom: seed.messagesByRoom,
            contacts: seed.contacts,
            suggestedPeople: seed.suggestedPeople,
            notes: seed.notes,
            myNote: seed.myNote,
            moments: seed.moments,
            memories: seed.memories,
            stickerPacks: seed.stickerPacks,
            installedStickerPackNames: Array(seed.installedStickerPackNames),
            insightsByRoom: seed.insightsByRoom,
            prefs: seed.prefs,
            aiMemories: seed.aiMemories,
            aiRoutineBuckets: seed.aiRoutineBuckets,
            recentAvatarURLs: seed.recentAvatarURLs
        )
        try cache.save(snap)

        let loaded = cache.loadSynchronously()
        XCTAssertEqual(loaded, snap)

        // Schema mismatch returns nil safely
        let wrongSchema = BootSnapshot(schemaVersion: 999, currentUser: seed.currentUser)
        try cache.save(wrongSchema)
        XCTAssertNil(cache.loadSynchronously())

        cache.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.snapshotFileURL.path))
    }

    func testPersistentOutboxFIFOIdempotencyAndMediaUploadReuseAcrossTransientRetry() async throws {
        let dir = try makeScratchDir("outbox_retry")
        let blobStore = OutboxBlobStore(directoryURL: dir.appendingPathComponent("blobs", isDirectory: true))
        let outbox = PersistentOutbox(
            directoryURL: dir,
            autoScheduleRetry: false,
            nowProvider: { 1_000_000 }
        )
        let recorder = OutboxRecorder()

        blobStore.put(cid: "cid_photo_1", data: Data([0x89, 0x50, 0x4E, 0x47]))

        actor FlakyGate {
            var shouldFailPost = true
            func consumeFailure() -> Bool {
                if shouldFailPost {
                    shouldFailPost = false
                    return true
                }
                return false
            }
        }
        let gate = FlakyGate()

        let deps = PersistentOutbox.Dependencies(
            loadBlob: { cid in blobStore.get(cid: cid) },
            deleteBlob: { cid in blobStore.delete(cid: cid) },
            uploadMedia: { entry, _ in
                await recorder.recordUpload(entry.cid)
                return OutboxUploadedAsset(
                    url: "/api/media/r2_photo_1.png",
                    meta: ["w": .int(800), "h": .int(600)]
                )
            },
            postMessage: { payload in
                if await gate.consumeFailure() {
                    throw CuvenAPIError(message: "Gateway timeout", statusCode: 502)
                }
                await recorder.recordPost(payload)
                let lid = payload["localId"]?.stringValue ?? ""
                return Message(
                    id: "srv_\(lid)",
                    localID: lid,
                    roomID: payload["room"]?.stringValue ?? "r1",
                    senderID: "u_tokio",
                    senderDisplay: "Tokio",
                    kind: .image,
                    text: payload["body"]?.stringValue ?? "",
                    createdAt: 1_000_005
                )
            },
            onLanded: { _, msg in await recorder.recordLanded(msg.id) },
            onFailed: { entry, err in await recorder.recordFailed(entry.cid, status: err.statusCode) },
            onWaiting: { entry, _ in await recorder.recordWaiting(entry.cid) }
        )

        await outbox.connect(deps)

        // Enqueue media message (1st attempt uploads media, then hits transient 502 on postMessage)
        await outbox.enqueue(
            cid: "cid_photo_1",
            roomID: "r1",
            body: ["room": .string("r1"), "type": .string("image"), "body": .string("Sunrise")],
            media: OutboxMediaDescriptor(kind: "image", contentType: "image/png", fileName: "sun.png")
        )

        // The 502 is waited out: the photo stays at the head with a 2 s back-off.
        let waitingAfterFirst = await recorder.waitingCIDs
        let backoffMs = await outbox.lastScheduledBackoffMs
        XCTAssertEqual(waitingAfterFirst, ["cid_photo_1"])
        XCTAssertEqual(backoffMs, 2_000)
        let pendingMid = await outbox.pendingCount
        XCTAssertEqual(pendingMid, 1)

        // A new message tries the line again at once (as public/js/outbox.js's add → pump):
        // the photo goes first WITHOUT being uploaded again, then the text behind it.
        await outbox.enqueue(
            cid: "cid_text_2",
            roomID: "r1",
            body: ["room": .string("r1"), "type": .string("text"), "body": .string("Follow-up")]
        )
        // Reconnecting with nothing left changes nothing.
        await outbox.resume()

        let uploads = await recorder.uploadCalls
        let landed = await recorder.landedIDs
        let posts = await recorder.postedPayloads
        let pendingEnd = await outbox.pendingCount

        XCTAssertEqual(uploads, ["cid_photo_1"], "Media upload must be reused across transient post retry")
        XCTAssertEqual(landed, ["srv_cid_photo_1", "srv_cid_text_2"])
        XCTAssertEqual(posts.first?["meta"]?["url"]?.stringValue, "/api/media/r2_photo_1.png")
        XCTAssertEqual(posts.map { $0["localId"]?.stringValue }, ["cid_photo_1", "cid_text_2"])
        XCTAssertEqual(pendingEnd, 0)
        XCTAssertNil(blobStore.get(cid: "cid_photo_1"), "Blob must be cleaned up after landing")
    }

    func testPermanent4xxMarksHeadFailedWithoutBlockingSubsequentMessagesAndDiskRestoreWorks() async throws {
        let dir = try makeScratchDir("outbox_4xx")
        let recorder = OutboxRecorder()
        let outbox1 = PersistentOutbox(directoryURL: dir, autoScheduleRetry: false, nowProvider: { 5_000 })

        let deps1 = PersistentOutbox.Dependencies(
            loadBlob: { _ in nil },
            deleteBlob: { _ in },
            uploadMedia: { _, _ in OutboxUploadedAsset(url: "/x") },
            postMessage: { payload in
                let cid = payload["localId"]?.stringValue ?? ""
                if cid == "cid_bad" {
                    throw CuvenAPIError(message: "Payload too large", statusCode: 413)
                }
                return Message(id: "ok_\(cid)", localID: cid, roomID: "r1", senderID: "u1", senderDisplay: "U", text: "ok", createdAt: 5_001)
            },
            onLanded: { _, msg in await recorder.recordLanded(msg.id) },
            onFailed: { entry, err in await recorder.recordFailed(entry.cid, status: err.statusCode) }
        )
        await outbox1.connect(deps1)

        await outbox1.enqueue(cid: "cid_bad", roomID: "r1", body: ["room": .string("r1"), "type": .string("text"), "body": .string("bad")])
        await outbox1.enqueue(cid: "cid_good", roomID: "r1", body: ["room": .string("r1"), "type": .string("text"), "body": .string("good")])

        let failed = await recorder.failedEntries
        let landed = await recorder.landedIDs
        let isBadFailed = await outbox1.isFailed(cid: "cid_bad")
        XCTAssertEqual(failed.count, 1)
        XCTAssertEqual(failed.first?.0, "cid_bad")
        XCTAssertEqual(failed.first?.1, 413)
        XCTAssertTrue(isBadFailed)
        XCTAssertEqual(landed, ["ok_cid_good"])

        // Simulate app restart with a fresh PersistentOutbox reading the persisted manifest
        let outbox2 = PersistentOutbox(directoryURL: dir, autoScheduleRetry: false, nowProvider: { 6_000 })
        await outbox2.connect(
            PersistentOutbox.Dependencies(
                loadBlob: { _ in nil },
                deleteBlob: { _ in },
                uploadMedia: { _, _ in OutboxUploadedAsset(url: "/x") },
                postMessage: { _ in
                    Message(id: "retried_1", roomID: "r1", senderID: "u1", senderDisplay: "U", text: "ok", createdAt: 6_001)
                },
                onLanded: { _, msg in await recorder.recordLanded(msg.id) },
                onFailed: { _, _ in },
                onRestore: { entries in await recorder.recordRestored(entries.count) }
            )
        )
        let restored = await recorder.restoredCount
        XCTAssertEqual(restored, 1)
        let retriedOK = await outbox2.retry(cid: "cid_bad")
        XCTAssertTrue(retriedOK)
        let landedAfterRetry = await recorder.landedIDs
        XCTAssertEqual(landedAfterRetry, ["ok_cid_good", "retried_1"])
    }

    func testBackoffCurveMatchesWebSpec() {
        XCTAssertEqual(PersistentOutbox.retryBackoffMilliseconds(forAttempt: 0), 2_000)
        XCTAssertEqual(PersistentOutbox.retryBackoffMilliseconds(forAttempt: 1), 4_000)
        XCTAssertEqual(PersistentOutbox.retryBackoffMilliseconds(forAttempt: 2), 8_000)
        XCTAssertEqual(PersistentOutbox.retryBackoffMilliseconds(forAttempt: 3), 16_000)
        XCTAssertEqual(PersistentOutbox.retryBackoffMilliseconds(forAttempt: 4), 30_000)
        XCTAssertEqual(PersistentOutbox.retryBackoffMilliseconds(forAttempt: 8), 30_000)
    }
}

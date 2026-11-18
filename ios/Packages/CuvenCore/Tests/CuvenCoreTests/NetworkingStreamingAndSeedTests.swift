import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import CuvenCore

private final class MockHTTPTransport: CuvenHTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try handler(request)
    }
}

private actor MockWebSocketConnection: CuvenWebSocketConnection {
    private var inboundQueue: [String]
    private(set) var sentFrames: [String] = []
    private(set) var isClosed = false

    init(inboundQueue: [String]) {
        self.inboundQueue = inboundQueue
    }

    func send(text: String) async throws {
        sentFrames.append(text)
    }

    func receiveText() async throws -> String {
        if !inboundQueue.isEmpty {
            return inboundQueue.removeFirst()
        }
        try await Task.sleep(nanoseconds: 5_000_000_000)
        throw URLError(.cancelled)
    }

    func close() async {
        isClosed = true
    }
}

private struct MockWebSocketDialer: CuvenWebSocketDialer {
    let connection: MockWebSocketConnection
    func connect(with request: URLRequest) async throws -> CuvenWebSocketConnection {
        connection
    }
}

final class NetworkingStreamingAndSeedTests: XCTestCase {

    func testRequestBuilderHeadersCookieExtractionAndAPIClientBootstrap() async throws {
        let base = URL(string: "https://wechat.cuven.us")!
        let req = try CuvenRequestBuilder.makeHTTPRequest(
            method: "POST",
            path: "/api/messages",
            baseURL: base,
            sessionToken: "tok_abc123",
            timeZone: TimeZone(secondsFromGMT: 8 * 3600)!,
            contentType: "application/json",
            body: Data("{}".utf8)
        )
        XCTAssertEqual(req.url?.absoluteString, "https://wechat.cuven.us/api/messages")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Origin"), "https://wechat.cuven.us")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Cookie"), "cfm_session=tok_abc123")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-tz"), "-480")

        let wsReq = try CuvenRequestBuilder.makeWebSocketRequest(
            baseURL: base,
            sessionToken: "tok_abc123",
            timeZone: TimeZone(secondsFromGMT: 8 * 3600)!
        )
        XCTAssertEqual(wsReq.url?.absoluteString, "wss://wechat.cuven.us/api/ws")
        XCTAssertEqual(wsReq.value(forHTTPHeaderField: "Origin"), "https://wechat.cuven.us")
        XCTAssertEqual(wsReq.value(forHTTPHeaderField: "Cookie"), "cfm_session=tok_abc123")

        // Verify Set-Cookie extraction & login + bootstrap flow via mock transport
        actor TokenBox {
            var observedToken: String?
            func set(_ t: String?) { observedToken = t }
        }
        let tokenBox = TokenBox()

        let transport = MockHTTPTransport { request in
            let path = request.url?.path ?? ""
            if path == "/auth/login" {
                let json = #"{"user":{"id":"u_tokio","username":"tokio","display":"Tokio","bio":"Design"}}"#
                let resp = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Set-Cookie": "cfm_session=live_sess_99; Path=/; HttpOnly; Secure; SameSite=Strict"]
                )!
                return (Data(json.utf8), resp)
            } else if path == "/api/bootstrap" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "cfm_session=live_sess_99")
                let json = #"""
                {
                  "me": {"id":"u_tokio","username":"tokio","display":"Tokio"},
                  "presence": ["u_coisini"],
                  "prefs": {"chat":"preset:ocean","call":"preset:night","receipts":true,"rooms":{"r1":"preset:dawn"}},
                  "contacts": [{"user":{"id":"u_coisini","username":"coisini","display":"Coisini"},"state":"accepted"}],
                  "rooms": [{"id":"r1","kind":"dm","name":"Coisini","peer":{"id":"u_coisini","username":"coisini"},"unread":2,"pinned":true,"ts":1763400000000,"last":{"type":"sticker","meta":{"emoji":"🦆"}}}]
                }
                """#
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (Data(json.utf8), resp)
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(#"{"error":"Not found"}"#.utf8), resp)
        }

        let client = CuvenAPIClient(baseURL: base, transport: transport)
        await client.setSessionTokenObserver { token in
            Task { await tokenBox.set(token) }
        }

        let user = try await client.login(username: "tokio", password: "secret")
        XCTAssertEqual(user.id, "u_tokio")
        let token = await client.sessionToken
        XCTAssertEqual(token, "live_sess_99")

        let boot = try await client.fetchBootstrap()
        XCTAssertEqual(boot.me.display, "Tokio")
        XCTAssertEqual(boot.prefs.defaultBackdrop, .ocean)
        XCTAssertEqual(boot.prefs.callBackdrop, .night)
        XCTAssertEqual(boot.contacts.first?.user.isOnline, true)
        XCTAssertEqual(boot.rooms.first?.backdrop, .dawn)
        XCTAssertEqual(boot.rooms.first?.lastMessagePreview, "[Sticker] 🦆")
    }

    func testWebSocketAll17ServerEventsBackoffAndSessionLifecycle() async throws {
        // Verify backoff curve (600 * 2^retry capped at 10_000ms)
        XCTAssertEqual(CuvenWebSocketClient.backoffMilliseconds(forRetry: 0), 600)
        XCTAssertEqual(CuvenWebSocketClient.backoffMilliseconds(forRetry: 1), 1_200)
        XCTAssertEqual(CuvenWebSocketClient.backoffMilliseconds(forRetry: 4), 9_600)
        XCTAssertEqual(CuvenWebSocketClient.backoffMilliseconds(forRetry: 5), 10_000)

        let rawFrames: [String] = [
            #"{"t":"hello","me":{"id":"u1","username":"tokio","display":"Tokio"},"presence":["u2"]}"#,
            #"{"t":"pong"}"#,
            #"{"t":"msg","localId":"cid_1","msg":{"id":"m1","room":"r1","sender":"u2","type":"text","body":"Hi","ts":100}}"#,
            #"{"t":"read","room":"r1","by":"u2","ts":100,"at":105}"#,
            #"{"t":"keys","id":"m1","room":"r1","keys":["Sunday","West Lake"]}"#,
            #"{"t":"edit","msg":{"id":"m1","room":"r1","sender":"u2","type":"text","body":"Hi!","edited":1,"ts":100}}"#,
            #"{"t":"react","msg":{"id":"m1","room":"r1","sender":"u2","type":"text","body":"Hi!","reactions":[{"emoji":"❤️","users":["u1"]}],"ts":100}}"#,
            #"{"t":"presence","uid":"u2","online":true}"#,
            #"{"t":"typing","room":"r1","uid":"u2","text":"typing live..."}"#,
            #"{"t":"profile","user":{"id":"u2","username":"coisini","display":"Coisini"}}"#,
            #"{"t":"prefs","prefs":{"chat":"preset:mist"}}"#,
            #"{"t":"rooms-dirty"}"#,
            #"{"t":"contacts-dirty"}"#,
            #"{"t":"note","user":"u2"}"#,
            #"{"t":"call","op":"invite","callId":"c1","room":"r1","video":true}"#,
            #"{"t":"moment","id":"mom1","user":"u2"}"#,
            #"{"t":"moment-changed","id":"mom1"}"#,
            #"{"t":"moment-deleted","id":"mom1"}"#
        ]

        let decoded = rawFrames.compactMap(CuvenWebSocketClient.decodeServerEvent(from:))
        XCTAssertEqual(decoded.count, 18) // 17 canonical server push types + pong

        // Verify live actor lifecycle with MockWebSocketDialer
        let mockConn = MockWebSocketConnection(inboundQueue: Array(rawFrames.prefix(3)))
        let api = CuvenAPIClient(sessionToken: "tok_ws")
        let wsClient = CuvenWebSocketClient(apiClient: api, dialer: MockWebSocketDialer(connection: mockConn))

        actor EventCollector {
            var events: [CuvenServerSocketEvent] = []
            func append(_ e: CuvenServerSocketEvent) { events.append(e) }
        }
        let collector = EventCollector()

        await wsClient.start { event in
            Task { await collector.append(event) }
        }
        try await Task.sleep(nanoseconds: 120_000_000)
        await wsClient.send(.typing(roomID: "r1", previewText: "hello honk"))
        await wsClient.stop()

        let received = await collector.events
        XCTAssertEqual(received.count, 3)
        let sent = await mockConn.sentFrames
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(sent[0].contains(#""t":"typing""#))
    }

    func testNDJSONLineParserChunkSplittingAndStreamClient() async throws {
        var parser = NDJSONLineParser()
        let chunk1 = #"{"type":"stage","stage":"search"}"# + "\n" + #"{"type":"que"#
        let chunk2 = #"ries","queries":["hangzhou west lake"],"lang":"en"}"# + "\n"
        let chunk3 = #"{"type":"sources","sources":[{"id":1,"title":"West Lake","url":"https://example.com","site":"example.com","snippet":"UNESCO lake"}]}"# + "\n"
        let chunk4 = #"{"type":"delta","text":"West Lake is "}"# + "\n" + #"{"type":"delta","text":"in Hangzhou."}"# + "\n"
        let chunk5 = #"{"type":"followups","questions":["Best time to visit?"]}"# + "\n" + #"{"type":"done"}"#

        var events: [CuvenExplainStreamEvent] = []
        events += parser.append(chunk1)
        XCTAssertEqual(events, [.stage("search")])
        events += parser.append(chunk2)
        events += parser.append(chunk3)
        events += parser.append(chunk4)
        events += parser.append(chunk5)
        events += parser.flush()

        XCTAssertEqual(events.count, 7)
        XCTAssertEqual(events[1], .queries(queries: ["hangzhou west lake"], language: "en"))
        XCTAssertEqual(events[3], .delta("West Lake is "))
        XCTAssertEqual(events[4], .delta("in Hangzhou."))
        XCTAssertEqual(events[5], .followups(["Best time to visit?"]))
        XCTAssertEqual(events[6], .done)

        // End-to-end NDJSONStreamClient test via mock HTTP transport
        let ndjsonPayload = [
            #"{"type":"stage","stage":"answer"}"#,
            #"{"type":"delta","text":"Clarinetta "}"#,
            #"{"type":"delta","text":"display serif."}"#,
            #"{"type":"done"}"#
        ].joined(separator: "\n") + "\n"

        let transport = MockHTTPTransport { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(ndjsonPayload.utf8), resp)
        }
        let api = CuvenAPIClient(transport: transport)
        let streamClient = NDJSONStreamClient(apiClient: api)

        var streamedDeltas = ""
        var sawDone = false
        for try await ev in streamClient.streamExplainEvents(selectedText: "Clarinetta", context: "Wordmark") {
            if case .delta(let txt) = ev { streamedDeltas += txt }
            if ev == .done { sawDone = true }
        }
        XCTAssertEqual(streamedDeltas, "Clarinetta display serif.")
        XCTAssertTrue(sawDone)
    }

    func testDemoSeedDatasetRichCompleteness() {
        let seed = DemoSeedFactory.makeDataset(anchorTimestampMs: 1_763_400_000_000)
        XCTAssertEqual(seed.currentUser.display, "Tokio")
        XCTAssertEqual(seed.rooms.count, 4)
        XCTAssertEqual(seed.stickerPacks.count, 14, "Must include all 14 canonical Telegram sticker packs")
        XCTAssertEqual(seed.aiRoutineBuckets.count, 24)
        XCTAssertGreaterThanOrEqual(seed.moments.count, 4)
        XCTAssertGreaterThanOrEqual(seed.memories.count, 8)
        XCTAssertNotNil(seed.insightsByRoom["room_hong"])
        XCTAssertEqual(seed.messagesByRoom["room_coisini"]?.first(where: { $0.id == "m_coi_3" })?.mediaURLs.count, 3)
    }
}

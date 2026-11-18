import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Realtime WebSocket Client (/api/ws, 17 Server Event Types, 25s Ping, Backoff Reconnect)

public enum CuvenServerSocketEvent: Equatable, Sendable {
    case hello(me: CuvenUser?, onlineUserIDs: [String])
    case pong
    case message(rawMessage: [String: CuvenJSONValue], localID: String?)
    case readReceipt(roomID: String, userID: String, timestampMs: Int64, readAtMs: Int64)
    case highlightedKeys(messageID: String, roomID: String, keywords: [String])
    case messageEdited(rawMessage: [String: CuvenJSONValue])
    case reactionUpdated(rawMessage: [String: CuvenJSONValue])
    case presence(userID: String, isOnline: Bool)
    case typing(roomID: String, userID: String, previewText: String)
    case profileUpdated(user: CuvenUser)
    case prefsUpdated(rawPrefs: [String: CuvenJSONValue])
    case roomsDirty
    case contactsDirty
    case noteUpdated(userID: String)
    case callSignal(rawPayload: [String: CuvenJSONValue])
    case momentCreated(momentID: String, userID: String)
    case momentChanged(momentID: String)
    case momentDeleted(momentID: String)
    case unknown(type: String, raw: [String: CuvenJSONValue])
}

public enum CuvenClientSocketFrame: Equatable, Sendable {
    case ping
    case read(roomID: String, timestampMs: Int64)
    case typing(roomID: String, previewText: String)
    case call(payload: [String: CuvenJSONValue])

    public func encodedJSONString() -> String? {
        let dict: [String: CuvenJSONValue]
        switch self {
        case .ping:
            dict = ["t": .string("ping")]
        case .read(let roomID, let ts):
            dict = ["t": .string("read"), "room": .string(roomID), "ts": .int(ts)]
        case .typing(let roomID, let text):
            dict = ["t": .string("typing"), "room": .string(roomID), "text": .string(String(text.prefix(500)))]
        case .call(var payload):
            payload["t"] = .string("call")
            dict = payload
        }
        guard let data = try? JSONEncoder().encode(dict) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

public protocol CuvenWebSocketConnection: Sendable {
    func send(text: String) async throws
    func receiveText() async throws -> String
    func close() async
}

public protocol CuvenWebSocketDialer: Sendable {
    func connect(with request: URLRequest) async throws -> CuvenWebSocketConnection
}

public final class URLSessionWebSocketConnectionAdapter: CuvenWebSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    public init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    public func send(text: String) async throws {
        #if canImport(FoundationNetworking)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            task.send(.string(text)) { error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: ()) }
            }
        }
        #else
        try await task.send(.string(text))
        #endif
    }

    public func receiveText() async throws -> String {
        #if canImport(FoundationNetworking)
        let message = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URLSessionWebSocketTask.Message, Error>) in
            task.receive { result in
                cont.resume(with: result)
            }
        }
        #else
        let message = try await task.receive()
        #endif
        switch message {
        case .string(let s):
            return s
        case .data(let d):
            return String(decoding: d, as: UTF8.self)
        @unknown default:
            return ""
        }
    }

    public func close() async {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

public struct URLSessionWebSocketDialer: CuvenWebSocketDialer {
    public init() {}

    public func connect(with request: URLRequest) async throws -> CuvenWebSocketConnection {
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        return URLSessionWebSocketConnectionAdapter(task: task)
    }
}

public actor CuvenWebSocketClient {
    /// Matches `public/js/api.js:79` (`25000ms` ping interval).
    public static let pingIntervalNanoseconds: UInt64 = 25_000_000_000

    /// Matches `public/js/api.js:101` (`Math.min(10000, 600 * 2 ** retry)`).
    public static func backoffMilliseconds(forRetry retry: Int) -> Int {
        let clampedExp = max(0, min(10, retry))
        let scaled = 600 * (1 << clampedExp)
        return min(10_000, scaled)
    }

    /// Decodes a raw JSON frame from `/api/ws` into one of the canonical server events.
    public static func decodeServerEvent(from jsonText: String) -> CuvenServerSocketEvent? {
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONDecoder().decode([String: CuvenJSONValue].self, from: data),
              let type = obj["t"]?.stringValue else {
            return nil
        }

        switch type {
        case "hello":
            let online = obj["presence"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let me = obj["me"]?.objectValue.flatMap { CuvenWireMapper.mapUser($0, onlineSet: Set(online)) }
            return .hello(me: me, onlineUserIDs: online)
        case "pong":
            return .pong
        case "msg":
            guard let msgObj = obj["msg"]?.objectValue else { return nil }
            return .message(rawMessage: msgObj, localID: obj["localId"]?.stringValue)
        case "read":
            return .readReceipt(
                roomID: obj["room"]?.stringValue ?? "",
                userID: obj["by"]?.stringValue ?? "",
                timestampMs: obj["ts"]?.int64Value ?? 0,
                readAtMs: obj["at"]?.int64Value ?? 0
            )
        case "keys":
            return .highlightedKeys(
                messageID: obj["id"]?.stringValue ?? "",
                roomID: obj["room"]?.stringValue ?? "",
                keywords: obj["keys"]?.arrayValue?.compactMap(\.stringValue) ?? []
            )
        case "edit":
            guard let msgObj = obj["msg"]?.objectValue else { return nil }
            return .messageEdited(rawMessage: msgObj)
        case "react":
            guard let msgObj = obj["msg"]?.objectValue else { return nil }
            return .reactionUpdated(rawMessage: msgObj)
        case "presence":
            return .presence(
                userID: obj["uid"]?.stringValue ?? "",
                isOnline: obj["online"]?.boolValue ?? false
            )
        case "typing":
            return .typing(
                roomID: obj["room"]?.stringValue ?? "",
                userID: obj["uid"]?.stringValue ?? "",
                previewText: obj["text"]?.stringValue ?? ""
            )
        case "profile":
            guard let uObj = obj["user"]?.objectValue,
                  let user = CuvenWireMapper.mapUser(uObj) else { return nil }
            return .profileUpdated(user: user)
        case "prefs":
            return .prefsUpdated(rawPrefs: obj["prefs"]?.objectValue ?? [:])
        case "rooms-dirty":
            return .roomsDirty
        case "contacts-dirty":
            return .contactsDirty
        case "note":
            return .noteUpdated(userID: obj["user"]?.stringValue ?? "")
        case "call":
            return .callSignal(rawPayload: obj)
        case "moment":
            return .momentCreated(
                momentID: obj["id"]?.stringValue ?? "",
                userID: obj["user"]?.stringValue ?? ""
            )
        case "moment-changed":
            return .momentChanged(momentID: obj["id"]?.stringValue ?? "")
        case "moment-deleted":
            return .momentDeleted(momentID: obj["id"]?.stringValue ?? "")
        default:
            return .unknown(type: type, raw: obj)
        }
    }

    private let apiClient: CuvenAPIClient
    private let dialer: CuvenWebSocketDialer
    private var connection: CuvenWebSocketConnection?
    private var lifecycleTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var isStopped: Bool = true
    public private(set) var isConnected: Bool = false
    private var eventHandler: (@Sendable (CuvenServerSocketEvent) -> Void)?
    private var connectionStateHandler: (@Sendable (Bool) -> Void)?

    public init(
        apiClient: CuvenAPIClient,
        dialer: CuvenWebSocketDialer = URLSessionWebSocketDialer()
    ) {
        self.apiClient = apiClient
        self.dialer = dialer
    }

    public func start(
        onEvent: @escaping @Sendable (CuvenServerSocketEvent) -> Void,
        onConnectionStateChange: (@Sendable (Bool) -> Void)? = nil
    ) {
        self.eventHandler = onEvent
        self.connectionStateHandler = onConnectionStateChange
        self.isStopped = false
        lifecycleTask?.cancel()
        lifecycleTask = Task { [weak self] in
            await self?.runReconnectLoop()
        }
    }

    public func stop() async {
        isStopped = true
        lifecycleTask?.cancel()
        lifecycleTask = nil
        pingTask?.cancel()
        pingTask = nil
        if let active = connection {
            connection = nil
            await active.close()
        }
        if isConnected {
            isConnected = false
            connectionStateHandler?(false)
        }
    }

    public func wake() {
        guard !isStopped, !isConnected else { return }
        lifecycleTask?.cancel()
        lifecycleTask = Task { [weak self] in
            await self?.runReconnectLoop()
        }
    }

    public func send(_ frame: CuvenClientSocketFrame) async {
        guard isConnected,
              let conn = connection,
              let json = frame.encodedJSONString() else { return }
        try? await conn.send(text: json)
    }

    private func runReconnectLoop() async {
        var retryAttempt = 0
        while !Task.isCancelled && !isStopped {
            do {
                let request = try await apiClient.buildWebSocketRequest()
                let conn = try await dialer.connect(with: request)
                self.connection = conn
                self.isConnected = true
                retryAttempt = 0
                connectionStateHandler?(true)
                startPingLoop(for: conn)

                while !Task.isCancelled && !isStopped {
                    let text = try await conn.receiveText()
                    if let event = Self.decodeServerEvent(from: text) {
                        eventHandler?(event)
                    }
                }
            } catch {
                // Socket closed or failed to connect; clean up and schedule exponential backoff.
            }

            pingTask?.cancel()
            pingTask = nil
            if let old = connection {
                connection = nil
                await old.close()
            }
            if isConnected {
                isConnected = false
                connectionStateHandler?(false)
            }
            guard !Task.isCancelled && !isStopped else { break }
            let delayMs = Self.backoffMilliseconds(forRetry: retryAttempt)
            retryAttempt += 1
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
        }
    }

    private func startPingLoop(for conn: CuvenWebSocketConnection) {
        pingTask?.cancel()
        pingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pingIntervalNanoseconds)
                if Task.isCancelled { break }
                guard let pingText = CuvenClientSocketFrame.ping.encodedJSONString() else { continue }
                try? await conn.send(text: pingText)
            }
        }
    }
}

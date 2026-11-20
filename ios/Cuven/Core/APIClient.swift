import Foundation
import Security

// HTTP access to the hub. The server authenticates with the `cfm_session`
// cookie and only accepts state-changing requests and socket upgrades that
// carry its own Origin (src/index.js), so every request sends both. The
// cookie is kept in the Keychain, per server.

struct APIError: LocalizedError {
    let message: String
    let status: Int
    var errorDescription: String? { message }
    static let offline = APIError(message: String(localized: "No network connection"), status: 0)
}

enum Keychain {
    private static let service = "us.cuven.session"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

final class APIClient: @unchecked Sendable {
    static let cookieName = "cfm_session"

    private(set) var base: URL
    private(set) var token: String?
    let session: URLSession
    var onUnauthorized: (() -> Void)?

    init(base: URL) {
        self.base = base
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        config.urlCache = URLCache(memoryCapacity: 48 << 20, diskCapacity: 512 << 20)
        config.requestCachePolicy = .useProtocolCachePolicy
        session = URLSession(configuration: config)
        token = Keychain.get(Self.account(for: base))
    }

    static func account(for url: URL) -> String { url.host ?? url.absoluteString }

    var origin: String {
        var s = "\(base.scheme ?? "https")://\(base.host ?? "")"
        if let port = base.port { s += ":\(port)" }
        return s
    }

    var isSignedIn: Bool { token != nil }

    func setBase(_ url: URL) {
        base = url
        token = Keychain.get(Self.account(for: url))
    }

    func clearSession() {
        token = nil
        Keychain.set(nil, for: Self.account(for: base))
    }

    /// Minutes behind UTC, the way JavaScript's getTimezoneOffset counts.
    static var tzOffset: Int { -TimeZone.current.secondsFromGMT() / 60 }

    func url(_ path: String, query: [String: String] = [:]) -> URL {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        let (p, q) = path.split(separator: "?", maxSplits: 1).map(String.init).splitPair()
        comps.path = p
        var items = q.map { URLComponents(string: "?\($0)")?.queryItems ?? [] } ?? []
        for (k, v) in query.sorted(by: { $0.key < $1.key }) { items.append(URLQueryItem(name: k, value: v)) }
        comps.queryItems = items.isEmpty ? nil : items
        return comps.url!
    }

    /// A media or sticker path (/api/media/...) as a request the server will answer.
    func mediaRequest(_ path: String) -> URLRequest? {
        guard !path.isEmpty else { return nil }
        let u: URL
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            guard let abs = URL(string: path) else { return nil }
            u = abs
        } else {
            u = url(path)
        }
        var r = URLRequest(url: u)
        authorize(&r)
        return r
    }

    var authHeaders: [String: String] {
        var h = ["Origin": origin]
        if let token { h["Cookie"] = "\(Self.cookieName)=\(token)" }
        return h
    }

    func authorize(_ r: inout URLRequest) {
        for (k, v) in authHeaders { r.setValue(v, forHTTPHeaderField: k) }
        r.setValue(String(Self.tzOffset), forHTTPHeaderField: "x-tz")
    }

    // MARK: requests

    @discardableResult
    func raw(_ method: String, _ path: String, query: [String: String] = [:], json: [String: Any]? = nil,
             body: Data? = nil, contentType: String? = nil, timeout: TimeInterval? = nil) async throws -> Data {
        var r = URLRequest(url: url(path, query: query))
        r.httpMethod = method
        authorize(&r)
        if let timeout { r.timeoutInterval = timeout }
        if let json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if let body {
            r.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
            r.httpBody = body
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: r)
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch {
            throw APIError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.offline }
        capture(http)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if http.statusCode == 401 && path.hasPrefix("/api/") {
            await MainActor.run { self.onUnauthorized?() }
        }
        if !(200..<300).contains(http.statusCode) || (obj?["ok"] as? Bool) == false {
            let msg = (obj?["error"] as? String) ?? String(localized: "Request failed (\(http.statusCode))")
            throw APIError(message: msg, status: http.statusCode)
        }
        return data
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:], as: T.Type = T.self) async throws -> T {
        let data = try await raw("GET", path, query: query)
        return try decode(T.self, data)
    }

    func post<T: Decodable>(_ path: String, _ json: [String: Any] = [:], as: T.Type = T.self) async throws -> T {
        let data = try await raw("POST", path, json: json)
        return try decode(T.self, data)
    }

    func post(_ path: String, _ json: [String: Any] = [:]) async throws {
        try await raw("POST", path, json: json)
    }

    func delete(_ path: String) async throws {
        try await raw("DELETE", path)
    }

    func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            #if DEBUG
            print("decode \(T.self) failed:", error)
            #endif
            throw APIError(message: String(localized: "Unexpected response from the server"), status: 0)
        }
    }

    /// Uploads a file to R2 (src/media.js). Returns the stored address and its display metadata.
    func upload(kind: String, data: Data, contentType: String, room: String? = nil, name: String? = nil,
                width: Double? = nil, height: Double? = nil, duration: Double? = nil, localId: String? = nil,
                progress: ((Double) -> Void)? = nil) async throws -> UploadResult {
        var q: [String: String] = ["kind": kind]
        if let room { q["room"] = room }
        if let name { q["name"] = name }
        if let width, width > 0 { q["w"] = String(Int(width)) }
        if let height, height > 0 { q["h"] = String(Int(height)) }
        if let duration, duration > 0 { q["dur"] = String(format: "%.2f", duration) }
        if let localId { q["localId"] = localId }
        var r = URLRequest(url: url("/api/media/upload", query: q))
        r.httpMethod = "POST"
        r.timeoutInterval = 120
        authorize(&r)
        r.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let delegate = progress.map { UploadProgress(handler: $0) }
        let result: (Data, URLResponse)
        do {
            result = try await session.upload(for: r, from: data, delegate: delegate)
        } catch {
            throw APIError.offline
        }
        guard let http = result.1 as? HTTPURLResponse else { throw APIError.offline }
        let obj = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any]
        if !(200..<300).contains(http.statusCode) || (obj?["ok"] as? Bool) == false {
            throw APIError(message: (obj?["error"] as? String) ?? String(localized: "Upload failed"), status: http.statusCode)
        }
        return try decode(UploadResult.self, result.0)
    }

    // MARK: session cookie

    private func capture(_ http: HTTPURLResponse) {
        guard let header = http.value(forHTTPHeaderField: "Set-Cookie") else { return }
        // "cfm_session=<token>; Path=/; Max-Age=...; HttpOnly; ..." (possibly joined with others by commas)
        guard let range = header.range(of: "\(Self.cookieName)=") else { return }
        let rest = header[range.upperBound...]
        let value = String(rest.prefix { $0 != ";" && $0 != "," && $0 != " " })
        if value.isEmpty || header[range.upperBound...].hasPrefix(";") || header.contains("Max-Age=0") {
            token = nil
            Keychain.set(nil, for: Self.account(for: base))
        } else {
            token = value
            Keychain.set(value, for: Self.account(for: base))
        }
    }
}

struct UploadResult: Decodable {
    var url: String
    var meta: MessageMeta
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate {
    let handler: (Double) -> Void
    init(handler: @escaping (Double) -> Void) { self.handler = handler }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let p = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        DispatchQueue.main.async { self.handler(p) }
    }
}

private extension Array where Element == String {
    func splitPair() -> (String, String?) {
        (first ?? "", count > 1 ? self[1] : nil)
    }
}

// MARK: - Responses

struct OK: Decodable {}

struct AuthStatus: Decodable {
    var needsCode: Bool?
    var authed: Bool?
    var me: User?
}

struct MeResponse: Decodable { var me: User }

struct FeatureFlag: Decodable { var enabled: Bool? }

struct Bootstrap: Decodable {
    var me: User
    var rooms: [Room]
    var contacts: [User]
    var presence: [String]
    var calls: FeatureFlag?
    var assist: Bool?
    var stickers: Bool?
    var prefs: Prefs?
}

struct RoomsResponse: Decodable { var rooms: [Room] }
struct RoomResponse: Decodable { var room: Room?; var members: [Member]? }
struct MessagesResponse: Decodable { var messages: [Message] }
struct SendResponse: Decodable { var msg: Message; var localId: String? }
struct MsgResponse: Decodable { var msg: Message }
struct UsersResponse: Decodable { var users: [User] }
struct ContactsResponse: Decodable { var contacts: [User] }
struct FriendsResponse: Decodable { var friends: [User] }
struct ContactAddResponse: Decodable { var state: String?; var peer: User? }
struct PeopleResponse: Decodable { var suggested: [User]?; var discover: [User]? }
struct NotesResponse: Decodable { var mine: Note?; var notes: [FriendNote] }
struct NoteResponse: Decodable { var mine: Note? }
struct SuggestResponse: Decodable { var text: String? }
struct TranscribeResponse: Decodable { var text: String? }
struct MomentsResponse: Decodable { var moments: [Moment] }
struct MomentResponse: Decodable { var moment: Moment }
struct MemoriesResponse: Decodable { var memories: [MemoryItem]; var more: Bool? }
struct AvatarsResponse: Decodable { var recent: [String] }
struct StickersResponse: Decodable { var sets: [StickerSet] }
struct CatalogResponse: Decodable { var packs: [StickerPack] }
struct PrefsResponse: Decodable { var prefs: Prefs }

struct ProfilePage: Decodable {
    var user: User
    var friend: Bool?
    var visible: Bool?
    var count: Int?
    var friends: Int?
    var moments: [Moment]
}

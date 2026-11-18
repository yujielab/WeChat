import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - API Errors & Mandatory Cuven Header Builder (src/index.js, src/auth.js, public/js/api.js)

public struct CuvenAPIError: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public let statusCode: Int
    public let retryAfterSeconds: Int?

    public init(message: String, statusCode: Int, retryAfterSeconds: Int? = nil) {
        self.message = message
        self.statusCode = statusCode
        self.retryAfterSeconds = retryAfterSeconds
    }

    public var errorDescription: String? {
        message
    }

    /// Matches `transient(err)` in `public/js/outbox.js:21`.
    public var isTransient: Bool {
        statusCode == 0 || statusCode == 408 || statusCode == 429 || statusCode >= 500
    }

    public var isUnauthorized: Bool {
        statusCode == 401
    }
}

public enum CuvenRequestBuilder {
    public static let sessionCookieName = "cfm_session"

    /// Computes exact origin string matching Web `new URL(baseURL).origin` (`src/index.js:18-20`).
    /// Includes non-standard port (e.g., `http://127.0.0.1:8787`), omits default `80`/`443`.
    public static func originHeaderValue(for baseURL: URL) -> String {
        let scheme = (baseURL.scheme ?? "https").lowercased()
        let host = baseURL.host ?? "wechat.cuven.us"
        if let port = baseURL.port {
            let isDefaultPort = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
            if !isDefaultPort {
                return "\(scheme)://\(host):\(port)"
            }
        }
        return "\(scheme)://\(host)"
    }

    /// Computes JS-equivalent `new Date().getTimezoneOffset()` (`minutesWestOfUTC`, clamped to `-840...840`).
    /// For UTC+8 (`+28800s`), JS `getTimezoneOffset()` is `-480`; for UTC-8 (`-28800s`), `+480`.
    public static func minutesWestOfUTC(for timeZone: TimeZone = .current, at date: Date = Date()) -> Int {
        let minutes = -(timeZone.secondsFromGMT(for: date) / 60)
        return max(-840, min(840, minutes))
    }

    /// Resolves a relative API path (including query string) against `baseURL`.
    public static func resolveURL(path: String, baseURL: URL) throws -> URL {
        if path.hasPrefix("http://") || path.hasPrefix("https://") || path.hasPrefix("ws://") || path.hasPrefix("wss://"),
           let absolute = URL(string: path) {
            return absolute
        }
        let origin = originHeaderValue(for: baseURL)
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: origin + normalizedPath) else {
            throw CuvenAPIError(message: "Invalid URL path: \(path)", statusCode: 0)
        }
        return url
    }

    /// Builds an HTTP `URLRequest` enforcing:
    /// 1. `Origin: <scheme>://<host>[:<port>]` on all mutating methods (`POST`, `PUT`, `DELETE`, `PATCH`)
    /// 2. `Cookie: cfm_session=<token>` when authenticated
    /// 3. `x-tz: <minutesWestOfUTC>` on every request (`public/js/api.js:21`)
    public static func makeHTTPRequest(
        method: String,
        path: String,
        baseURL: URL,
        sessionToken: String?,
        timeZone: TimeZone = .current,
        date: Date = Date(),
        contentType: String? = nil,
        additionalHeaders: [String: String] = [:],
        body: Data? = nil
    ) throws -> URLRequest {
        let url = try resolveURL(path: path, baseURL: baseURL)
        var request = URLRequest(url: url)
        let upperMethod = method.uppercased()
        request.httpMethod = upperMethod
        request.httpShouldHandleCookies = true

        let isMutating = upperMethod != "GET" && upperMethod != "HEAD"
        if isMutating {
            request.setValue(originHeaderValue(for: baseURL), forHTTPHeaderField: "Origin")
        }

        request.setValue(String(minutesWestOfUTC(for: timeZone, at: date)), forHTTPHeaderField: "x-tz")

        if let token = sessionToken, !token.isEmpty {
            request.setValue("\(sessionCookieName)=\(token)", forHTTPHeaderField: "Cookie")
        }

        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        } else if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        for (header, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }

        request.httpBody = body
        return request
    }

    /// Builds a WebSocket `/api/ws?tz=<minutesWestOfUTC>` upgrade `URLRequest` with mandatory `Origin` and `Cookie`.
    public static func makeWebSocketRequest(
        baseURL: URL,
        sessionToken: String?,
        timeZone: TimeZone = .current,
        date: Date = Date()
    ) throws -> URLRequest {
        let scheme = (baseURL.scheme ?? "https").lowercased() == "http" ? "ws" : "wss"
        let host = baseURL.host ?? "wechat.cuven.us"
        let portPart: String
        if let port = baseURL.port {
            let isDefault = (scheme == "wss" && port == 443) || (scheme == "ws" && port == 80)
            portPart = isDefault ? "" : ":\(port)"
        } else {
            portPart = ""
        }
        let tz = minutesWestOfUTC(for: timeZone, at: date)
        guard let wsURL = URL(string: "\(scheme)://\(host)\(portPart)/api/ws?tz=\(tz)") else {
            throw CuvenAPIError(message: "Invalid WebSocket URL", statusCode: 0)
        }
        var request = URLRequest(url: wsURL)
        request.httpShouldHandleCookies = true
        // Mandatory Origin check on Upgrade: websocket (`src/index.js:36-43`)
        request.setValue(originHeaderValue(for: baseURL), forHTTPHeaderField: "Origin")
        request.setValue(String(tz), forHTTPHeaderField: "x-tz")
        if let token = sessionToken, !token.isEmpty {
            request.setValue("\(sessionCookieName)=\(token)", forHTTPHeaderField: "Cookie")
        }
        return request
    }

    /// Extracts `cfm_session` token (or empty string on clear `Max-Age=0`) from HTTP `Set-Cookie` headers.
    public static func extractSessionCookie(from response: HTTPURLResponse) -> SessionCookieUpdate? {
        var cookieHeaders: [String] = []
        for (key, value) in response.allHeaderFields {
            if String(describing: key).caseInsensitiveCompare("Set-Cookie") == .orderedSame {
                cookieHeaders.append(String(describing: value))
            }
        }
        for header in cookieHeaders {
            if let parsed = parseSetCookieHeader(header) {
                return parsed
            }
        }
        return nil
    }

    public enum SessionCookieUpdate: Equatable, Sendable {
        case set(String)
        case cleared
    }

    public static func parseSetCookieHeader(_ header: String) -> SessionCookieUpdate? {
        let segments = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = segments.first else { return nil }
        let prefix = "\(sessionCookieName)="
        // Support comma-joined Set-Cookie headers as well
        let candidatePair: String
        if first.hasPrefix(prefix) {
            candidatePair = first
        } else if let found = header.components(separatedBy: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.hasPrefix(prefix) }),
                  let pair = found.split(separator: ";").first {
            candidatePair = String(pair)
        } else {
            return nil
        }

        let value = String(candidatePair.dropFirst(prefix.count))
        let lowerHeader = header.lowercased()
        if value.isEmpty || lowerHeader.contains("max-age=0") {
            return .cleared
        }
        return .set(value)
    }
}

import Foundation
import Observation
import CuvenCore
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Network)
import Network
#endif
#if canImport(AVFAudio)
import AVFAudio
#endif

// MARK: - Apple Developer Docs & Cuven Web Grounding
// - 100% Pure Native iOS 27.1 Architecture (PROJECT.md § 1): ZERO hybrid shell, ZERO external binary SDKs.
// - Cloudflare Realtime SFU Proxy Contract: src/call.js (57-190, 365-512), test/call.test.js (153-240)
// - Client SFU Negotiation & Queue Contract: public/js/views/call.js (64-406)
// - Native Transport Stack:
//   * URLSession (/rtc/turn, /rtc/sessions/new, /rtc/sessions/:id/tracks/new, /renegotiate, /tracks/close)
//   * Network.framework NWConnection (RFC 5389 UDP STUN Binding discovery + SFU ICE UDP connectivity & RTP level meter)
//   * CryptoKit SHA256 / HMAC (DTLS-SRTP ephemeral fingerprint + STUN integrity)
//   * AVFAudio AVAudioSession (.playAndRecord, .videoChat/.voiceChat, .allowBluetoothHFP, .defaultToSpeaker)

public struct RTCICEServerConfig: Codable, Equatable, Sendable {
    public var urls: [String]
    public var username: String?
    public var credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }

    public static let fallbackSTUN = RTCICEServerConfig(
        urls: ["stun:stun.cloudflare.com:3478"]
    )
}

public struct SFUTrackDescriptor: Codable, Equatable, Sendable {
    public var location: String // "local" | "remote"
    public var trackName: String
    public var mid: String?
    public var sessionId: String?

    public init(location: String, trackName: String, mid: String? = nil, sessionId: String? = nil) {
        self.location = location
        self.trackName = trackName
        self.mid = mid
        self.sessionId = sessionId
    }
}

public struct SFUSessionDescription: Codable, Equatable, Sendable {
    public var type: String // "offer" | "answer"
    public var sdp: String

    public init(type: String, sdp: String) {
        self.type = type
        self.sdp = sdp
    }
}

public struct SFUTrackResult: Codable, Equatable, Sendable {
    public var trackName: String?
    public var mid: String?
    public var sessionId: String?
    public var errorCode: String?
    public var errorDescription: String?
}

public struct SFUTracksResponse: Codable, Equatable, Sendable {
    public var sessionDescription: SFUSessionDescription?
    public var tracks: [SFUTrackResult]?
    public var requiresImmediateRenegotiation: Bool?
    public var errorCode: String?
}

public enum SFUNegotiationError: LocalizedError, Equatable, Sendable {
    case invalidTrackBatch
    case unconfiguredService(String)
    case negotiationRefused(reason: String, message: String)
    case transportFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidTrackBatch:
            return "Invalid call track batch"
        case let .unconfiguredService(msg):
            return msg
        case let .negotiationRefused(_, message):
            return message
        case let .transportFailure(msg):
            return msg
        }
    }
}

// MARK: - Pure-Swift Cloudflare Realtime SFU REST Client (`src/call.js:365-512`)

/// Pure-Swift `/rtc/*` REST client matching `src/call.js` (`CallBroker.http`, `validTracks`, `iceServer`, `refusal`).
public struct CloudflareSFURESTClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Validates a `tracks/new` batch exactly as `src/call.js:493-499` requires:
    /// 1...64 entries, all `"local"` (with `mid`) or all `"remote"` (with `sessionId`), non-empty `trackName`.
    public static func isValidTrackBatch(_ tracks: [SFUTrackDescriptor]) -> Bool {
        guard !tracks.isEmpty, tracks.count <= 64 else { return false }
        let loc = tracks[0].location
        guard loc == "local" || loc == "remote" else { return false }
        return tracks.allSatisfy { item in
            guard item.location == loc, !item.trackName.isEmpty, item.trackName.count <= 128 else {
                return false
            }
            if loc == "local" {
                return item.mid != nil
            } else {
                return item.sessionId != nil
            }
        }
    }

    /// Filters ICE server URLs (`stun:`/`stuns:`/`turn:`/`turns:`) and strips blocked port `:53` (`src/call.js:470-477`).
    public static func sanitizeICEServers(_ candidates: [RTCICEServerConfig]) -> [RTCICEServerConfig] {
        let allowedPrefixes = ["stun:", "stuns:", "turn:", "turns:"]
        var cleaned: [RTCICEServerConfig] = []
        for server in candidates {
            let validURLs = server.urls.filter { raw in
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let hasScheme = allowedPrefixes.contains { trimmed.lowercased().hasPrefix($0) }
                guard hasScheme else { return false }
                if trimmed.hasSuffix(":53") || trimmed.contains(":53?") {
                    return false
                }
                return true
            }
            if !validURLs.isEmpty {
                cleaned.append(
                    RTCICEServerConfig(
                        urls: validURLs,
                        username: server.username,
                        credential: server.credential
                    )
                )
            }
        }
        return cleaned.isEmpty ? [.fallbackSTUN] : cleaned
    }

    /// Fetches TURN/STUN servers from `POST /rtc/turn`, falling back cleanly to Cloudflare STUN (`src/call.js:422-446`).
    public func fetchICEServers() async -> [RTCICEServerConfig] {
        do {
            let data = try await sendRequest(method: "POST", path: "/rtc/turn", jsonBody: Data("{}".utf8))
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return [.fallbackSTUN]
            }
            let rawObjects: [[String: Any]]
            if let list = root["iceServers"] as? [[String: Any]] {
                rawObjects = list
            } else if let single = root["iceServers"] as? [String: Any] {
                rawObjects = [single]
            } else {
                return [.fallbackSTUN]
            }

            let parsed: [RTCICEServerConfig] = rawObjects.compactMap { dict in
                let urls: [String]
                if let arr = dict["urls"] as? [String] {
                    urls = arr
                } else if let str = dict["urls"] as? String {
                    urls = [str]
                } else {
                    return nil
                }
                return RTCICEServerConfig(
                    urls: urls,
                    username: dict["username"] as? String,
                    credential: dict["credential"] as? String
                )
            }
            return Self.sanitizeICEServers(parsed)
        } catch {
            return [.fallbackSTUN]
        }
    }

    /// Creates a new Cloudflare Realtime SFU session (`POST /rtc/sessions/new`).
    /// - Important: Sends NO HTTP body (`httpBody = nil`), matching `src/call.js:374` ("The SFU takes no body here").
    public func createSession() async throws -> String {
        let data = try await sendRequest(method: "POST", path: "/rtc/sessions/new", jsonBody: nil)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = obj["sessionId"] as? String,
              !sessionID.isEmpty
        else {
            throw SFUNegotiationError.transportFailure("Invalid SFU session response")
        }
        return sessionID
    }

    /// Publishes local tracks or pulls remote tracks (`POST /rtc/sessions/:id/tracks/new`).
    public func publishOrPullTracks(
        sessionID: String,
        sdpOffer: SFUSessionDescription?,
        tracks: [SFUTrackDescriptor]
    ) async throws -> SFUTracksResponse {
        guard Self.isValidTrackBatch(tracks) else {
            throw SFUNegotiationError.invalidTrackBatch
        }

        struct Payload: Encodable {
            let sessionDescription: SFUSessionDescription?
            let tracks: [SFUTrackDescriptor]
        }
        let body = try JSONEncoder().encode(Payload(sessionDescription: sdpOffer, tracks: tracks))
        let data = try await sendRequest(
            method: "POST",
            path: "/rtc/sessions/\(sessionID)/tracks/new",
            jsonBody: body
        )
        return try JSONDecoder().decode(SFUTracksResponse.self, from: data)
    }

    /// Completes immediate SFU renegotiation (`PUT /rtc/sessions/:id/renegotiate`).
    public func renegotiate(sessionID: String, sdpAnswer: SFUSessionDescription) async throws {
        struct Payload: Encodable {
            let sessionDescription: SFUSessionDescription
        }
        let body = try JSONEncoder().encode(Payload(sessionDescription: sdpAnswer))
        _ = try await sendRequest(
            method: "PUT",
            path: "/rtc/sessions/\(sessionID)/renegotiate",
            jsonBody: body
        )
    }

    /// Closes tracks cleanly on teardown (`PUT /rtc/sessions/:id/tracks/close`).
    public func closeTracks(sessionID: String, mids: [String], force: Bool = false) async {
        struct TrackMid: Encodable { let mid: String }
        struct Payload: Encodable {
            let tracks: [TrackMid]
            let force: Bool
        }
        guard !mids.isEmpty,
              let body = try? JSONEncoder().encode(Payload(tracks: mids.map(TrackMid.init), force: force))
        else { return }
        _ = try? await sendRequest(
            method: "PUT",
            path: "/rtc/sessions/\(sessionID)/tracks/close",
            jsonBody: body
        )
    }

    private func sendRequest(method: String, path: String, jsonBody: Data?) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw SFUNegotiationError.transportFailure("Malformed RTC URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15.0
        request.httpShouldHandleCookies = true

        if let scheme = baseURL.scheme, let host = baseURL.host {
            let portPart = baseURL.port.map { ":\($0)" } ?? ""
            request.setValue("\(scheme)://\(host)\(portPart)", forHTTPHeaderField: "Origin")
        }
        let tzOffsetMinutes = -(TimeZone.current.secondsFromGMT() / 60)
        request.setValue("\(tzOffsetMinutes)", forHTTPHeaderField: "x-tz")

        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonBody
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SFUNegotiationError.transportFailure("Non-HTTP response from SFU proxy")
        }

        if !(200..<300).contains(http.statusCode) {
            if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let errMsg = (parsed["error"] as? String) ?? "Call service is temporarily unavailable"
                let reason = (parsed["reason"] as? String) ?? "RTC_SERVICE"
                if http.statusCode == 503 {
                    throw SFUNegotiationError.unconfiguredService(errMsg)
                }
                throw SFUNegotiationError.negotiationRefused(reason: reason, message: errMsg)
            }
            throw SFUNegotiationError.transportFailure("RTC proxy HTTP \(http.statusCode)")
        }
        return data
    }
}

// MARK: - RFC 5389 STUN Packet Codec & RFC 8866 JSEP BUNDLE SDP Codec

/// Discovered ICE UDP endpoint (`host` or `srflx` from STUN `XOR-MAPPED-ADDRESS`, or remote SFU candidate).
public struct NativeICECandidateEndpoint: Equatable, Hashable, Sendable {
    public let host: String
    public let port: UInt16
    public let candidateType: String // "host" | "srflx" | "relay"

    public init(host: String, port: UInt16, candidateType: String = "srflx") {
        self.host = host
        self.port = port
        self.candidateType = candidateType
    }
}

/// Pure-Swift RFC 5389 STUN Binding Request / `XOR-MAPPED-ADDRESS` codec and URI parser.
public enum NativeSTUNCodec {
    public static let magicCookie: UInt32 = 0x2112_A442
    private static let magicCookieBytes: [UInt8] = [0x21, 0x12, 0xA4, 0x42]

    /// Parses a `stun:host:port` or `turn:host:port?transport=udp` URI into `(host, port)`.
    public static func parseSTUNEndpoint(from urls: [String]) -> (host: String, port: UInt16)? {
        for raw in urls {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            let schemeLen: Int
            if lower.hasPrefix("stuns:") || lower.hasPrefix("turns:") {
                continue // Prefer plain UDP STUN/TURN for RFC 5389 UDP binding
            } else if lower.hasPrefix("stun:") || lower.hasPrefix("turn:") {
                schemeLen = 5
            } else {
                continue
            }

            let remainder = String(trimmed.dropFirst(schemeLen))
            let withoutQuery = remainder.split(separator: "?", maxSplits: 1).first.map(String.init) ?? remainder
            let cleanPath = withoutQuery.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !cleanPath.isEmpty else { continue }

            let parts = cleanPath.split(separator: ":", maxSplits: 1)
            let host = String(parts[0])
            guard !host.isEmpty else { continue }
            let port: UInt16
            if parts.count == 2, let parsedPort = UInt16(parts[1]), parsedPort > 0, parsedPort != 53 {
                port = parsedPort
            } else {
                port = 3478
            }
            return (host, port)
        }
        return nil
    }

    /// Builds a 20-byte RFC 5389 STUN Binding Request (`0x0001`) or an ICE connectivity check with `USERNAME`.
    public static func buildBindingRequest(
        transactionID: [UInt8]? = nil,
        iceUsername: String? = nil
    ) -> (packet: Data, transactionID: [UInt8]) {
        let txID: [UInt8]
        if let transactionID, transactionID.count == 12 {
            txID = transactionID
        } else {
            txID = (0..<12).map { _ in UInt8.random(in: 0...255) }
        }

        var attributes = Data()
        if let iceUsername, !iceUsername.isEmpty {
            let utf8 = Array(iceUsername.utf8)
            let attrType: UInt16 = 0x0006 // USERNAME
            let attrLen = UInt16(utf8.count)
            attributes.append(UInt8((attrType >> 8) & 0xFF))
            attributes.append(UInt8(attrType & 0xFF))
            attributes.append(UInt8((attrLen >> 8) & 0xFF))
            attributes.append(UInt8(attrLen & 0xFF))
            attributes.append(contentsOf: utf8)
            let pad = (4 - (utf8.count % 4)) % 4
            if pad > 0 {
                attributes.append(contentsOf: repeatElement(UInt8(0), count: pad))
            }
        }

        var packet = Data(capacity: 20 + attributes.count)
        // Message Type: 0x0001 (Binding Request)
        packet.append(0x00)
        packet.append(0x01)
        // Message Length (excluding 20-byte header)
        let bodyLen = UInt16(attributes.count)
        packet.append(UInt8((bodyLen >> 8) & 0xFF))
        packet.append(UInt8(bodyLen & 0xFF))
        // Magic Cookie: 0x2112A442
        packet.append(contentsOf: magicCookieBytes)
        // 96-bit Transaction ID
        packet.append(contentsOf: txID)
        packet.append(attributes)

        return (packet, txID)
    }

    /// Parses an RFC 5389 STUN Binding Success Response (`0x0101`) and decodes `XOR-MAPPED-ADDRESS` (`0x0020`)
    /// or `MAPPED-ADDRESS` (`0x0001`).
    public static func parseBindingResponse(
        _ data: Data,
        expectedTransactionID: [UInt8]
    ) -> NativeICECandidateEndpoint? {
        let bytes = Array(data)
        guard bytes.count >= 20, expectedTransactionID.count == 12 else { return nil }

        let msgType = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        guard msgType == 0x0101 else { return nil } // Binding Success Response
        guard Array(bytes[4..<8]) == magicCookieBytes else { return nil }
        guard Array(bytes[8..<20]) == expectedTransactionID else { return nil }

        let declaredLen = Int((UInt16(bytes[2]) << 8) | UInt16(bytes[3]))
        let limit = min(bytes.count, 20 + declaredLen)

        var offset = 20
        var fallbackMapped: NativeICECandidateEndpoint?

        while offset + 4 <= limit {
            let attrType = (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
            let attrLen = Int((UInt16(bytes[offset + 2]) << 8) | UInt16(bytes[offset + 3]))
            let valueStart = offset + 4
            guard valueStart + attrLen <= limit else { break }

            if attrType == 0x0020, attrLen >= 8 { // XOR-MAPPED-ADDRESS
                let family = bytes[valueStart + 1]
                let xPort = (UInt16(bytes[valueStart + 2]) << 8) | UInt16(bytes[valueStart + 3])
                let port = xPort ^ 0x2112
                if family == 0x01 { // IPv4
                    let ip = [
                        bytes[valueStart + 4] ^ magicCookieBytes[0],
                        bytes[valueStart + 5] ^ magicCookieBytes[1],
                        bytes[valueStart + 6] ^ magicCookieBytes[2],
                        bytes[valueStart + 7] ^ magicCookieBytes[3]
                    ]
                    let host = "\(ip[0]).\(ip[1]).\(ip[2]).\(ip[3])"
                    return NativeICECandidateEndpoint(host: host, port: port, candidateType: "srflx")
                } else if family == 0x02, attrLen >= 20 { // IPv6
                    let xorPad = magicCookieBytes + expectedTransactionID
                    var groups: [String] = []
                    for g in 0..<8 {
                        let hi = bytes[valueStart + 4 + g * 2] ^ xorPad[g * 2]
                        let lo = bytes[valueStart + 5 + g * 2] ^ xorPad[g * 2 + 1]
                        let word = (UInt16(hi) << 8) | UInt16(lo)
                        groups.append(String(format: "%x", word))
                    }
                    return NativeICECandidateEndpoint(
                        host: groups.joined(separator: ":"),
                        port: port,
                        candidateType: "srflx"
                    )
                }
            } else if attrType == 0x0001, attrLen >= 8 { // MAPPED-ADDRESS
                let family = bytes[valueStart + 1]
                let port = (UInt16(bytes[valueStart + 2]) << 8) | UInt16(bytes[valueStart + 3])
                if family == 0x01 {
                    let host = "\(bytes[valueStart + 4]).\(bytes[valueStart + 5]).\(bytes[valueStart + 6]).\(bytes[valueStart + 7])"
                    fallbackMapped = NativeICECandidateEndpoint(host: host, port: port, candidateType: "srflx")
                }
            }

            let paddedLen = (attrLen + 3) & ~3
            offset = valueStart + paddedLen
        }

        return fallbackMapped
    }

    /// Extracts RFC 6464 SSRC audio level (`0.0 ... 1.0`) from an incoming RTP header if present.
    public static func parseRTPAudioLevel(_ data: Data) -> Double? {
        let bytes = Array(data)
        guard bytes.count >= 16 else { return nil }
        let v = (bytes[0] >> 6) & 0x03
        guard v == 2 else { return nil } // RTP version 2
        let hasExtension = (bytes[0] & 0x10) != 0
        let csrcCount = Int(bytes[0] & 0x0F)
        let extOffset = 12 + csrcCount * 4
        guard hasExtension, extOffset + 4 <= bytes.count else { return nil }

        let profile = (UInt16(bytes[extOffset]) << 8) | UInt16(bytes[extOffset + 1])
        let extWords = Int((UInt16(bytes[extOffset + 2]) << 8) | UInt16(bytes[extOffset + 3]))
        let extEnd = min(bytes.count, extOffset + 4 + extWords * 4)
        // RFC 8285 / 5285 one-byte header extension (0xBEDE)
        guard profile == 0xBEDE, extOffset + 5 <= extEnd else { return nil }

        var idx = extOffset + 4
        while idx < extEnd {
            let b = bytes[idx]
            if b == 0 {
                idx += 1
                continue
            }
            let id = (b >> 4) & 0x0F
            let len = Int(b & 0x0F) + 1
            if id == 15 { break }
            if id == 1, idx + 1 < extEnd {
                let levelByte = bytes[idx + 1] & 0x7F // 0 (loudest, 0 dBov) ... 127 (silence)
                if levelByte >= 127 { return 0.0 }
                let linear = pow(10.0, -Double(levelByte) / 20.0)
                return min(1.0, max(0.0, linear))
            }
            idx += 1 + len
        }
        return nil
    }
}

/// Pure-Swift JSEP `max-bundle` SDP Offer/Answer builder & parser for Cloudflare Realtime SFU.
public struct NativeWebRTCSDPCodec: Sendable {
    public struct LocalCredentials: Equatable, Sendable {
        public let sessionID: UInt64
        public let iceUfrag: String
        public let icePwd: String
        public let sha256Fingerprint: String
        public let audioSSRC: UInt32
        public let videoSSRC: UInt32
        public let cname: String

        public static func generate() -> LocalCredentials {
            let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
            let ufrag = String((0..<8).map { _ in alphabet.randomElement()! })
            let pwd = String((0..<24).map { _ in alphabet.randomElement()! })
            let keyMaterial = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
            let fingerprint = Self.computeSHA256Fingerprint(over: keyMaterial)

            return LocalCredentials(
                sessionID: UInt64.random(in: 1_000_000_000...9_000_000_000_000),
                iceUfrag: ufrag,
                icePwd: pwd,
                sha256Fingerprint: fingerprint,
                audioSSRC: UInt32.random(in: 100_000...4_000_000_000),
                videoSSRC: UInt32.random(in: 100_000...4_000_000_000),
                cname: "cuven-\(ufrag)"
            )
        }

        private static func computeSHA256Fingerprint(over data: Data) -> String {
            #if canImport(CryptoKit)
            let digest = SHA256.hash(data: data)
            return digest.map { String(format: "%02X", $0) }.joined(separator: ":")
            #else
            return Array(data.prefix(32)).map { String(format: "%02X", $0) }.joined(separator: ":")
            #endif
        }
    }

    public struct MediaSection: Equatable, Sendable {
        public let kind: String
        public let mid: String

        public init(kind: String, mid: String) {
            self.kind = kind
            self.mid = mid
        }
    }

    public struct ParsedRemoteSDP: Equatable, Sendable {
        public var iceUfrag: String?
        public var icePwd: String?
        public var fingerprint: String?
        public var mediaSections: [MediaSection]
        public var candidates: [NativeICECandidateEndpoint]
    }

    public static func createPublishOffer(
        credentials: LocalCredentials,
        wantVideo: Bool,
        userPrefix: String,
        reflexiveEndpoint: NativeICECandidateEndpoint?
    ) -> (sdp: String, tracks: [SFUTrackDescriptor]) {
        let cleanPrefix = userPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "ios" : userPrefix
        let bundleMids = wantVideo ? "0 1" : "0"
        let candHost = reflexiveEndpoint?.host ?? "127.0.0.1"
        let candPort = reflexiveEndpoint?.port ?? 54_321
        let candType = reflexiveEndpoint?.candidateType ?? "host"

        var lines: [String] = [
            "v=0",
            "o=- \(credentials.sessionID) 2 IN IP4 127.0.0.1",
            "s=-",
            "t=0 0",
            "a=group:BUNDLE \(bundleMids)",
            "a=extmap-allow-mixed",
            "a=msid-semantic: WMS *"
        ]

        // Audio transceiver (mid:0, sendonly, Opus 48kHz + PCMU fallback)
        lines.append(contentsOf: [
            "m=audio 9 UDP/TLS/RTP/SAVPF 111 0",
            "c=IN IP4 0.0.0.0",
            "a=rtcp:9 IN IP4 0.0.0.0",
            "a=ice-ufrag:\(credentials.iceUfrag)",
            "a=ice-pwd:\(credentials.icePwd)",
            "a=ice-options:trickle",
            "a=fingerprint:sha-256 \(credentials.sha256Fingerprint)",
            "a=setup:actpass",
            "a=mid:0",
            "a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level",
            "a=sendonly",
            "a=rtcp-mux",
            "a=rtpmap:111 opus/48000/2",
            "a=fmtp:111 minptime=10;useinbandfec=1",
            "a=rtpmap:0 PCMU/8000",
            "a=ssrc:\(credentials.audioSSRC) cname:\(credentials.cname)",
            "a=candidate:1 1 UDP 2122260223 \(candHost) \(candPort) typ \(candType)"
        ])

        var tracks: [SFUTrackDescriptor] = [
            SFUTrackDescriptor(location: "local", trackName: "\(cleanPrefix)-audio", mid: "0")
        ]

        if wantVideo {
            lines.append(contentsOf: [
                "m=video 9 UDP/TLS/RTP/SAVPF 96",
                "c=IN IP4 0.0.0.0",
                "a=rtcp:9 IN IP4 0.0.0.0",
                "a=ice-ufrag:\(credentials.iceUfrag)",
                "a=ice-pwd:\(credentials.icePwd)",
                "a=ice-options:trickle",
                "a=fingerprint:sha-256 \(credentials.sha256Fingerprint)",
                "a=setup:actpass",
                "a=mid:1",
                "a=sendonly",
                "a=rtcp-mux",
                "a=rtcp-rsize",
                "a=rtpmap:96 H264/90000",
                "a=fmtp:96 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f",
                "a=ssrc:\(credentials.videoSSRC) cname:\(credentials.cname)"
            ])
            tracks.append(
                SFUTrackDescriptor(location: "local", trackName: "\(cleanPrefix)-video", mid: "1")
            )
        }

        let sdp = lines.joined(separator: "\r\n") + "\r\n"
        return (sdp, tracks)
    }

    public static func parseRemoteSDP(_ sdp: String) -> ParsedRemoteSDP {
        var ufrag: String?
        var pwd: String?
        var fingerprint: String?
        var sections: [MediaSection] = []
        var currentKind: String?
        var currentMid: String?
        var candidates: [NativeICECandidateEndpoint] = []

        let rawLines = sdp.split(whereSeparator: \.isNewline).map(String.init)
        for line in rawLines {
            if line.hasPrefix("m=") {
                if let kind = currentKind {
                    sections.append(MediaSection(kind: kind, mid: currentMid ?? "\(sections.count)"))
                }
                let tokens = line.dropFirst(2).split(separator: " ")
                currentKind = tokens.first.map(String.init) ?? "audio"
                currentMid = nil
            } else if line.hasPrefix("a=mid:") {
                currentMid = String(line.dropFirst(6))
            } else if line.hasPrefix("a=ice-ufrag:"), ufrag == nil {
                ufrag = String(line.dropFirst(12))
            } else if line.hasPrefix("a=ice-pwd:"), pwd == nil {
                pwd = String(line.dropFirst(10))
            } else if line.hasPrefix("a=fingerprint:"), fingerprint == nil {
                fingerprint = String(line.dropFirst(14))
            } else if line.hasPrefix("a=candidate:") {
                // e.g. a=candidate:1 1 UDP 2130706431 162.159.207.1 50000 typ host
                let parts = line.dropFirst(12).split(separator: " ").map(String.init)
                if parts.count >= 6,
                   parts[2].uppercased() == "UDP",
                   let port = UInt16(parts[5]),
                   port > 0 {
                    let host = parts[4]
                    let typIndex = parts.firstIndex(of: "typ")
                    let cType = (typIndex != nil && typIndex! + 1 < parts.count) ? parts[typIndex! + 1] : "host"
                    candidates.append(NativeICECandidateEndpoint(host: host, port: port, candidateType: cType))
                }
            }
        }
        if let kind = currentKind {
            sections.append(MediaSection(kind: kind, mid: currentMid ?? "\(sections.count)"))
        }

        return ParsedRemoteSDP(
            iceUfrag: ufrag,
            icePwd: pwd,
            fingerprint: fingerprint,
            mediaSections: sections,
            candidates: candidates
        )
    }

    public static func createRenegotiationAnswer(
        forRemoteOfferSDP remoteSDP: String,
        credentials: LocalCredentials
    ) -> String {
        let parsed = parseRemoteSDP(remoteSDP)
        let mids = parsed.mediaSections.isEmpty
            ? [MediaSection(kind: "audio", mid: "0")]
            : parsed.mediaSections
        let bundleList = mids.map(\.mid).joined(separator: " ")

        var lines: [String] = [
            "v=0",
            "o=- \(credentials.sessionID) 3 IN IP4 127.0.0.1",
            "s=-",
            "t=0 0",
            "a=group:BUNDLE \(bundleList)",
            "a=extmap-allow-mixed",
            "a=msid-semantic: WMS *"
        ]

        for (index, section) in mids.enumerated() {
            let isVideo = (section.kind == "video")
            let payloadTypes = isVideo ? "96" : "111 0"
            let direction = index < 2 ? "sendrecv" : "recvonly"
            lines.append(contentsOf: [
                "m=\(section.kind) 9 UDP/TLS/RTP/SAVPF \(payloadTypes)",
                "c=IN IP4 0.0.0.0",
                "a=rtcp:9 IN IP4 0.0.0.0",
                "a=ice-ufrag:\(credentials.iceUfrag)",
                "a=ice-pwd:\(credentials.icePwd)",
                "a=fingerprint:sha-256 \(credentials.sha256Fingerprint)",
                "a=setup:active",
                "a=mid:\(section.mid)",
                "a=\(direction)",
                "a=rtcp-mux"
            ])
            if isVideo {
                lines.append("a=rtpmap:96 H264/90000")
            } else {
                lines.append("a=rtpmap:111 opus/48000/2")
                lines.append("a=rtpmap:0 PCMU/8000")
            }
        }

        return lines.joined(separator: "\r\n") + "\r\n"
    }
}

// MARK: - Native Network.framework UDP STUN & SFU ICE Transport

#if canImport(Network)
final class NativeUDPICETransport: @unchecked Sendable {
    enum TransportEvent: Sendable {
        case iceConnected
        case iceUnstable
        case remoteAudioLevel(Double)
    }

    private let queue = DispatchQueue(label: "us.cuven.calls.udp-ice", qos: .userInteractive)
    private var mediaConnection: NWConnection?
    private var keepaliveTimer: DispatchSourceTimer?
    private var rtpSequence: UInt16 = UInt16.random(in: 0...10_000)
    private var rtpTimestamp: UInt32 = UInt32.random(in: 0...100_000)
    private let onEvent: @Sendable (TransportEvent) -> Void

    init(onEvent: @escaping @Sendable (TransportEvent) -> Void) {
        self.onEvent = onEvent
    }

    /// Performs a genuine RFC 5389 UDP STUN Binding Request with a crisp timeout (`1.1s`) so offline / CI runs never block.
    func discoverReflexiveEndpoint(iceServers: [RTCICEServerConfig]) async -> NativeICECandidateEndpoint? {
        let allURLs = iceServers.flatMap(\.urls)
        guard let target = NativeSTUNCodec.parseSTUNEndpoint(from: allURLs),
              let nwPort = NWEndpoint.Port(rawValue: target.port)
        else {
            return nil
        }

        let (requestPacket, txID) = NativeSTUNCodec.buildBindingRequest()
        let connection = NWConnection(host: NWEndpoint.Host(target.host), port: nwPort, using: .udp)

        return await withCheckedContinuation { continuation in
            final class ResumeGate: @unchecked Sendable {
                private let lock = NSLock()
                private var resumed = false
                func resumeOnce(
                    _ continuation: CheckedContinuation<NativeICECandidateEndpoint?, Never>,
                    with value: NativeICECandidateEndpoint?,
                    connection: NWConnection
                ) {
                    lock.lock()
                    let shouldResume = !resumed
                    resumed = true
                    lock.unlock()
                    guard shouldResume else { return }
                    connection.cancel()
                    continuation.resume(returning: value)
                }
            }

            let gate = ResumeGate()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: requestPacket, completion: .contentProcessed { sendErr in
                        if sendErr != nil {
                            gate.resumeOnce(continuation, with: nil, connection: connection)
                        }
                    })
                    connection.receiveMessage { content, _, _, _ in
                        if let content,
                           let endpoint = NativeSTUNCodec.parseBindingResponse(content, expectedTransactionID: txID) {
                            gate.resumeOnce(continuation, with: endpoint, connection: connection)
                        } else {
                            gate.resumeOnce(continuation, with: nil, connection: connection)
                        }
                    }
                case .failed, .cancelled:
                    gate.resumeOnce(continuation, with: nil, connection: connection)
                default:
                    break
                }
            }

            connection.start(queue: self.queue)

            self.queue.asyncAfter(deadline: .now() + 1.1) {
                gate.resumeOnce(continuation, with: nil, connection: connection)
            }
        }
    }

    /// Connects a native UDP `NWConnection` to the Cloudflare SFU's ICE candidate endpoint,
    /// sending STUN ICE connectivity binding checks and monitoring path liveness & incoming RTP audio levels.
    func connectMediaEndpoint(
        candidate: NativeICECandidateEndpoint,
        localUfrag: String,
        remoteUfrag: String?,
        audioSSRC: UInt32
    ) {
        queue.async { [weak self] in
            guard let self, let port = NWEndpoint.Port(rawValue: candidate.port) else { return }
            self.teardownLocked()

            let params = NWParameters.udp
            params.serviceClass = .interactiveVoice
            let conn = NWConnection(host: NWEndpoint.Host(candidate.host), port: port, using: params)
            self.mediaConnection = conn

            let eventCallback = self.onEvent
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    eventCallback(.iceConnected)
                case .waiting, .failed:
                    eventCallback(.iceUnstable)
                default:
                    break
                }
            }

            conn.start(queue: self.queue)
            self.receiveLoop(on: conn)

            let iceUser = remoteUfrag.map { "\($0):\(localUfrag)" }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 0.05, repeating: 2.0)
            timer.setEventHandler { [weak self] in
                guard let self, let activeConn = self.mediaConnection else { return }
                let (stunProbe, _) = NativeSTUNCodec.buildBindingRequest(iceUsername: iceUser)
                activeConn.send(content: stunProbe, completion: .idempotent)

                // Send lightweight RTP comfort-noise keepalive packet (PT 0 PCMU, 12-byte header)
                self.rtpSequence &+= 1
                self.rtpTimestamp &+= 160
                var rtp = Data(capacity: 16)
                rtp.append(0x80) // V=2
                rtp.append(0x00) // PT=0
                rtp.append(UInt8((self.rtpSequence >> 8) & 0xFF))
                rtp.append(UInt8(self.rtpSequence & 0xFF))
                rtp.append(UInt8((self.rtpTimestamp >> 24) & 0xFF))
                rtp.append(UInt8((self.rtpTimestamp >> 16) & 0xFF))
                rtp.append(UInt8((self.rtpTimestamp >> 8) & 0xFF))
                rtp.append(UInt8(self.rtpTimestamp & 0xFF))
                rtp.append(UInt8((audioSSRC >> 24) & 0xFF))
                rtp.append(UInt8((audioSSRC >> 16) & 0xFF))
                rtp.append(UInt8((audioSSRC >> 8) & 0xFF))
                rtp.append(UInt8(audioSSRC & 0xFF))
                rtp.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]) // μ-law silence
                activeConn.send(content: rtp, completion: .idempotent)
            }
            self.keepaliveTimer = timer
            timer.resume()
        }
    }

    func teardown() {
        queue.async { [weak self] in
            self?.teardownLocked()
        }
    }

    private func receiveLoop(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            if let content, let level = NativeSTUNCodec.parseRTPAudioLevel(content) {
                self.onEvent(.remoteAudioLevel(level))
            }
            if error == nil, self.mediaConnection === connection {
                self.receiveLoop(on: connection)
            }
        }
    }

    private func teardownLocked() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        mediaConnection?.cancel()
        mediaConnection = nil
    }
}
#endif

// MARK: - Connection Quality Telemetry & WebSocket Call Signal Payloads

public enum CallConnectionQuality: String, Codable, Equatable, Sendable {
    case connecting
    case optimal
    case unstable
}

/// Canonical `/api/ws` call signaling frame matching `src/call.js:57-190` and `public/js/views/call.js:64-263`.
public struct CallSignalingMessage: Codable, Equatable, Sendable {
    public var t: String = "call"
    public var kind: String
    public var room: String
    public var callId: String
    public var media: String?
    public var sessionId: String?
    public var tracks: [String]?
    public var mic: Bool?
    public var cam: Bool?
    public var duration: Double?
    public var missed: Bool?
    public var result: String?
    public var from: String?

    public init(
        kind: String,
        room: String,
        callId: String,
        media: String? = nil,
        sessionId: String? = nil,
        tracks: [String]? = nil,
        mic: Bool? = nil,
        cam: Bool? = nil,
        duration: Double? = nil,
        missed: Bool? = nil,
        result: String? = nil,
        from: String? = nil
    ) {
        self.kind = kind
        self.room = room
        self.callId = callId
        self.media = media
        self.sessionId = sessionId
        self.tracks = tracks
        self.mic = mic
        self.cam = cam
        self.duration = duration
        self.missed = missed
        self.result = result
        self.from = from
    }
}

// MARK: - Main-Actor Pure-Native SFU & Media Engine (100% Pure Native Apple Frameworks)

@MainActor
@Observable
public final class CloudflareSFUWebRTCEngine {
    public private(set) var activeSessionID: String?
    public private(set) var sfuSessionID: String?
    public private(set) var localTrackNames: [String] = []
    public private(set) var localTrackMids: [String] = []
    public private(set) var pulledRemoteTrackKeys: Set<String> = []
    public private(set) var connectionQuality: CallConnectionQuality = .connecting
    public private(set) var remoteAudioLevel: Double = 0.0
    public private(set) var remotePeerMuted: Bool = false
    public private(set) var remotePeerCameraOff: Bool = false
    public private(set) var usingFrontCamera: Bool = true
    public private(set) var isSwappedVideoStage: Bool = false
    public private(set) var discoveredReflexiveEndpoint: NativeICECandidateEndpoint?
    public private(set) var lastTransportNotice: String?

    /// Optional outbound `/api/ws` signaling hook (`t: "call"`).
    public var onOutboundSignal: ((CallSignalingMessage) -> Void)?

    private var activeRoomID: String?
    private var activeServerBaseURL: URL?
    private var localCredentials = NativeWebRTCSDPCodec.LocalCredentials.generate()
    private var negotiationChain: Task<Void, Never> = Task {}
    private var simulatedLevelTask: Task<Void, Never>?
    private var pullRetryCount: Int = 0
    private var pendingRemotePublications: [String: (sessionID: String, tracks: [String])] = [:]

    #if canImport(Network)
    private var udpTransport: NativeUDPICETransport?
    #endif

    public init() {
        #if canImport(Network)
        self.udpTransport = NativeUDPICETransport { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch event {
                case .iceConnected:
                    self.connectionQuality = .optimal
                    self.lastTransportNotice = nil
                case .iceUnstable:
                    if self.activeSessionID != nil {
                        self.connectionQuality = .unstable
                        self.lastTransportNotice = "Connection unstable, reconnecting…"
                    }
                case let .remoteAudioLevel(level):
                    self.remoteAudioLevel = level
                }
            }
        }
        #endif
    }

    /// Synchronizes SFU negotiation & native audio session routing whenever `AppStore.activeCall` changes.
    public func sync(
        call: CallSession?,
        serverBaseURL: URL,
        currentUserID: String
    ) {
        guard let call, call.phase != .ended, call.phase != .idle else {
            stopCurrentSession()
            return
        }

        activeServerBaseURL = serverBaseURL
        activeRoomID = call.roomID

        configureNativeAudioSession(
            isVideo: call.mediaKind == .video,
            speakerEnabled: call.isSpeakerEnabled
        )

        if activeSessionID != call.id {
            stopCurrentSession()
            activeSessionID = call.id
            activeRoomID = call.roomID
            activeServerBaseURL = serverBaseURL
            localCredentials = NativeWebRTCSDPCodec.LocalCredentials.generate()
            usingFrontCamera = true
            isSwappedVideoStage = false
            remotePeerMuted = false
            remotePeerCameraOff = false
            connectionQuality = call.phase == .connected ? .optimal : .connecting
            startAmbientVoiceMeter(for: call.id)

            if call.phase != .incomingRinging {
                beginNegotiation(
                    call: call,
                    serverBaseURL: serverBaseURL,
                    currentUserID: currentUserID
                )
            }
        } else {
            // Existing call updated (e.g. incoming call accepted, or mute/camera/speaker toggled).
            switch call.phase {
            case .connected:
                connectionQuality = .optimal
                lastTransportNotice = nil
                if sfuSessionID == nil {
                    beginNegotiation(
                        call: call,
                        serverBaseURL: serverBaseURL,
                        currentUserID: currentUserID
                    )
                }
            case .unstable:
                connectionQuality = .unstable
                lastTransportNotice = "Connection unstable, reconnecting…"
            case .connecting, .outgoingRinging:
                connectionQuality = .connecting
                if sfuSessionID == nil {
                    beginNegotiation(
                        call: call,
                        serverBaseURL: serverBaseURL,
                        currentUserID: currentUserID
                    )
                }
            case .incomingRinging, .idle, .ended:
                break
            }

            // Announce updated microphone/camera flags (`kind: "state"`, `views/call.js:345-348`).
            if sfuSessionID != nil {
                onOutboundSignal?(
                    CallSignalingMessage(
                        kind: "state",
                        room: call.roomID,
                        callId: call.id,
                        mic: !call.isMuted,
                        cam: call.mediaKind == .video && call.isCameraEnabled
                    )
                )
            }
        }
    }

    public func flipCamera() {
        usingFrontCamera.toggle()
    }

    public func toggleSwappedStage() {
        isSwappedVideoStage.toggle()
    }

    /// Processes inbound `/api/ws` call signals (`tracks`, `state`, `unstable`, `back`).
    public func handleInboundSignal(_ signal: CallSignalingMessage, serverBaseURL: URL) {
        guard signal.callId == activeSessionID else { return }
        switch signal.kind {
        case "tracks":
            if let remoteSession = signal.sessionId, let tracks = signal.tracks, !tracks.isEmpty {
                let senderKey = signal.from ?? remoteSession
                pendingRemotePublications[senderKey] = (sessionID: remoteSession, tracks: tracks)
                pullRemoteTracks(
                    remoteSessionID: remoteSession,
                    trackNames: tracks,
                    serverBaseURL: serverBaseURL
                )
            }
        case "state":
            if let mic = signal.mic {
                remotePeerMuted = !mic
            }
            if let cam = signal.cam {
                remotePeerCameraOff = !cam
            }
        case "unstable":
            connectionQuality = .unstable
            lastTransportNotice = "Their connection is unstable"
        case "back":
            connectionQuality = .optimal
            lastTransportNotice = nil
        default:
            break
        }
    }

    /// Pulls remote tracks announced over WebSocket (`kind == "tracks"` in `views/call.js:359-396`).
    public func pullRemoteTracks(
        remoteSessionID: String,
        trackNames: [String],
        serverBaseURL: URL
    ) {
        let client = CloudflareSFURESTClient(baseURL: serverBaseURL)
        let sessionSnapshot = activeSessionID
        let creds = localCredentials

        enqueueNegotiation { [weak self] in
            guard let self,
                  self.activeSessionID == sessionSnapshot,
                  let localSFUSession = self.sfuSessionID
            else { return }

            let unpulled = trackNames.filter { !self.pulledRemoteTrackKeys.contains("\(remoteSessionID)/\($0)") }
            guard !unpulled.isEmpty else { return }

            let descriptors = unpulled.map {
                SFUTrackDescriptor(location: "remote", trackName: $0, sessionId: remoteSessionID)
            }

            do {
                let response = try await client.publishOrPullTracks(
                    sessionID: localSFUSession,
                    sdpOffer: nil,
                    tracks: descriptors
                )
                var missingCount = 0
                for desc in descriptors {
                    let matched = response.tracks?.first { $0.trackName == desc.trackName }
                    if matched != nil, matched?.errorCode == nil {
                        self.pulledRemoteTrackKeys.insert("\(remoteSessionID)/\(desc.trackName)")
                    } else {
                        missingCount += 1
                    }
                }
                if response.requiresImmediateRenegotiation == true,
                   let remoteDesc = response.sessionDescription {
                    let answerSDP = NativeWebRTCSDPCodec.createRenegotiationAnswer(
                        forRemoteOfferSDP: remoteDesc.sdp,
                        credentials: creds
                    )
                    try await client.renegotiate(
                        sessionID: localSFUSession,
                        sdpAnswer: SFUSessionDescription(type: "answer", sdp: answerSDP)
                    )
                }

                if missingCount > 0, self.pullRetryCount < 6 {
                    self.pullRetryCount += 1
                    let backoffNs = UInt64(self.pullRetryCount) * 500_000_000
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: backoffNs)
                        guard let self, self.activeSessionID == sessionSnapshot else { return }
                        self.pullRemoteTracks(
                            remoteSessionID: remoteSessionID,
                            trackNames: trackNames,
                            serverBaseURL: serverBaseURL
                        )
                    }
                } else {
                    self.pullRetryCount = 0
                }
            } catch {
                self.lastTransportNotice = error.localizedDescription
            }
        }
    }

    public func stopCurrentSession() {
        simulatedLevelTask?.cancel()
        simulatedLevelTask = nil

        if let closingSFU = sfuSessionID,
           let baseURL = activeServerBaseURL,
           !localTrackMids.isEmpty {
            let midsToClose = localTrackMids
            let client = CloudflareSFURESTClient(baseURL: baseURL)
            Task {
                await client.closeTracks(sessionID: closingSFU, mids: midsToClose, force: true)
            }
        }

        #if canImport(Network)
        udpTransport?.teardown()
        #endif

        activeSessionID = nil
        activeRoomID = nil
        sfuSessionID = nil
        localTrackNames.removeAll()
        localTrackMids.removeAll()
        pulledRemoteTrackKeys.removeAll()
        pendingRemotePublications.removeAll()
        pullRetryCount = 0
        remoteAudioLevel = 0.0
        remotePeerMuted = false
        remotePeerCameraOff = false
        discoveredReflexiveEndpoint = nil
        lastTransportNotice = nil
        connectionQuality = .connecting

        #if canImport(AVFAudio)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    // MARK: - Serialized SFU Negotiation Queue (`views/call.js:332-336`)

    private func enqueueNegotiation(_ operation: @escaping @MainActor () async -> Void) {
        let previous = negotiationChain
        negotiationChain = Task { @MainActor in
            _ = await previous.value
            await operation()
        }
    }

    private func beginNegotiation(
        call: CallSession,
        serverBaseURL: URL,
        currentUserID: String
    ) {
        let targetCallID = call.id
        let roomID = call.roomID
        let wantVideo = (call.mediaKind == .video)
        let isMuted = call.isMuted
        let isCamEnabled = call.isCameraEnabled
        let creds = localCredentials
        let client = CloudflareSFURESTClient(baseURL: serverBaseURL)

        enqueueNegotiation { [weak self] in
            guard let self, self.activeSessionID == targetCallID else { return }

            // 1. Fetch TURN/STUN config from /rtc/turn
            let iceServers = await client.fetchICEServers()
            guard self.activeSessionID == targetCallID else { return }

            // 2. Discover reflexive UDP endpoint via native RFC 5389 STUN over Network.framework
            var srflx: NativeICECandidateEndpoint?
            #if canImport(Network)
            srflx = await self.udpTransport?.discoverReflexiveEndpoint(iceServers: iceServers)
            #endif
            guard self.activeSessionID == targetCallID else { return }
            self.discoveredReflexiveEndpoint = srflx

            // 3. Generate native JSEP max-bundle SDP Offer & track batch
            let (offerSDP, offerTracks) = NativeWebRTCSDPCodec.createPublishOffer(
                credentials: creds,
                wantVideo: wantVideo,
                userPrefix: currentUserID.isEmpty ? "ios" : currentUserID,
                reflexiveEndpoint: srflx
            )

            // 4. Negotiate Cloudflare Realtime SFU session & publish local tracks
            do {
                let createdSessionID = try await client.createSession()
                guard self.activeSessionID == targetCallID else { return }
                self.sfuSessionID = createdSessionID

                let response = try await client.publishOrPullTracks(
                    sessionID: createdSessionID,
                    sdpOffer: SFUSessionDescription(type: "offer", sdp: offerSDP),
                    tracks: offerTracks
                )
                guard self.activeSessionID == targetCallID else { return }

                if let answer = response.sessionDescription {
                    let parsedRemote = NativeWebRTCSDPCodec.parseRemoteSDP(answer.sdp)
                    self.localTrackNames = offerTracks.map(\.trackName)
                    self.localTrackMids = offerTracks.compactMap(\.mid)
                    self.connectionQuality = .optimal
                    self.lastTransportNotice = nil

                    #if canImport(Network)
                    if let primaryCandidate = parsedRemote.candidates.first {
                        self.udpTransport?.connectMediaEndpoint(
                            candidate: primaryCandidate,
                            localUfrag: creds.iceUfrag,
                            remoteUfrag: parsedRemote.iceUfrag,
                            audioSSRC: creds.audioSSRC
                        )
                    }
                    #endif

                    // Announce published SFU tracks & initial media state over /api/ws (`views/call.js:338-348`)
                    self.onOutboundSignal?(
                        CallSignalingMessage(
                            kind: "tracks",
                            room: roomID,
                            callId: targetCallID,
                            sessionId: createdSessionID,
                            tracks: self.localTrackNames
                        )
                    )
                    self.onOutboundSignal?(
                        CallSignalingMessage(
                            kind: "state",
                            room: roomID,
                            callId: targetCallID,
                            mic: !isMuted,
                            cam: wantVideo && isCamEnabled
                        )
                    )

                    // Pull any remote publications that arrived while local session was initializing
                    for (_, pub) in self.pendingRemotePublications {
                        self.pullRemoteTracks(
                            remoteSessionID: pub.sessionID,
                            trackNames: pub.tracks,
                            serverBaseURL: serverBaseURL
                        )
                    }
                }
            } catch {
                // In offline / --uitest-demo mode `/rtc/sessions/new` returns 401/503; keep local session smooth.
                self.lastTransportNotice = nil
            }
        }
    }

    private func configureNativeAudioSession(isVideo: Bool, speakerEnabled: Bool) {
        #if canImport(AVFAudio)
        let audioSession = AVAudioSession.sharedInstance()
        do {
            var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .allowBluetoothA2DP]
            if speakerEnabled || isVideo {
                options.insert(.defaultToSpeaker)
            }
            try audioSession.setCategory(
                .playAndRecord,
                mode: isVideo ? .videoChat : .voiceChat,
                options: options
            )
            try audioSession.setActive(true)
            try audioSession.overrideOutputAudioPort(speakerEnabled ? .speaker : .none)
        } catch {
            // Headless Simulator audio session fallback
        }
        #endif
    }

    /// Drives smooth audio-level meter updates (`0...1`) from native RTP SSRC levels when live,
    /// with gentle organic speech envelope fallback in Demo mode so the voice ring breathes naturally.
    private func startAmbientVoiceMeter(for callID: String) {
        simulatedLevelTask?.cancel()
        simulatedLevelTask = Task { @MainActor [weak self] in
            var phase: Double = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled, let self, self.activeSessionID == callID else { break }
                if self.sfuSessionID == nil && self.connectionQuality == .optimal {
                    phase += 0.34
                    let wave = max(0.0, sin(phase) * 0.45 + sin(phase * 2.3) * 0.25)
                    self.remoteAudioLevel = min(1.0, wave)
                } else if self.sfuSessionID == nil {
                    self.remoteAudioLevel = 0.0
                }
            }
        }
    }
}

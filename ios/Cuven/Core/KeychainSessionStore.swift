import Foundation
import Security
import CuvenCore

// MARK: - Keychain Session & Local Preferences Store (ios/Cuven/Core/KeychainSessionStore.swift)
//
// Persists `cfm_session` in the iOS Keychain (`kSecClassGenericPassword`) with a sandboxed fallback
// when running unsigned (`CODE_SIGNING_ALLOWED=NO`, `-34018 errSecMissingEntitlement`) on CI Simulators,
// and synchronizes `HTTPCookieStorage.shared` so `URLSession` / `AVURLAsset` media requests automatically
// carry `Cookie: cfm_session=<token>`.

public final class KeychainSessionStore: @unchecked Sendable {
    public static let shared = KeychainSessionStore()

    public let service: String
    public let account: String
    private let defaults: UserDefaults
    private let fallbackFileURL: URL
    private let lock = NSLock()
    private var memoryToken: String?

    private enum Keys {
        static let serverBaseURL = "cuven.serverBaseURL"
        static let localUserPrefs = "cuven.localUserPrefs"
        static let dominantTintHex = "cuven.dominantTintHex"
        static let installedStickerPacks = "cuven.installedStickerPacks"
    }

    public init(
        service: String = "us.cuven.wechat.session",
        account: String = "cfm_session",
        defaults: UserDefaults = .standard,
        fallbackDirectoryURL: URL? = nil
    ) {
        self.service = service
        self.account = account
        self.defaults = defaults
        let baseDir = fallbackDirectoryURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.fallbackFileURL = baseDir
            .appendingPathComponent("Cuven/Session", isDirectory: true)
            .appendingPathComponent("\(account).tok", isDirectory: false)
    }

    // MARK: - Session Token (`cfm_session`)

    public func loadSessionToken() -> String? {
        lock.lock()
        defer { lock.unlock() }

        if let mem = memoryToken, !mem.isEmpty {
            return mem
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess,
           let data = item as? Data,
           let token = String(data: data, encoding: .utf8),
           !token.isEmpty {
            memoryToken = token
            return token
        }

        if let data = try? Data(contentsOf: fallbackFileURL),
           let token = String(data: data, encoding: .utf8),
           !token.isEmpty {
            memoryToken = token
            return token
        }

        return nil
    }

    public func saveSessionToken(_ token: String?, for serverBaseURL: URL) {
        lock.lock()
        defer {
            lock.unlock()
            Self.synchronizeSharedCookieStorage(token: token, serverBaseURL: serverBaseURL)
        }

        guard let token, !token.isEmpty else {
            memoryToken = nil
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(deleteQuery as CFDictionary)
            try? FileManager.default.removeItem(at: fallbackFileURL)
            return
        }

        memoryToken = token
        let tokenData = Data(token.utf8)

        let matchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: tokenData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(matchQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = matchQuery
            for (k, v) in attributes {
                addQuery[k] = v
            }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                writeFallbackToken(tokenData)
            }
        } else if updateStatus != errSecSuccess {
            writeFallbackToken(tokenData)
        }
    }

    public func clearSession(for serverBaseURL: URL) {
        saveSessionToken(nil, for: serverBaseURL)
    }

    private func writeFallbackToken(_ data: Data) {
        do {
            let dir = fallbackFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: fallbackFileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            try? data.write(to: fallbackFileURL, options: [.atomic])
        }
    }

    // MARK: - HTTPCookieStorage Synchronization

    public static func synchronizeSharedCookieStorage(token: String?, serverBaseURL: URL) {
        let storage = HTTPCookieStorage.shared
        let host = serverBaseURL.host ?? "wechat.cuven.us"
        let isSecure = (serverBaseURL.scheme ?? "https").lowercased() == "https"

        if let existing = storage.cookies {
            for cookie in existing where cookie.name == CuvenRequestBuilder.sessionCookieName && cookie.domain.contains(host) {
                storage.deleteCookie(cookie)
            }
        }

        guard let token, !token.isEmpty else { return }

        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: CuvenRequestBuilder.sessionCookieName,
            .value: token,
            .domain: host,
            .path: "/",
            .version: "0"
        ]
        if isSecure {
            properties[.secure] = "TRUE"
        }
        if let cookie = HTTPCookie(properties: properties) {
            storage.setCookie(cookie)
        }
    }

    // MARK: - Server Base URL & Local Client Preferences

    public func loadServerBaseURL() -> URL {
        if let saved = defaults.string(forKey: Keys.serverBaseURL),
           let url = URL(string: saved),
           let scheme = url.scheme,
           (scheme == "https" || scheme == "http"),
           url.host != nil {
            return url
        }
        return URL(string: "https://wechat.cuven.us")!
    }

    public func saveServerBaseURL(_ url: URL) {
        defaults.set(url.absoluteString, forKey: Keys.serverBaseURL)
    }

    public func loadUserPrefs() -> UserPrefs {
        guard let data = defaults.data(forKey: Keys.localUserPrefs),
              let decoded = try? JSONDecoder().decode(UserPrefs.self, from: data) else {
            return UserPrefs()
        }
        return decoded
    }

    public func saveUserPrefs(_ prefs: UserPrefs) {
        if let data = try? JSONEncoder().encode(prefs) {
            defaults.set(data, forKey: Keys.localUserPrefs)
        }
    }

    public func loadDominantTintHex() -> String? {
        defaults.string(forKey: Keys.dominantTintHex)
    }

    public func saveDominantTintHex(_ hex: String?) {
        if let hex, !hex.isEmpty {
            defaults.set(hex, forKey: Keys.dominantTintHex)
        } else {
            defaults.removeObject(forKey: Keys.dominantTintHex)
        }
    }

    public func loadInstalledStickerPacks() -> Set<String>? {
        guard let array = defaults.stringArray(forKey: Keys.installedStickerPacks) else {
            return nil
        }
        return Set(array)
    }

    public func saveInstalledStickerPacks(_ names: Set<String>) {
        defaults.set(Array(names).sorted(), forKey: Keys.installedStickerPacks)
    }
}
